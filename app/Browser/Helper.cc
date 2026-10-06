#include "include/cef_app.h"
#include "PasswordRenderer.h"
#include <Security/Security.h>
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

// The sandbox must be initialized before loading Chromium in every helper.
int main(int argc, char** argv) {
  // Child processes must never open credential authorization UI.
  if (SecKeychainSetUserInteractionAllowed(false) != errSecSuccess) return 1;
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  return CefExecuteProcess(CefMainArgs(argc, argv), WovenPasswordRendererApp(), nullptr);
}
