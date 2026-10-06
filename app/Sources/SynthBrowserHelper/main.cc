// Entry point for CEF's helper processes (renderer/GPU/plugin/utility). Bundle
// assembly copies this one binary in as the four "Synth Helper*" apps.
//
// The Chromium sandbox is engaged here, before anything else runs (ADR-0011 stage five). It
// was the one place in the whole capability audit where Synth was behind every competitor on
// security rather than on features, and it blocks notarization regardless. Nothing had to be
// vendored or linked for it: CefScopedSandboxContext dlopens
// libcef_sandbox.dylib out of the framework by a path relative to this executable, and the
// wrapper archive we already link carries the class.
//
// Initialize() failing is fatal on purpose. A helper that carried on unsandboxed would be a
// silent downgrade of exactly the property this is here to provide, and the browser it belongs
// to would look like it was working.

#include <map>

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_sandbox_mac.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"

// Stamps `window.__synthSessionId` on every main-frame document as its JS world is created,
// so CDPClient.attach can tell which page target is a session's from the moment there is a
// window to ask. The page theme attaches as navigation starts; anything later than this —
// load end, say — leaves a slow page unthemed for as long as it takes to load.
class SessionTagApp : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

  // CEFShimBrowser passes the id as extra_info. A cross-origin navigation can create the
  // browser here again before the old one with the same identifier is destroyed, hence the
  // count rather than a plain erase.
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDictionaryValue> extra_info) override {
    if (!extra_info || !extra_info->HasKey("synthSessionId")) {
      return;
    }
    Tag& tag = sessions_[browser->GetIdentifier()];
    tag.sessionId = extra_info->GetString("synthSessionId");
    tag.browsers += 1;
  }

  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    auto it = sessions_.find(browser->GetIdentifier());
    if (it != sessions_.end() && --it->second.browsers == 0) {
      sessions_.erase(it);
    }
  }

  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    auto it = sessions_.find(browser->GetIdentifier());
    if (!frame->IsMain() || it == sessions_.end()) {
      return;
    }
    context->GetGlobal()->SetValue("__synthSessionId",
                                   CefV8Value::CreateString(it->second.sessionId),
                                   V8_PROPERTY_ATTRIBUTE_NONE);
  }

 private:
  struct Tag {
    CefString sessionId;
    int browsers = 0;
  };
  // Renderer main thread only, which is where every callback above runs.
  std::map<int, Tag> sessions_;

  IMPLEMENT_REFCOUNTING(SessionTagApp);
};

int main(int argc, char* argv[]) {
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }

  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }

  CefMainArgs main_args(argc, argv);
  CefRefPtr<CefApp> app(new SessionTagApp);
  return CefExecuteProcess(main_args, app, nullptr);
}
