// ObjC surface over the embedded CEF browser process (ADR-0011 stage one). Swift sees
// only this header; all CEF C++ stays inside the shim. One process-wide runtime
// (init once, external message pump on the main runloop, shutdown once at app exit)
// plus one CEFShimBrowser per browser session.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// What a page has put to the user, and the answer it is holding for (ADR-0011 stage five).
/// One object per question: a certificate the engine won't vouch for, an HTTP auth challenge,
/// the page's own alert/confirm/prompt, a request for the camera. Every one of these stops
/// the page until it is answered, so exactly one answer must reach it — and the shim makes
/// the second a no-op rather than a crash, because a UI can double-fire and a renderer left
/// waiting forever is the failure this whole handler set exists to remove.
typedef NS_ENUM(NSInteger, CEFShimAskKind) {
  CEFShimAskCertificate,
  CEFShimAskAuth,
  CEFShimAskAlert,
  CEFShimAskConfirm,
  CEFShimAskPrompt,
  CEFShimAskBeforeUnload,
  CEFShimAskPermission,
};

@interface CEFShimAsk : NSObject

@property(nonatomic, readonly) CEFShimAskKind kind;
/// Who is asking: the host for a certificate error or an auth challenge, the origin for a
/// JS dialog or a permission prompt.
@property(nonatomic, readonly, copy) NSString *origin;
/// The page's own words for a JS dialog; the realm for auth; what is being asked for on a
/// permission prompt; the certificate error's name for a certificate.
@property(nonatomic, readonly, copy, nullable) NSString *detail;
/// window.prompt's default value; nil for everything else.
@property(nonatomic, readonly, copy, nullable) NSString *defaultText;

- (void)allow;
- (void)allowWithText:(NSString *)text;                                  // prompt
- (void)allowWithUser:(NSString *)user password:(NSString *)password;    // auth
- (void)deny;

@end

@protocol CEFShimBrowserDelegate <NSObject>
/// Fires for every main-frame address change, including CDP-initiated navigations.
- (void)cefBrowserAddressDidChange:(NSString *)url;
- (void)cefBrowserTitleDidChange:(NSString *)title;
- (void)cefBrowserNavigationStateDidChange:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
/// window.open / target=_blank. The popup itself was already cancelled inside the shim —
/// letting it proceed blocks the renderer inside window.open() (spike LEARNINGS).
- (void)cefBrowserDidRequestPopup:(NSString *)url;
/// The page is holding for an answer. Present it and send exactly one.
- (void)cefBrowserDidAsk:(CEFShimAsk *)ask;
/// The question no longer applies — the page navigated out from under it, or CEF withdrew
/// it. Take it off screen; answering it now would reach nothing.
- (void)cefBrowserDidWithdrawAsk:(CEFShimAsk *)ask;
/// Find-in-page progress for the active query: which match is current, how many there are.
/// `finalUpdate` marks the last report for that query.
- (void)cefBrowserDidFindMatch:(int)activeIndex of:(int)count final:(BOOL)finalUpdate;
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

/// Creates the browser synchronously on `cachePath` — the workspace's profile, shared
/// with every other browser in that workspace, and a child of the runtime's
/// rootCachePath. Returns nil if the runtime isn't initialized or CEF refuses the
/// browser. `sessionId` (the Synth session's UUID) is stamped into the
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
/// Sets the page zoom level (CEF's logarithmic scale: factor = 1.2^level, 0 = 100%).
- (void)setZoomLevel:(double)level;
/// Opens Chromium DevTools for this page in its own native window.
- (void)showDevTools;
/// Closes this page's DevTools window if one is open.
- (void)closeDevTools;
/// Whether this page currently has a DevTools window open.
- (BOOL)hasDevTools;
/// Find in page. `forward`/`matchCase` apply to the search; `findNext` NO advances to the
/// next match of the same query rather than starting a new search. Results arrive on
/// cefBrowserDidFindMatch.
- (void)find:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
/// Ends the search and drops the highlights; `activate` leaves the last match selected.
- (void)stopFinding:(BOOL)activate;

/// Async close; the browser is gone shortly after.
- (void)close;

@end

NS_ASSUME_NONNULL_END
