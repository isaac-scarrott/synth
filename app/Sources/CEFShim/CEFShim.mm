// CEF runtime + per-session browser bridge. All CEF C++ lives here; Swift sees CEFShim.h.
//
// Load-bearing choices, each traced to spike/LEARNINGS.md:
// - The framework is dlopen'd from the app bundle (CefScopedLibraryLoader), so a bare
//   `swift build` binary fails initialize cleanly instead of crashing.
// - external_message_pump on the existing NSApplication runloop — Synth already owns
//   the main loop, CefRunMessageLoop would fight SwiftUI.
// - SetAsChild forces Alloy runtime style on macOS; we request it explicitly rather
//   than let DEFAULT resolve (the cefsimple CHECK_EQ trap).
// - OnBeforePopup always cancels and surfaces the URL: an unhandled popup blocks the
//   renderer inside window.open() forever.
// - --use-mock-keychain under automation: keychain (os_crypt) lookups crash or hang
//   startup in harness-spawned contexts, taking the CDP server with them.

#import "CEFShim.h"

#import <objc/runtime.h>

#include <crt_externs.h>

#include <algorithm>
#include <atomic>
#include <list>
#include <string>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

static BOOL g_initialized = NO;
static BOOL g_contextInitialized = NO;
static BOOL g_shutdownDone = NO;
static BOOL g_automation = NO;
// Every live CEF browser (sessions + DevTools windows); CefShutdown is only legal at 0.
static std::atomic<int> g_aliveBrowsers{0};
// Weak registry of session browsers so runtime shutdown can force-close stragglers.
static NSHashTable<CEFShimBrowser *> *g_liveShimBrowsers;

#pragma mark - CefAppProtocol graft

// CEF requires NSApp to conform to CefAppProtocol, but SwiftUI owns the NSApplication
// instance, so the protocol is grafted onto its class at runtime (the JCEF approach)
// instead of subclassing.
static BOOL g_handlingSendEvent = NO;
static IMP g_originalSendEvent = NULL;

static BOOL ShimIsHandlingSendEvent(id, SEL) {
  return g_handlingSendEvent;
}
static void ShimSetHandlingSendEvent(id, SEL, BOOL handling) {
  g_handlingSendEvent = handling;
}
static void ShimSendEvent(id self, SEL _cmd, NSEvent *event) {
  BOOL previous = g_handlingSendEvent;
  g_handlingSendEvent = YES;
  ((void (*)(id, SEL, NSEvent *))g_originalSendEvent)(self, _cmd, event);
  g_handlingSendEvent = previous;
}

static void GraftCefAppProtocol(void) {
  Class cls = [[NSApplication sharedApplication] class];
  if ([cls conformsToProtocol:@protocol(CefAppProtocol)]) {
    return;
  }
  char boolGetterEnc[8], boolSetterEnc[8];
  snprintf(boolGetterEnc, sizeof(boolGetterEnc), "%s@:", @encode(BOOL));
  snprintf(boolSetterEnc, sizeof(boolSetterEnc), "v@:%s", @encode(BOOL));
  class_addMethod(cls, @selector(isHandlingSendEvent), (IMP)ShimIsHandlingSendEvent,
                  boolGetterEnc);
  class_addMethod(cls, @selector(setHandlingSendEvent:), (IMP)ShimSetHandlingSendEvent,
                  boolSetterEnc);
  Method sendEvent = class_getInstanceMethod(cls, @selector(sendEvent:));
  g_originalSendEvent = method_getImplementation(sendEvent);
  method_setImplementation(sendEvent, (IMP)ShimSendEvent);
  class_addProtocol(cls, @protocol(CefAppProtocol));
}

#pragma mark - External message pump
//
// cefclient's MainMessageLoopExternalPump shape: OnScheduleMessagePumpWork callbacks
// for latency, plus a permanent ~30ms fallback timer for liveness. The timer is
// load-bearing, not paranoia: Chromium arms OnScheduleMessagePumpWork edge-triggered
// (work_deduplicator), and init/browser-creation must drive CefDoMessageLoopWork
// manually outside any scheduled callback, which consumes the outstanding edge.
// Observed on CEF 144: after CefInitialize's single delay=0 callback CEF never
// scheduled again, so a schedule-only pump starved permanently the moment manual
// pumping ended (black view, dead CDP, zero delegate callbacks).

// Diagnostics: SYNTH_CEF_PUMP_TRACE=<path> traces every schedule/pump event.
#include <pthread.h>
static FILE *PumpTraceFile(void) {
  static FILE *f = NULL;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char *path = getenv("SYNTH_CEF_PUMP_TRACE");
    if (path) f = fopen(path, "w");
  });
  return f;
}
#define PUMP_TRACE(fmt, ...)                                                              \
  do {                                                                                    \
    FILE *tf = PumpTraceFile();                                                           \
    if (tf) {                                                                             \
      fprintf(tf, "%.3f [t%x m%d] " fmt "\n", CFAbsoluteTimeGetCurrent(),                 \
              (unsigned)pthread_mach_thread_np(pthread_self()),                           \
              (int)pthread_main_np(), ##__VA_ARGS__);                                     \
      fflush(tf);                                                                         \
    }                                                                                     \
  } while (0)

static void PumpWork(void);

// The permanent fallback: fires every 30ms from init to shutdown and drives
// CefDoMessageLoopWork, so delayed work and any lost schedule edge are picked up
// within one tick. An idle CefDoMessageLoopWork costs microseconds.
static dispatch_source_t g_pumpTimer;

static void StartPumpTimer(void) {
  if (g_pumpTimer) {
    return;
  }
  g_pumpTimer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(g_pumpTimer, DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC,
                            10 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(g_pumpTimer, ^{
    PumpWork();
  });
  dispatch_resume(g_pumpTimer);
}

static void StopPumpTimer(void) {
  if (g_pumpTimer) {
    dispatch_source_cancel(g_pumpTimer);
    g_pumpTimer = nil;
  }
}

static void SchedulePumpWork(int64_t delayMs) {
  PUMP_TRACE("schedule delay=%lld", (long long)delayMs);
  // Callable from any CEF thread; the pump itself only ever runs on main. Delayed
  // work (delay > 0) is covered by the fallback timer within 30ms.
  if (delayMs > 0) {
    return;
  }
  static std::atomic<bool> pending{false};
  bool expected = false;
  if (!pending.compare_exchange_strong(expected, true)) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    pending.store(false);
    PumpWork();
  });
}

static void PumpWork(void) {
  if (!g_initialized || g_shutdownDone) {
    return;
  }
  // A nested runloop (modal panel, menu tracking) can drain the main queue while a
  // previous CefDoMessageLoopWork is still on the stack; CEF forbids reentrancy.
  // A skipped pump is never lost — the fallback timer retries within 30ms.
  static BOOL working = NO;
  if (working) {
    PUMP_TRACE("pump reentrant -> skip");
    return;
  }
  working = YES;
  PUMP_TRACE("pump DoWork begin");
  CefDoMessageLoopWork();
  PUMP_TRACE("pump DoWork end");
  working = NO;
}

#pragma mark - CefApp

class ShimApp : public CefApp, public CefBrowserProcessHandler {
 public:
  ShimApp() = default;

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString &process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (g_automation) {
      command_line->AppendSwitch("use-mock-keychain");
    }
  }

  void OnContextInitialized() override { g_contextInitialized = YES; }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override { SchedulePumpWork(delay_ms); }

 private:
  IMPLEMENT_REFCOUNTING(ShimApp);
  DISALLOW_COPY_AND_ASSIGN(ShimApp);
};

#pragma mark - Browser container view

@class CEFShimBrowser;

// Keeps the CEF child NSView glued to the container's bounds through SwiftUI layout,
// and tells the owner when the pane reparents it (so the staging window can go).
@interface CEFShimContainerView : NSView
@property(nonatomic, weak, nullable) CEFShimBrowser *owner;
@end

@interface CEFShimBrowser ()
- (void)containerDidMoveToWindow:(nullable NSWindow *)window;
@end

@implementation CEFShimContainerView
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  for (NSView *subview in self.subviews) {
    subview.frame = self.bounds;
  }
}
- (BOOL)isFlipped {
  return YES;
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self.owner containerDidMoveToWindow:self.window];
}
@end

#pragma mark - CEFShimBrowser internals

@interface CEFShimBrowser () {
 @public
  CefRefPtr<CefBrowser> _browser;
  BOOL _closeRequested;
}
@property(nonatomic, strong) CEFShimContainerView *containerView;
// Never-shown host for the container until the pane reparents it: CEF's child-view
// creation needs a window-backed parent (detached parents yield a nullptr browser).
@property(nonatomic, strong, nullable) NSWindow *stagingWindow;
@property(nonatomic, copy, nullable) NSString *cachedURL;
@property(nonatomic, copy, nullable) NSString *cachedTitle;
@property(nonatomic) BOOL cachedCanGoBack;
@property(nonatomic) BOOL cachedCanGoForward;

- (void)handleBrowserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)handleAddressChange:(NSString *)url;
- (void)handleTitleChange:(NSString *)title;
- (void)handleLoadingStateChangeCanGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)handlePopupRequest:(NSString *)url;
- (void)handleBeforeClose;
@end

// Life-span bookkeeping for browsers we don't surface (DevTools windows): they must
// count toward g_aliveBrowsers or shutdown would proceed under them.
class AuxClient : public CefClient, public CefLifeSpanHandler {
 public:
  AuxClient() = default;
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { g_aliveBrowsers++; }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override { g_aliveBrowsers--; }

 private:
  IMPLEMENT_REFCOUNTING(AuxClient);
  DISALLOW_COPY_AND_ASSIGN(AuxClient);
};

// One client per CEFShimBrowser, so callbacks never need first-browser filtering —
// DevTools gets AuxClient and popups are cancelled, so this client sees exactly one
// browser for its whole life.
class ShimClient : public CefClient,
                   public CefDisplayHandler,
                   public CefLifeSpanHandler,
                   public CefLoadHandler {
 public:
  ShimClient(CEFShimBrowser *owner, const std::string &sessionId)
      : owner_(owner),
        sessionTag_("window.__synthSessionId = \"" + sessionId + "\";") {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString &url) override {
    if (!frame->IsMain()) {
      return;
    }
    [owner_ handleAddressChange:@(url.ToString().c_str())];
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
    [owner_ handleTitleChange:@(title.ToString().c_str())];
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack,
                            bool canGoForward) override {
    [owner_ handleLoadingStateChangeCanGoBack:canGoBack canGoForward:canGoForward];
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    if (!frame->IsMain()) {
      return;
    }
    // Session↔target mapping for CDP clients (ADR-0011 stage two): re-stamped after
    // every main-frame load because each navigation gets a fresh JS world.
    frame->ExecuteJavaScript(sessionTag_, frame->GetURL(), 0);
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                     const CefString &target_url, const CefString &target_frame_name,
                     CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                     bool user_gesture, const CefPopupFeatures &popupFeatures,
                     CefWindowInfo &windowInfo, CefRefPtr<CefClient> &client,
                     CefBrowserSettings &settings, CefRefPtr<CefDictionaryValue> &extra_info,
                     bool *no_javascript_access) override {
    [owner_ handlePopupRequest:@(target_url.ToString().c_str())];
    return true;  // Cancel — the delegate routes the URL into a new session.
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    g_aliveBrowsers++;
    [owner_ handleBrowserCreated:browser];
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // true = the embedder completes the close via native view teardown (done in
    // -[CEFShimBrowser close]). Returning false would make CEF performClose: the
    // browser's top-level NSWindow — Synth's own app window, which never closes
    // mid-session, leaving the browser half-closed until CefShutdown.
    PUMP_TRACE("DoClose");
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    g_aliveBrowsers--;
    PUMP_TRACE("OnBeforeClose alive=%d", g_aliveBrowsers.load());
    [owner_ handleBeforeClose];
  }

 private:
  __weak CEFShimBrowser *owner_;
  const std::string sessionTag_;

  IMPLEMENT_REFCOUNTING(ShimClient);
  DISALLOW_COPY_AND_ASSIGN(ShimClient);
};

#pragma mark - CEFShimRuntime

@implementation CEFShimRuntime

+ (BOOL)initializeWithRootCachePath:(NSString *)rootCachePath
                            cdpPort:(uint16_t)cdpPort
                         automation:(BOOL)automation {
  NSAssert(NSThread.isMainThread, @"CEFShimRuntime is main-thread only");
  if (g_initialized || g_shutdownDone) {
    return g_initialized;
  }
  g_automation = automation;

  GraftCefAppProtocol();

  // Never freed: the framework must stay loaded for the process lifetime.
  static CefScopedLibraryLoader *loader = new CefScopedLibraryLoader();
  static BOOL loaded = NO;
  if (!loaded) {
    loaded = loader->LoadInMain();
  }
  if (!loaded) {
    NSLog(@"CEFShim: CEF framework not found in app bundle (run from a bundle assembled "
          @"by dev.sh/build-app.sh)");
    return NO;
  }

  CefMainArgs mainArgs(*_NSGetArgc(), *_NSGetArgv());

  CefSettings settings;
  settings.no_sandbox = true;
  settings.external_message_pump = true;
  settings.remote_debugging_port = cdpPort;
  settings.log_severity = LOGSEVERITY_WARNING;
  CefString(&settings.root_cache_path) = rootCachePath.UTF8String;
  // GUI stdout is block-buffered — file logging from day one (spike LEARNINGS).
  CefString(&settings.log_file) =
      [rootCachePath stringByAppendingPathComponent:@"cef.log"].UTF8String;

  CefRefPtr<ShimApp> app(new ShimApp);
  if (!CefInitialize(mainArgs, settings, app.get(), nullptr)) {
    // False also covers process-singleton early exit; the caller treats both as
    // "engine unavailable" rather than crashing.
    NSLog(@"CEFShim: CefInitialize failed (exit code %d)", CefGetExitCode());
    return NO;
  }
  g_initialized = YES;
  StartPumpTimer();

  // Under the external pump CefInitialize returns before the browser context is up;
  // creating a browser before OnContextInitialized silently yields nullptr. Pump it in.
  PUMP_TRACE("manual init-pump begin");
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
  while (!g_contextInitialized && deadline.timeIntervalSinceNow > 0) {
    CefDoMessageLoopWork();
    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                          beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  PUMP_TRACE("manual init-pump end (ctx=%d)", g_contextInitialized);
  if (!g_contextInitialized) {
    NSLog(@"CEFShim: browser context never initialized");
    return NO;
  }
  return YES;
}

+ (BOOL)isInitialized {
  return g_initialized;
}

+ (void)shutdown {
  NSAssert(NSThread.isMainThread, @"CEFShimRuntime is main-thread only");
  if (!g_initialized || g_shutdownDone) {
    return;
  }
  // Surviving CEF processes own the profile singleton and silently absorb the next
  // launch (spike LEARNINGS) — so force-close everything and wait it out.
  PUMP_TRACE("shutdown begin alive=%d shimBrowsers=%d", g_aliveBrowsers.load(),
             (int)g_liveShimBrowsers.count);
  for (CEFShimBrowser *browser in g_liveShimBrowsers.allObjects) {
    [browser close];
  }
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
  while (g_aliveBrowsers.load() > 0 && deadline.timeIntervalSinceNow > 0) {
    // Fresh pool each pass: close completion rides on the CEF view's dealloc
    // (WindowDestroyed), and a bare-signal shutdown never returns to the event
    // loop to drain the outer pool.
    @autoreleasepool {
      CefDoMessageLoopWork();
      [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
  }
  PUMP_TRACE("shutdown close-wait done alive=%d", g_aliveBrowsers.load());
  g_shutdownDone = YES;  // Pump gate: no CefDoMessageLoopWork after CefShutdown.
  StopPumpTimer();
  CefShutdown();
  g_initialized = NO;
}

@end

#pragma mark - CEFShimBrowser

@implementation CEFShimBrowser

- (nullable instancetype)initWithURL:(NSString *)url
                           cachePath:(NSString *)cachePath
                           sessionId:(NSString *)sessionId
                               frame:(NSRect)frame {
  NSAssert(NSThread.isMainThread, @"CEFShimBrowser is main-thread only");
  if (!g_initialized) {
    return nil;
  }
  self = [super init];
  if (!self) {
    return nil;
  }

  // Never zero-sized at creation: CEF sizes the child view once at SetAsChild, and a
  // 0x0 browser can wedge first paint before layout runs.
  NSRect initial = NSIsEmptyRect(frame) ? NSMakeRect(0, 0, 800, 600) : frame;
  _containerView = [[CEFShimContainerView alloc] initWithFrame:initial];
  _containerView.owner = self;

  _stagingWindow = [[NSWindow alloc] initWithContentRect:initial
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
  _stagingWindow.releasedWhenClosed = NO;
  [_stagingWindow.contentView addSubview:_containerView];

  CefRequestContextSettings contextSettings;
  CefString(&contextSettings.cache_path) = cachePath.UTF8String;
  CefRefPtr<CefRequestContext> context =
      CefRequestContext::CreateContext(contextSettings, nullptr);

  CefWindowInfo windowInfo;
  windowInfo.SetAsChild((__bridge void *)_containerView,
                        CefRect(0, 0, (int)NSWidth(initial), (int)NSHeight(initial)));
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  CefRefPtr<ShimClient> client(new ShimClient(self, std::string(sessionId.UTF8String)));
  CefBrowserSettings browserSettings;
  // Async creation only: a fresh request context initializes its profile off-thread,
  // and CreateBrowserSync returns nullptr rather than waiting for it. Pump until
  // OnAfterCreated so callers still get a live browser on return.
  if (!CefBrowserHost::CreateBrowser(windowInfo, client, url.UTF8String, browserSettings,
                                     nullptr, context)) {
    return nil;
  }
  PUMP_TRACE("manual create-pump begin");
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
  while (!_browser && deadline.timeIntervalSinceNow > 0) {
    CefDoMessageLoopWork();
    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                          beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  PUMP_TRACE("manual create-pump end (browser=%d)", _browser ? 1 : 0);
  if (!_browser) {
    return nil;
  }
  if (!g_liveShimBrowsers) {
    g_liveShimBrowsers = [NSHashTable weakObjectsHashTable];
  }
  [g_liveShimBrowsers addObject:self];
  return self;
}

- (NSView *)view {
  return self.containerView;
}

- (nullable NSString *)currentURL {
  return self.cachedURL;
}

- (nullable NSString *)currentTitle {
  return self.cachedTitle;
}

- (BOOL)canGoBack {
  return self.cachedCanGoBack;
}

- (BOOL)canGoForward {
  return self.cachedCanGoForward;
}

- (void)navigate:(NSString *)url {
  PUMP_TRACE("navigate %s (browser=%d)", url.UTF8String, _browser ? 1 : 0);
  if (_browser) {
    _browser->GetMainFrame()->LoadURL(url.UTF8String);
  }
}

- (void)goBack {
  if (_browser) {
    _browser->GoBack();
  }
}

- (void)goForward {
  if (_browser) {
    _browser->GoForward();
  }
}

- (void)reload {
  if (_browser) {
    _browser->Reload();
  }
}

- (void)showDevTools {
  if (!_browser) {
    return;
  }
  // Empty CefWindowInfo: CEF opens its own native DevTools window (spike-verified).
  // AuxClient keeps it out of this browser's callback stream.
  CefWindowInfo windowInfo;
  CefBrowserSettings settings;
  _browser->GetHost()->ShowDevTools(windowInfo, new AuxClient(), settings, CefPoint());
}

- (void)closeDevTools {
  if (!_browser) {
    return;
  }
  _browser->GetHost()->CloseDevTools();
}

- (BOOL)hasDevTools {
  return _browser && _browser->GetHost()->HasDevTools();
}

- (void)close {
  if (!_browser || _closeRequested) {
    return;
  }
  _closeRequested = YES;
  CefRefPtr<CefBrowserHost> host = _browser->GetHost();
  host->CloseBrowser(/*force_close=*/true);
  // Close completion on macOS is the CEF wrapper NSView's -dealloc (it calls
  // WindowDestroyed, which destroys the browser and fires OnBeforeClose). CEF's own
  // completion path performClose:'s the hosting NSWindow — Synth's app window,
  // which stays open — so tear the view down here instead. The local pool is
  // load-bearing: a signal-initiated quit pumps from inside willTerminate, where
  // the outer autorelease pool never drains, and a pool-held reference would keep
  // the view (and browser) alive until CefShutdown (observed as an 8s stall).
  @autoreleasepool {
    NSView *cefView = (__bridge NSView *)host->GetWindowHandle();
    [cefView removeFromSuperview];
  }
}

#pragma mark ShimClient callbacks (CEF UI thread == main thread under external pump)

- (void)containerDidMoveToWindow:(nullable NSWindow *)window {
  if (window && window != self.stagingWindow) {
    self.stagingWindow = nil;
  }
}

- (void)handleBrowserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  NSView *cefView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  cefView.frame = self.containerView.bounds;
  [self.containerView addSubview:cefView];
}

- (void)handleAddressChange:(NSString *)url {
  self.cachedURL = url;
  [self.delegate cefBrowserAddressDidChange:url];
}

- (void)handleTitleChange:(NSString *)title {
  self.cachedTitle = title;
  [self.delegate cefBrowserTitleDidChange:title];
}

- (void)handleLoadingStateChangeCanGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward {
  self.cachedCanGoBack = canGoBack;
  self.cachedCanGoForward = canGoForward;
  [self.delegate cefBrowserNavigationStateDidChange:canGoBack canGoForward:canGoForward];
}

- (void)handlePopupRequest:(NSString *)url {
  [self.delegate cefBrowserDidRequestPopup:url];
}

- (void)handleBeforeClose {
  _browser = nullptr;
  [g_liveShimBrowsers removeObject:self];
  [self.delegate cefBrowserDidClose];
}

@end
