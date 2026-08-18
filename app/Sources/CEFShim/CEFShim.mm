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
// - The Chromium sandbox is on; the helpers engage it (SynthBrowserHelper/main.cc).

#import "CEFShim.h"

#import <objc/runtime.h>

#include <crt_externs.h>

#include <algorithm>
#include <atomic>
#include <list>
#include <map>
#include <mutex>
#include <set>
#include <string>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_auth_callback.h"
#include "include/cef_browser.h"
#include "include/cef_callback.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"
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

#pragma mark - CEFShimAsk

// The four unwired handlers all have the same shape: CEF hands over a question and a
// callback, the page stops until the callback runs, and the answer is the user's. So they
// share one object rather than four near-identical delegate methods — the differences (a
// password, a prompt's text, an allow/deny) are the answer, not the question.

@interface CEFShimAsk () {
 @public
  CefRefPtr<CefCallback> _certCallback;
  CefRefPtr<CefAuthCallback> _authCallback;
  CefRefPtr<CefJSDialogCallback> _jsCallback;
  CefRefPtr<CefPermissionPromptCallback> _permCallback;
  uint64_t _promptId;
  BOOL _answered;
}
/// For a question CEF has no callback for — the 401 path below, which the shim drives itself.
@property(nonatomic, copy, nullable) void (^resolve)(BOOL allow, NSString *user, NSString *password);
@property(nonatomic) CEFShimAskKind kind;
@property(nonatomic, copy) NSString *origin;
@property(nonatomic, copy, nullable) NSString *detail;
@property(nonatomic, copy, nullable) NSString *defaultText;
- (void)answer:(BOOL)allow
          text:(nullable NSString *)text
          user:(nullable NSString *)user
      password:(nullable NSString *)password;
/// CEF withdrew the question (navigation, browser close). Drop the callbacks unanswered —
/// running them now would reach a request that no longer exists.
- (void)abandon;
@end

@implementation CEFShimAsk

- (void)allow {
  [self answer:YES text:nil user:nil password:nil];
}
- (void)allowWithText:(NSString *)text {
  [self answer:YES text:text user:nil password:nil];
}
- (void)allowWithUser:(NSString *)user password:(NSString *)password {
  [self answer:YES text:nil user:user password:password];
}
- (void)deny {
  [self answer:NO text:nil user:nil password:nil];
}

- (void)answer:(BOOL)allow
          text:(nullable NSString *)text
          user:(nullable NSString *)user
      password:(nullable NSString *)password {
  if (_answered) {
    return;
  }
  _answered = YES;
  if (_certCallback) {
    if (allow) {
      _certCallback->Continue();
    } else {
      _certCallback->Cancel();
    }
    _certCallback = nullptr;
  } else if (_authCallback) {
    if (allow) {
      _authCallback->Continue(CefString(user.UTF8String ?: ""),
                              CefString(password.UTF8String ?: ""));
    } else {
      _authCallback->Cancel();
    }
    _authCallback = nullptr;
  } else if (_jsCallback) {
    _jsCallback->Continue(allow, CefString(text.UTF8String ?: ""));
    _jsCallback = nullptr;
  } else if (_permCallback) {
    _permCallback->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT
                                  : CEF_PERMISSION_RESULT_DENY);
    _permCallback = nullptr;
  } else if (self.resolve) {
    self.resolve(allow, user, password);
    self.resolve = nil;
  }
}

- (void)abandon {
  _answered = YES;
  self.resolve = nil;
  _certCallback = nullptr;
  _authCallback = nullptr;
  _jsCallback = nullptr;
  _permCallback = nullptr;
}

@end

/// Every permission Chromium can prompt for, in the words a person would use. A prompt
/// naming a bitmask, or naming nothing, is the "looks broken in Synth, fine in Chrome"
/// failure with a card drawn over it.
static NSString *PermissionNames(uint32_t mask) {
  static const struct { uint32_t bit; const char *name; } kNames[] = {
      {CEF_PERMISSION_TYPE_CAMERA_STREAM, "camera"},
      {CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, "camera controls"},
      {CEF_PERMISSION_TYPE_MIC_STREAM, "microphone"},
      {CEF_PERMISSION_TYPE_GEOLOCATION, "location"},
      {CEF_PERMISSION_TYPE_NOTIFICATIONS, "notifications"},
      {CEF_PERMISSION_TYPE_CLIPBOARD, "the clipboard"},
      {CEF_PERMISSION_TYPE_MIDI_SYSEX, "MIDI devices"},
      {CEF_PERMISSION_TYPE_IDLE_DETECTION, "idle detection"},
      {CEF_PERMISSION_TYPE_LOCAL_FONTS, "your installed fonts"},
      {CEF_PERMISSION_TYPE_STORAGE_ACCESS, "storage across sites"},
      {CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, "storage across sites"},
      {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, "your screen layout"},
      {CEF_PERMISSION_TYPE_KEYBOARD_LOCK, "the keyboard"},
      {CEF_PERMISSION_TYPE_POINTER_LOCK, "the pointer"},
      {CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, "files on this Mac"},
      {CEF_PERMISSION_TYPE_LOCAL_NETWORK_ACCESS, "devices on your network"},
      {CEF_PERMISSION_TYPE_VR_SESSION, "virtual reality"},
      {CEF_PERMISSION_TYPE_AR_SESSION, "augmented reality"},
      {CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER, "protected media playback"},
      {CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, "multiple downloads"},
      {CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER, "handling links"},
      {CEF_PERMISSION_TYPE_WEB_APP_INSTALLATION, "installing itself as an app"},
      {CEF_PERMISSION_TYPE_DISK_QUOTA, "more disk space"},
      {CEF_PERMISSION_TYPE_CAPTURED_SURFACE_CONTROL, "control of the captured window"},
      {CEF_PERMISSION_TYPE_HAND_TRACKING, "hand tracking"},
      {CEF_PERMISSION_TYPE_IDENTITY_PROVIDER, "signing you in"},
  };
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (const auto &entry : kNames) {
    if ((mask & entry.bit) && ![out containsObject:@(entry.name)]) {
      [out addObject:@(entry.name)];
    }
  }
  if (out.count == 0) {
    return @"something this build of Synth has no name for";
  }
  if (out.count == 1) {
    return out[0];
  }
  NSString *last = out.lastObject;
  [out removeLastObject];
  return [NSString stringWithFormat:@"%@ and %@", [out componentsJoinedByString:@", "], last];
}

/// Why the engine won't vouch for the certificate, in one clause a person can act on. Only
/// the ones a developer meets: a self-signed certificate on a dev box, one that has expired,
/// one issued for a different name. Anything else says what it is and leaves the judgement
/// where it belongs.
static NSString *CertErrorReason(cef_errorcode_t code) {
  switch (code) {
    case ERR_CERT_AUTHORITY_INVALID:
      return @"it was signed by an authority this Mac doesn't trust — which is what a "
             @"self-signed certificate on a local server looks like";
    case ERR_CERT_COMMON_NAME_INVALID:
      return @"it was issued for a different address than the one being loaded";
    case ERR_CERT_DATE_INVALID:
      return @"it has expired, or isn't valid yet";
    case ERR_CERT_REVOKED:
      return @"it has been revoked by the authority that issued it";
    case ERR_CERT_WEAK_SIGNATURE_ALGORITHM:
    case ERR_CERT_WEAK_KEY:
      return @"it is signed too weakly to be trusted";
    case ERR_CERT_NAME_CONSTRAINT_VIOLATION:
      return @"its issuer isn't allowed to vouch for this address";
    case ERR_CERT_VALIDITY_TOO_LONG:
      return @"it is valid for longer than certificates are allowed to be";
    case ERR_CERT_INVALID:
    case ERR_CERT_CONTAINS_ERRORS:
      return @"it is malformed";
    default:
      return [NSString stringWithFormat:@"the engine rejected it (error %d)", (int)code];
  }
}

/// scheme://host:port — the unit a credential belongs to. A password typed for
/// staging.example.com must not travel to anything else.
static std::string OriginOf(const std::string &url) {
  NSURL *parsed = [NSURL URLWithString:@(url.c_str())];
  if (!parsed.scheme || !parsed.host) {
    return std::string();
  }
  NSString *origin = parsed.port
      ? [NSString stringWithFormat:@"%@://%@:%@", parsed.scheme, parsed.host, parsed.port]
      : [NSString stringWithFormat:@"%@://%@", parsed.scheme, parsed.host];
  return std::string(origin.UTF8String);
}

/// The host a person recognises, out of a full URL. A prompt that says
/// "https://staging.synth.dev:8443/admin/login?next=%2F is asking for a password" has
/// buried the one thing the answer turns on.
static NSString *HostOf(const CefString &url) {
  NSString *raw = @(url.ToString().c_str());
  NSURL *parsed = [NSURL URLWithString:raw];
  NSString *host = parsed.host;
  if (host.length == 0) {
    return raw.length > 0 ? raw : @"this page";
  }
  return parsed.port ? [NSString stringWithFormat:@"%@:%@", host, parsed.port] : host;
}

#pragma mark - Context menu

// Right-click. CEF builds a default model and can display it itself, but the menu Synth wants
// is not Chrome's: there is no tab strip to open a link into and downloads are blocked
// (ADR-0011 stage five), so "Open Link in New Tab" and "Save Image As…" are items that would
// do nothing. The model is replaced with the verbs this pane actually has, and the display is
// the delegate's — a native NSMenu, the way every other native app draws one, and the same
// seam a driven build uses to record the menu instead of putting it on someone's screen.

enum : int {
  kMenuOpenExternal = MENU_ID_USER_FIRST,
  kMenuCopyLink,
  kMenuCopyImage,
  kMenuInspect,
};

@interface CEFShimMenuItem ()
@property(nonatomic, copy) NSString *title;
@property(nonatomic) int commandID;
@property(nonatomic) BOOL enabled;
@end

@implementation CEFShimMenuItem
- (BOOL)isSeparator {
  return self.title.length == 0;
}
@end

static CEFShimMenuItem *MenuItem(NSString *title, int commandID, BOOL enabled) {
  CEFShimMenuItem *item = [[CEFShimMenuItem alloc] init];
  item.title = title ?: @"";
  item.commandID = commandID;
  item.enabled = enabled;
  return item;
}

static void CopyToPasteboard(const CefString &text) {
  NSPasteboard *pb = [NSPasteboard generalPasteboard];
  [pb clearContents];
  [pb setString:@(text.ToString().c_str()) forType:NSPasteboardTypeString];
}

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
  /// origin -> "Basic <base64>", for as long as this browser lives. Touched only on the
  /// main thread: the IO thread reads it through -authorizationForOrigin:, which is called
  /// from OnBeforeResourceLoad, so it is a std::map under a lock rather than a bare read.
  std::map<std::string, std::string> _authTokens;
  std::mutex _authMutex;
  /// Origins with a question already on screen, so a page whose every subresource 401s
  /// raises one prompt rather than twenty.
  std::set<std::string> _authAsking;
  /// This session's request context, kept so a popup opens on the same profile — a sign-in
  /// window with its own cookie jar is not a sign-in window.
  CefRefPtr<CefRequestContext> _context;
}
@property(nonatomic, strong) CEFShimContainerView *containerView;
// Never-shown host for the container until the pane reparents it: CEF's child-view
// creation needs a window-backed parent (detached parents yield a nullptr browser).
@property(nonatomic, strong, nullable) NSWindow *stagingWindow;
@property(nonatomic, copy, nullable) NSString *cachedURL;
@property(nonatomic, copy, nullable) NSString *cachedTitle;
@property(nonatomic) BOOL cachedCanGoBack;
@property(nonatomic) BOOL cachedCanGoForward;
/// The questions this page is holding on, oldest first. More than one is normal — a page can
/// call alert() twice, or ask for the camera while an auth challenge is still up — and each
/// keeps its own callback, so answering one never touches another.
@property(nonatomic, strong) NSMutableArray<CEFShimAsk *> *pendingAsks;

- (void)handleBrowserCreated:(CefRefPtr<CefBrowser>)browser;
- (void)handleAddressChange:(NSString *)url;
- (void)handleTitleChange:(NSString *)title;
- (void)handleLoadingStateChangeCanGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)handleAsk:(CEFShimAsk *)ask;
- (void)handleOpenExternal:(NSString *)url;
- (void)openPopup:(NSString *)url width:(int)width height:(int)height;
- (nullable NSString *)authorizationForOrigin:(const std::string &)origin;
- (void)challengeOrigin:(std::string)origin realm:(nullable NSString *)realm;
- (void)handleWithdrawPromptID:(uint64_t)promptID;
- (void)handleFindResult:(int)activeIndex count:(int)count final:(BOOL)finalUpdate;
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

// getUserMedia answers through CefMediaAccessCallback, which wants the media permissions it
// was asked about handed back; the generic prompt answers through CefPermissionPromptCallback,
// which takes an accept/deny. This adapts the first to the second so the shim carries ONE
// kind of pending answer, and a permission question is a permission question wherever it came
// from.
class MediaAccessShim : public CefPermissionPromptCallback {
 public:
  MediaAccessShim(CefRefPtr<CefMediaAccessCallback> callback, uint32_t requested)
      : callback_(callback), requested_(requested) {}

  void Continue(cef_permission_request_result_t result) override {
    if (!callback_) {
      return;
    }
    if (result == CEF_PERMISSION_RESULT_ACCEPT) {
      callback_->Continue(requested_);
    } else {
      callback_->Cancel();
    }
    callback_ = nullptr;
  }

 private:
  CefRefPtr<CefMediaAccessCallback> callback_;
  const uint32_t requested_;

  IMPLEMENT_REFCOUNTING(MediaAccessShim);
  DISALLOW_COPY_AND_ASSIGN(MediaAccessShim);
};

#pragma mark - Transient popup windows

// window.open used to route into a NEW Synth browser session — a permanent sidebar row that
// outlived the flow that opened it. Consistent with one-page-per-session and wrong in
// practice: the overwhelming use of a popup is OAuth, so signing into your own staging app
// left litter behind every time, and a popup that closed itself left a dead row. A popup is a
// transient window now, and never a session (ADR-0011 stage five).
//
// It is a window Synth opens, not a popup the engine hands us, and that distinction is
// measured rather than chosen. Letting CEF create the popup — return false from OnBeforePopup
// — hangs the opener's renderer inside window.open() permanently on this embedding: with the
// pump healthy (verified through SYNTH_CEF_PUMP_TRACE: DoWork begin/end every 30ms
// throughout) and with NO modification to windowInfo, client or settings, the opener stops
// answering CDP evaluates and the popup browser is never created. So the popup is cancelled,
// which is what keeps the renderer running, and the URL is opened in a window of our own on
// the next main-queue turn — using the same create-and-pump path the session browser uses,
// which does work.
//
// The cost, named rather than hidden: the window has no window.opener relationship to the
// page that asked for it and the page cannot close it, so a third-party sign-in that posts
// its result back to the opener still does not complete. That was equally true of the session
// this replaces; what changes is that the flow no longer leaves a row behind.

@class CEFShimPopupWindow;
static NSMutableArray<CEFShimPopupWindow *> *g_livePopups;

@interface CEFShimPopupWindow : NSObject <NSWindowDelegate>
+ (void)openURL:(NSString *)url
        context:(CefRefPtr<CefRequestContext>)context
          width:(int)width
         height:(int)height;
- (void)adopt:(CefRefPtr<CefBrowser>)browser;
- (void)retitle:(NSString *)title;
- (void)dismiss;
@end

class PopupClient : public CefClient,
                    public CefDisplayHandler,
                    public CefLifeSpanHandler {
 public:
  explicit PopupClient(CEFShimPopupWindow *host) : host_(host) {}

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    g_aliveBrowsers++;
    [host_ adopt:browser];
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString &url) override {
    if (frame->IsMain()) {
      // The origin, not the page's <title>: the whole reason a sign-in window has a title bar
      // is so the user can see which site is collecting the password, and a page chooses its
      // own title. Re-set on every navigation, because a sign-in flow is several.
      [host_ retitle:HostOf(url)];
    }
  }

  // A popup that opens a popup gets its own window too, by the same route.
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                     const CefString &target_url, const CefString &target_frame_name,
                     CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                     bool user_gesture, const CefPopupFeatures &popupFeatures,
                     CefWindowInfo &windowInfo, CefRefPtr<CefClient> &client,
                     CefBrowserSettings &settings, CefRefPtr<CefDictionaryValue> &extra_info,
                     bool *no_javascript_access) override;

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // true, like the session browser: the window is ours, so the teardown is ours. CEF's own
    // completion path performClose:'s the hosting window, which here would be right — but the
    // view teardown is what actually completes a close on macOS, so it stays in one place.
    [host_ dismiss];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    g_aliveBrowsers--;
    [g_livePopups removeObject:host_];
  }

 private:
  __weak CEFShimPopupWindow *host_;

  IMPLEMENT_REFCOUNTING(PopupClient);
  DISALLOW_COPY_AND_ASSIGN(PopupClient);
};

/// The size window.open asked for, or a sign-in window's shape — which is what almost every
/// popup is.
static NSSize PopupSize(const CefPopupFeatures &features) {
  return NSMakeSize(features.widthSet && features.width > 100 ? features.width : 520,
                    features.heightSet && features.height > 100 ? features.height : 660);
}

@implementation CEFShimPopupWindow {
  CefRefPtr<CefBrowser> _browser;
  NSWindow *_window;
  BOOL _closing;
}

+ (void)openURL:(NSString *)url
        context:(CefRefPtr<CefRequestContext>)context
          width:(int)width
         height:(int)height {
  NSAssert(NSThread.isMainThread, @"popup windows are main-thread only");
  CEFShimPopupWindow *host = [[CEFShimPopupWindow alloc] init];
  const NSRect frame = NSMakeRect(0, 0, width, height);
  NSWindow *window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskResizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  window.releasedWhenClosed = NO;
  window.title = HostOf(CefString(url.UTF8String));
  window.delegate = host;
  [window center];
  host->_window = window;

  CEFShimContainerView *container = [[CEFShimContainerView alloc] initWithFrame:frame];
  container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [window.contentView addSubview:container];

  if (g_automation) {
    // The driven build's promise (Automation.park): a gate run happens on a real desktop while
    // its owner is working, so nothing Synth opens may appear or take the pointer. This window
    // is opened by the shim rather than by the app, so it parks itself.
    window.alphaValue = 0;
    window.ignoresMouseEvents = YES;
    window.level = (NSWindowLevel)CGWindowLevelForKey(kCGDesktopWindowLevelKey);
    window.collectionBehavior |= NSWindowCollectionBehaviorTransient |
                                 NSWindowCollectionBehaviorIgnoresCycle;
  }

  CefWindowInfo windowInfo;
  windowInfo.SetAsChild((__bridge void *)container,
                        CefRect(0, 0, (int)width, (int)height));
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefRefPtr<PopupClient> client(new PopupClient(host));
  CefBrowserSettings settings;
  // The opener's request context, so the popup is the same signed-in browser. A sign-in window
  // with its own cookie jar is not a sign-in window.
  if (!CefBrowserHost::CreateBrowser(windowInfo, client, url.UTF8String, settings, nullptr,
                                     context)) {
    [window close];
    return;
  }
  if (!g_livePopups) {
    g_livePopups = [NSMutableArray array];
  }
  [g_livePopups addObject:host];
  // Async creation only, pumped until OnAfterCreated — the session browser's path, and the
  // reason this one works where letting CEF create the popup does not.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
  while (!host->_browser && deadline.timeIntervalSinceNow > 0) {
    CefDoMessageLoopWork();
    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                          beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  if (!host->_browser) {
    [g_livePopups removeObject:host];
    [window close];
  }
}

- (void)adopt:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  NSView *cefView = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  NSView *container = _window.contentView.subviews.firstObject ?: _window.contentView;
  cefView.frame = container.bounds;
  [container addSubview:cefView];
  [_window makeKeyAndOrderFront:nil];
}

- (void)retitle:(NSString *)title {
  if (title.length > 0) {
    _window.title = title;
  }
}

/// The page closed itself, or the runtime is shutting down.
- (void)dismiss {
  if (_closing) {
    return;
  }
  _closing = YES;
  // The session browser's teardown, for the same reasons: close completion on macOS is the
  // CEF wrapper view's dealloc, and the local pool keeps a signal-initiated quit from stalling.
  @autoreleasepool {
    if (_browser) {
      NSView *cefView = (__bridge NSView *)_browser->GetHost()->GetWindowHandle();
      [cefView removeFromSuperview];
    }
  }
  _browser = nullptr;
  _window.delegate = nil;
  [_window close];
  _window = nil;
}

/// The user closed the window. The page has to be told, or a renderer is left running behind
/// a window nobody can see.
- (BOOL)windowShouldClose:(NSWindow *)sender {
  if (_browser && !_closing) {
    _browser->GetHost()->CloseBrowser(/*force_close=*/true);
    [self dismiss];
  }
  return YES;
}

@end

bool PopupClient::OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                int popup_id, const CefString &target_url,
                                const CefString &target_frame_name,
                                CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                                bool user_gesture, const CefPopupFeatures &popupFeatures,
                                CefWindowInfo &windowInfo, CefRefPtr<CefClient> &client,
                                CefBrowserSettings &settings,
                                CefRefPtr<CefDictionaryValue> &extra_info,
                                bool *no_javascript_access) {
  NSString *url = @(target_url.ToString().c_str());
  const NSSize size = PopupSize(popupFeatures);
  CefRefPtr<CefRequestContext> context = browser->GetHost()->GetRequestContext();
  dispatch_async(dispatch_get_main_queue(), ^{
    [CEFShimPopupWindow openURL:url
                        context:context
                          width:(int)size.width
                         height:(int)size.height];
  });
  return true;
}

// One client per CEFShimBrowser, so callbacks never need first-browser filtering —
// DevTools gets AuxClient and popups are opened as windows of ours, so this client sees
// exactly one browser for its whole life.
class ShimClient : public CefClient,
                   public CefContextMenuHandler,
                   public CefDisplayHandler,
                   public CefFindHandler,
                   public CefJSDialogHandler,
                   public CefLifeSpanHandler,
                   public CefLoadHandler,
                   public CefPermissionHandler,
                   public CefRequestHandler,
                   public CefResourceRequestHandler {
 public:
  ShimClient(CEFShimBrowser *owner, const std::string &sessionId)
      : owner_(owner),
        sessionTag_("window.__synthSessionId = \"" + sessionId + "\";") {}

  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
      bool is_navigation, bool is_download, const CefString &request_initiator,
      bool &disable_default_handling) override {
    return this;
  }

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
    // Cancel, then open it ourselves — see the note above the popup window. Cancelling is what
    // keeps the opener's renderer running; the window arrives on the next main-queue turn,
    // because creating a browser pumps the loop and this is called from inside one.
    NSString *url = @(target_url.ToString().c_str());
    const NSSize size = PopupSize(popupFeatures);
    __strong CEFShimBrowser *owner = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [owner openPopup:url width:(int)size.width height:(int)size.height];
    });
    return true;
  }

  // ---- The four handlers that were missing (ADR-0011 stage five) ----------------------
  //
  // An unwired handler is not an absent feature; it is a silently broken web platform. A
  // self-signed certificate had no proceed path and basic auth had no prompt, so a local
  // HTTPS dev server and any protected staging box were simply unreachable from the pane
  // whose stated job is checking your work. alert/confirm/prompt were undefined and could
  // block the page. Camera, microphone and location were denied with no prompt and no way
  // to grant — which reads as our bug in someone else's code.
  //
  // Every one of these hands the question to Swift and keeps the page waiting. Nothing here
  // decides on the user's behalf.

  bool OnCertificateError(CefRefPtr<CefBrowser> browser, cef_errorcode_t cert_error,
                          const CefString &request_url, CefRefPtr<CefSSLInfo> ssl_info,
                          CefRefPtr<CefCallback> callback) override {
    CEFShimAsk *ask = [[CEFShimAsk alloc] init];
    ask.kind = CEFShimAskCertificate;
    ask.origin = HostOf(request_url);
    ask.detail = CertErrorReason(cert_error);
    ask->_certCallback = callback;
    [owner_ handleAsk:ask];
    return true;
  }

  // The one handler CEF calls off the UI thread. The ask has to reach the main thread (the
  // UI is there) but the callback is safe to run from wherever the answer comes back.
  bool GetAuthCredentials(CefRefPtr<CefBrowser> browser, const CefString &origin_url,
                          bool isProxy, const CefString &host, int port,
                          const CefString &realm, const CefString &scheme,
                          CefRefPtr<CefAuthCallback> callback) override {
    CEFShimAsk *ask = [[CEFShimAsk alloc] init];
    ask.kind = CEFShimAskAuth;
    ask.origin = isProxy ? [NSString stringWithFormat:@"the proxy at %@", HostOf(host)]
                         : HostOf(origin_url);
    ask.detail = realm.empty() ? nil : @(realm.ToString().c_str());
    ask->_authCallback = callback;
    __strong CEFShimBrowser *owner = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [owner handleAsk:ask];
    });
    return true;
  }

  bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString &origin_url,
                  JSDialogType dialog_type, const CefString &message_text,
                  const CefString &default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback, bool &suppress_message) override {
    CEFShimAsk *ask = [[CEFShimAsk alloc] init];
    switch (dialog_type) {
      case JSDIALOGTYPE_ALERT:   ask.kind = CEFShimAskAlert; break;
      case JSDIALOGTYPE_CONFIRM: ask.kind = CEFShimAskConfirm; break;
      case JSDIALOGTYPE_PROMPT:  ask.kind = CEFShimAskPrompt; break;
      default:                   ask.kind = CEFShimAskAlert; break;
    }
    ask.origin = HostOf(origin_url);
    ask.detail = @(message_text.ToString().c_str());
    if (dialog_type == JSDIALOGTYPE_PROMPT) {
      ask.defaultText = @(default_prompt_text.ToString().c_str());
    }
    ask->_jsCallback = callback;
    [owner_ handleAsk:ask];
    return true;
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString &message_text,
                            bool is_reload, CefRefPtr<CefJSDialogCallback> callback) override {
    CEFShimAsk *ask = [[CEFShimAsk alloc] init];
    ask.kind = CEFShimAskBeforeUnload;
    ask.origin = HostOf(browser->GetMainFrame()->GetURL());
    ask.detail = message_text.empty()
        ? (is_reload ? @"Reload this page? Changes you made may not be saved."
                     : @"Leave this page? Changes you made may not be saved.")
        : @(message_text.ToString().c_str());
    ask->_jsCallback = callback;
    [owner_ handleAsk:ask];
    return true;
  }

  // Navigation cancels whatever the old page was asking. CEF drops the callbacks itself, so
  // the surface has to come down with them or it would collect an answer nothing receives.
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override {
    [owner_ handleWithdrawPromptID:0];
  }

  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
                              const CefString &requesting_origin,
                              uint32_t requested_permissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    CEFShimAsk *ask = [[CEFShimAsk alloc] init];
    ask.kind = CEFShimAskPermission;
    ask.origin = HostOf(requesting_origin);
    ask.detail = PermissionNames(requested_permissions);
    ask->_permCallback = callback;
    ask->_promptId = prompt_id;
    [owner_ handleAsk:ask];
    return true;
  }

  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
                                 cef_permission_request_result_t result) override {
    [owner_ handleWithdrawPromptID:prompt_id];
  }

  // getUserMedia takes its own path rather than the generic prompt, and Alloy's default for
  // it is a silent deny — the exact failure this set is here to remove. Routed to the same
  // question, so the user answers it once and in one place.
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                      const CefString &requesting_origin,
                                      uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    uint32_t asked = 0;
    if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
      asked |= CEF_PERMISSION_TYPE_CAMERA_STREAM;
    }
    if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
      asked |= CEF_PERMISSION_TYPE_MIC_STREAM;
    }
    CEFShimAsk *ask = [[CEFShimAsk alloc] init];
    ask.kind = CEFShimAskPermission;
    ask.origin = HostOf(requesting_origin);
    ask.detail = PermissionNames(asked ? asked : requested_permissions);
    // CefMediaAccessCallback wants the permissions it was asked about back, so the answer
    // is wrapped rather than shared with the generic prompt's callback.
    ask->_permCallback = new MediaAccessShim(callback, requested_permissions);
    [owner_ handleAsk:ask];
    return true;
  }

  // ---- Right-click ----------------------------------------------------------------------

  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    model->Clear();
    const uint32_t type = params->GetTypeFlags();
    const uint32_t edit = params->GetEditStateFlags();

    if (type & CM_TYPEFLAG_LINK) {
      model->AddItem(kMenuOpenExternal, "Open Link in Default Browser");
      model->AddItem(kMenuCopyLink, "Copy Link Address");
      model->AddSeparator();
    }
    if ((type & CM_TYPEFLAG_MEDIA) &&
        params->GetMediaType() == CM_MEDIATYPE_IMAGE) {
      model->AddItem(kMenuCopyImage, "Copy Image Address");
      model->AddSeparator();
    }
    if (type & CM_TYPEFLAG_EDITABLE) {
      model->AddItem(MENU_ID_UNDO, "Undo");
      model->SetEnabled(MENU_ID_UNDO, (edit & CM_EDITFLAG_CAN_UNDO) != 0);
      model->AddItem(MENU_ID_REDO, "Redo");
      model->SetEnabled(MENU_ID_REDO, (edit & CM_EDITFLAG_CAN_REDO) != 0);
      model->AddSeparator();
      model->AddItem(MENU_ID_CUT, "Cut");
      model->SetEnabled(MENU_ID_CUT, (edit & CM_EDITFLAG_CAN_CUT) != 0);
      model->AddItem(MENU_ID_COPY, "Copy");
      model->SetEnabled(MENU_ID_COPY, (edit & CM_EDITFLAG_CAN_COPY) != 0);
      model->AddItem(MENU_ID_PASTE, "Paste");
      model->SetEnabled(MENU_ID_PASTE, (edit & CM_EDITFLAG_CAN_PASTE) != 0);
      model->AddItem(MENU_ID_SELECT_ALL, "Select All");
      model->SetEnabled(MENU_ID_SELECT_ALL, (edit & CM_EDITFLAG_CAN_SELECT_ALL) != 0);
      model->AddSeparator();
    } else if (!params->GetSelectionText().empty()) {
      model->AddItem(MENU_ID_COPY, "Copy");
      model->AddSeparator();
    } else if (!(type & CM_TYPEFLAG_LINK)) {
      // Plain page: history and reload, the three controls the bar already carries — reachable
      // without travelling back to it.
      model->AddItem(MENU_ID_BACK, "Back");
      model->SetEnabled(MENU_ID_BACK, browser->CanGoBack());
      model->AddItem(MENU_ID_FORWARD, "Forward");
      model->SetEnabled(MENU_ID_FORWARD, browser->CanGoForward());
      model->AddItem(MENU_ID_RELOAD, "Reload");
      model->AddSeparator();
    }
    model->AddItem(kMenuInspect, "Inspect Element");
  }

  bool RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model,
                      CefRefPtr<CefRunContextMenuCallback> callback) override {
    // The model must not outlive this call, so it is copied out before anything can be
    // displayed. Displaying runs a nested runloop, and this is called from inside
    // CefDoMessageLoopWork — so it happens on the next main-queue turn rather than here.
    NSMutableArray<CEFShimMenuItem *> *items = [NSMutableArray array];
    for (size_t i = 0; i < model->GetCount(); i++) {
      const bool separator = model->GetTypeAt(i) == MENUITEMTYPE_SEPARATOR;
      [items addObject:MenuItem(separator ? @"" : @(model->GetLabelAt(i).ToString().c_str()),
                                separator ? 0 : model->GetCommandIdAt(i),
                                separator ? YES : model->IsEnabledAt(i))];
    }
    const NSPoint point = NSMakePoint(params->GetXCoord(), params->GetYCoord());
    __strong CEFShimBrowser *owner = owner_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!owner) {
        callback->Cancel();
        return;
      }
      __block BOOL answered = NO;
      [owner.delegate cefBrowserDidRequestContextMenu:items
                                              atPoint:point
                                               choose:^(int commandID) {
        if (answered) {
          return;
        }
        answered = YES;
        if (commandID == 0) {
          callback->Cancel();
        } else {
          callback->Continue(commandID, EVENTFLAG_NONE);
        }
      }];
    });
    return true;
  }

  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params, int command_id,
                            EventFlags event_flags) override {
    switch (command_id) {
      case kMenuOpenExternal:
        [owner_ handleOpenExternal:@(params->GetLinkUrl().ToString().c_str())];
        return true;
      case kMenuCopyLink:
        CopyToPasteboard(params->GetUnfilteredLinkUrl());
        return true;
      case kMenuCopyImage:
        CopyToPasteboard(params->GetSourceUrl());
        return true;
      case kMenuInspect:
        browser->GetHost()->ShowDevTools(CefWindowInfo(), new AuxClient(),
                                         CefBrowserSettings(),
                                         CefPoint(params->GetXCoord(), params->GetYCoord()));
        return true;
      default:
        return false;
    }
  }

  // ---- HTTP basic auth, in the resource path ------------------------------------------
  //
  // GetAuthCredentials above is the seam CEF documents for this, and it stays wired — but it
  // is not what runs. Measured on CEF 144: a 401 on a top-level navigation in an Alloy-style
  // window never reaches it. Chrome's own login UI owns server authentication now, and an
  // Alloy window has nowhere to put that UI, so the challenge is dropped and the page renders
  // the empty 401 body. Which is the failure this stage exists to remove, so the challenge is
  // read off the response instead and the credential is put on the retry by hand.
  //
  // Credentials live for the browser's lifetime and no longer: Chrome doesn't persist
  // basic-auth credentials either, and a password kept in a profile that outlives the app is
  // a bigger promise than this makes.

  CefResourceRequestHandler::ReturnValue OnBeforeResourceLoad(
      CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
      CefRefPtr<CefCallback> callback) override {
    const std::string origin = OriginOf(request->GetURL().ToString());
    NSString *token = [owner_ authorizationForOrigin:origin];
    if (token) {
      request->SetHeaderByName("Authorization", token.UTF8String, /*overwrite=*/true);
    }
    return RV_CONTINUE;
  }

  bool OnResourceResponse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefRequest> request,
                          CefRefPtr<CefResponse> response) override {
    if (response->GetStatus() != 401) {
      return false;
    }
    const std::string challenge =
        response->GetHeaderByName("WWW-Authenticate").ToString();
    // Basic only. Digest and NTLM are Chromium's to negotiate, and a prompt that collected a
    // password we then sent as Basic would be worse than no prompt.
    if (challenge.rfind("Basic", 0) != 0) {
      return false;
    }
    std::string realm;
    const std::string marker = "realm=\"";
    const size_t at = challenge.find(marker);
    if (at != std::string::npos) {
      const size_t start = at + marker.size();
      const size_t end = challenge.find('"', start);
      if (end != std::string::npos) {
        realm = challenge.substr(start, end - start);
      }
    }
    const std::string origin = OriginOf(request->GetURL().ToString());
    __strong CEFShimBrowser *owner = owner_;
    NSString *realmText = realm.empty() ? nil : @(realm.c_str());
    dispatch_async(dispatch_get_main_queue(), ^{
      [owner challengeOrigin:origin realm:realmText];
    });
    return false;   // let the 401 render; the retry rides the answer
  }

  void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count,
                    const CefRect &selectionRect, int activeMatchOrdinal,
                    bool finalUpdate) override {
    [owner_ handleFindResult:activeMatchOrdinal count:count final:finalUpdate];
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
  // The sandbox is on (stage five). The helpers engage it themselves — see
  // Sources/SynthBrowserHelper/main.cc — and a helper that could not would exit rather than
  // run unsandboxed, so this browser would fail loudly rather than quietly downgrade.
  settings.no_sandbox = false;
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
  // A popup window is not a session and is not in that table, but its browser counts toward
  // g_aliveBrowsers all the same — and a survivor owns the profile singleton (spike LEARNINGS).
  for (CEFShimPopupWindow *popup in [g_livePopups copy]) {
    [popup dismiss];
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
  _context = context;

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

- (void)setZoomLevel:(double)level {
  if (_browser) {
    _browser->GetHost()->SetZoomLevel(level);
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

- (void)find:(NSString *)text
     forward:(BOOL)forward
   matchCase:(BOOL)matchCase
    findNext:(BOOL)findNext {
  if (_browser) {
    _browser->GetHost()->Find(text.UTF8String, forward, matchCase, findNext);
  }
}

- (void)stopFinding:(BOOL)activate {
  if (_browser) {
    _browser->GetHost()->StopFinding(activate);
  }
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

- (void)handleAsk:(CEFShimAsk *)ask {
  if (!self.pendingAsks) {
    self.pendingAsks = [NSMutableArray array];
  }
  [self.pendingAsks addObject:ask];
  [self.delegate cefBrowserDidAsk:ask];
}

/// CEF has taken a question back. `promptID` 0 means all of them (dialog state reset on
/// navigation); anything else is one permission prompt.
- (void)handleWithdrawPromptID:(uint64_t)promptID {
  NSArray<CEFShimAsk *> *asks = [self.pendingAsks copy];
  for (CEFShimAsk *ask in asks) {
    if (promptID != 0 && ask->_promptId != promptID) {
      continue;
    }
    [ask abandon];
    [self.pendingAsks removeObject:ask];
    [self.delegate cefBrowserDidWithdrawAsk:ask];
  }
}

- (void)handleOpenExternal:(NSString *)url {
  [self.delegate cefBrowserDidRequestOpenExternal:url];
}

- (void)openPopup:(NSString *)url width:(int)width height:(int)height {
  [CEFShimPopupWindow openURL:url context:_context width:width height:height];
}

- (nullable NSString *)authorizationForOrigin:(const std::string &)origin {
  if (origin.empty()) {
    return nil;
  }
  std::lock_guard<std::mutex> lock(_authMutex);
  const auto it = _authTokens.find(origin);
  return it == _authTokens.end() ? nil : @(it->second.c_str());
}

/// A 401 came back from `origin`. Ask once, and on an answer store the credential and reload
/// — the retry is the reload, because the response that carried the challenge is already
/// spent.
// `origin` by value, not by reference: the answer block outlives this call, and a block
// capturing a reference parameter keeps the reference rather than the string.
- (void)challengeOrigin:(std::string)origin realm:(nullable NSString *)realm {
  if (origin.empty() || _authAsking.count(origin)) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(_authMutex);
    if (_authTokens.count(origin)) {
      // Already signed in and still refused: the credential is wrong, so drop it and ask
      // again rather than reloading into the same 401 forever.
      _authTokens.erase(origin);
    }
  }
  _authAsking.insert(origin);
  CEFShimAsk *ask = [[CEFShimAsk alloc] init];
  ask.kind = CEFShimAskAuth;
  ask.origin = HostOf(CefString(origin));
  ask.detail = realm;
  __weak CEFShimBrowser *weakSelf = self;
  ask.resolve = ^(BOOL allow, NSString *user, NSString *password) {
    CEFShimBrowser *strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }
    strongSelf->_authAsking.erase(origin);
    if (!allow) {
      return;
    }
    NSString *pair = [NSString stringWithFormat:@"%@:%@", user ?: @"", password ?: @""];
    NSString *token = [@"Basic " stringByAppendingString:
        [[pair dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
    {
      std::lock_guard<std::mutex> lock(strongSelf->_authMutex);
      strongSelf->_authTokens[origin] = std::string(token.UTF8String);
    }
    if (strongSelf->_browser) {
      strongSelf->_browser->ReloadIgnoreCache();
    }
  };
  [self handleAsk:ask];
}

- (void)handleFindResult:(int)activeIndex count:(int)count final:(BOOL)finalUpdate {
  [self.delegate cefBrowserDidFindMatch:activeIndex of:count final:finalUpdate];
}

- (void)handleBeforeClose {
  _browser = nullptr;
  // A page that closed mid-question takes its callbacks with it: answering afterwards would
  // reach a request that no longer exists, and leaving the surface up would invite it.
  [self handleWithdrawPromptID:0];
  [g_liveShimBrowsers removeObject:self];
}

@end
