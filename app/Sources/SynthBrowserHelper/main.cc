// Entry point for CEF's helper processes (renderer/GPU/plugin/utility). Bundle
// assembly copies this one binary in as the four "Synth Helper*" apps. Sandbox is
// off to match the browser process (no cef_sandbox integration under SwiftPM).

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }

  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
