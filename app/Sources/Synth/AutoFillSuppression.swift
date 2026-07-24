import AppKit
import ObjectiveC

/// Neuter AppKit's password-autofill heuristic app-wide.
///
/// Whenever any editable `NSTextField` becomes first responder, AppKit runs
/// `-[NSAutoFillHeuristicController _showPasswordAutoFillIfNecessaryForView:withCompletionHandler:]`
/// to decide whether to offer a Keychain password suggestion. To find a username/password *pair* it
/// gathers every focusable key-view in the field's window — `NSHostingView._recursiveGatherAllKeyViewCandidates`
/// → `FocusNavigator.allItems` — a per-node uncached protocol-conformance walk. The key-view loop is
/// per-window, so in Synth's main window that walk crosses the whole app tree (sidebar rows + every
/// open pane) and costs **250–400ms of main-thread CPU per focus** on a loaded session: `sample`
/// clocked inline rename at ~180ms and the feedback field at similar in the gather alone. It scales
/// with the tree, so it worsens as sessions pile up — exactly the wrong shape for "blazing."
///
/// Synth has no native password/username fields: rename, feedback, settings, the ⌘K palette and the
/// browser omnibox are all plain text. (Web-content autofill lives inside CEF/WKWebView, a separate
/// path this never touches.) So the heuristic only ever burns the walk and shows nothing. Replacing
/// it with a no-op removes the stall from every native field at once — and immunises future ones —
/// where the ⌘K palette previously needed its own `NSPanel` to escape the same walk.
///
/// Guarded on the private symbols still existing; if a future macOS renames them the swizzle simply
/// doesn't install and the old walk returns (correct, just slow), never a crash.
enum AutoFillSuppression {
    static func install() {
        guard let cls = NSClassFromString("NSAutoFillHeuristicController") else { return }
        let sel = NSSelectorFromString("_showPasswordAutoFillIfNecessaryForView:withCompletionHandler:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        // Password autofill is a suggestion UI, not part of text-editing correctness — skipping the
        // gather (and the suggestion it would present) leaves the field fully editable.
        let noop: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { _, _, _ in }
        method_setImplementation(method, imp_implementationWithBlock(noop))
    }
}
