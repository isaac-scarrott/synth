// ObjC surface over the embedded CEF browser process (ADR-0011 stage one). Swift sees
// only this header; all CEF C++ stays inside the shim. One process-wide runtime
// (init once, external message pump on the main runloop, shutdown once at app exit)
// plus one CEFShimBrowser per browser session.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol CEFShimBrowserDelegate <NSObject>
/// Fires for every main-frame address change, including CDP-initiated navigations.
- (void)cefBrowserAddressDidChange:(NSString *)url;
- (void)cefBrowserTitleDidChange:(NSString *)title;
- (void)cefBrowserNavigationStateDidChange:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
/// window.open / target=_blank. The popup itself was already cancelled inside the shim —
/// letting it proceed blocks the renderer inside window.open() (spike LEARNINGS).
- (void)cefBrowserDidRequestPopup:(NSString *)url;
/// The browser finished closing; its cache dir is safe to delete now.
- (void)cefBrowserDidClose;
@end

/// Process-wide CEF runtime. Main thread only.
@interface CEFShimRuntime : NSObject

/// One-time init. Returns NO if the app bundle lacks the CEF framework or CefInitialize
/// fails (e.g. another process owns this rootCachePath's singleton). `rootCachePath`
/// parents every session cache dir; `cdpPort` serves /json/* for all browsers.
/// `automation` adds --use-mock-keychain so harness-spawned runs never hit the macOS
/// keychain crash (spike LEARNINGS: os_crypt trap).
+ (BOOL)initializeWithRootCachePath:(NSString *)rootCachePath
                            cdpPort:(uint16_t)cdpPort
                         automation:(BOOL)automation;

+ (BOOL)isInitialized;

/// Force-closes all browsers, pumps until they are gone, then CefShutdown. Call exactly
/// once, at app termination — CEF cannot be re-initialized in the same process.
+ (void)shutdown;

@end

/// One embedded browser (one page per Synth session). Main thread only.
@interface CEFShimBrowser : NSObject

@property(nonatomic, weak, nullable) id<CEFShimBrowserDelegate> delegate;
/// Container view to parent into the pane; the CEF child view tracks its bounds.
@property(nonatomic, readonly) NSView *view;
@property(nonatomic, readonly, nullable) NSString *currentURL;
@property(nonatomic, readonly, nullable) NSString *currentTitle;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;

/// Creates the browser synchronously with an isolated cache dir (must live under the
/// runtime's rootCachePath). Returns nil if the runtime isn't initialized or CEF
/// refuses the browser. `sessionId` (the Synth session's UUID) is stamped into the
/// page as `window.__synthSessionId` on every main-frame load end, so CDP clients
/// can map page targets back to Synth sessions (ADR-0011 stage two).
- (nullable instancetype)initWithURL:(NSString *)url
                           cachePath:(NSString *)cachePath
                           sessionId:(NSString *)sessionId
                               frame:(NSRect)frame;

- (void)navigate:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
/// Opens Chromium DevTools for this page in its own native window.
- (void)showDevTools;
/// Closes this page's DevTools window if one is open.
- (void)closeDevTools;
/// Whether this page currently has a DevTools window open.
- (BOOL)hasDevTools;
/// Async close; cefBrowserDidClose fires when the browser is gone.
- (void)close;

@end

NS_ASSUME_NONNULL_END
