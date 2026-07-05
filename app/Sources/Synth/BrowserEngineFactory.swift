/// The one place an engine is chosen (ADR-0011's reversible seam, in code).
///
/// INTEGRATION SWITCH POINT — engine slice: replace the body with your `CEFEngine()`
/// (cdpPort live), keeping `WKWebViewEngine()` as the fallback if CEF fails to
/// initialise. Nothing else in the app names a concrete engine type.
@MainActor
enum BrowserEngineFactory {
    static func make() -> BrowserEngine {
        WKWebViewEngine()
    }
}
