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

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

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
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
