# Shared workspace browser

For controls, tab limits, persistence, and sharing behavior, see
[Notes and data](../guide/notes-and-data.md#browse-beside-your-work). Credential
consent, recovery, and Dev signing are documented in
[Credential access](../KEYCHAIN_ACCESS.md).

## Ownership and lifecycle

`WorkspaceAssetSession` owns ephemeral tabs independently of chats.
`DashboardAssetPane` owns pane navigation and shared toolbar controls;
`DashboardNotePane` supplies the selected note-like asset's editor.
SwiftUI redraws, reparenting, and hidden panes retain each page's AppKit view.

The runtime retains pages until CEF's `OnBeforeClose`; clients hold weak page
references, and closure releases CEF references before the owner. Creation,
navigation, and close run on the main thread. The external message pump runs in
common AppKit run-loop modes. Native quit is deferred until outside that pump.
Updates and execution-mode changes resolve unload prompts before committing a
restart, keeping CEF initialized so failed preparation can restore browsing.
Only final termination calls `CefShutdown`.

Popups preserve CEF's opener and POST navigation in the shared tab strip.
Downloads use a save dialog and never execute automatically. Helpers initialize
the macOS sandbox before loading CEF. Websites have no Woven Matter tool bridge,
remote debugging port, Node integration, or certificate-error bypass. Existing
HTML artifact WebKit isolation remains independent.

Browser Use is enabled by default and exposes Playwright operations through the
session-bound CLI and MCP. The GUI owns an automation socket beside the backend
socket, with the same private directory and kernel peer checks as backend RPC.
The backend checks the caller's current capability and persists an input digest
before dispatch. The GUI rechecks it on each native protocol command. An ephemeral
Node helper translates one owned CEF page into a token-protected loopback CDP
connection for Playwright; CEF itself has no debugging port. Native frame IDs,
utility worlds and domain cleanup preserve repeated connections and iframes.
The helper receives no CLI socket or provider credentials. Shared tabs remain
owned by ApplicationModel's WorkspaceAssetSession across pane visibility changes.

Secondary Macs inject the visible client's same asset session into their native
execution workspace and dispatch automation in process, without replacing the
central library's automation socket. Browser tabs remain accessible in the
client's Browser pane. Device-owned iPhone tools route these two capabilities to
the paired central Mac; they do not control iPhone UI. Central device execution
access is checked before acceptance and between native input steps. Cancellation
retains caller ownership and works after capability or execution-access revocation.
Automation receipts retain completion metadata, without page or desktop captures;
retries after completion inspect fresh state instead of replaying input.

Computer Use is an independent, default-off capability. Peekaboo's Swift
libraries, selected by the shared native lockfile within a compatible release
range, run inside the signed GUI process, so macOS grants apply to Woven Matter.
MCP and CLI route local and remote harnesses to this host. Screen capture returns
a bounded image and a single-use, chat-scoped frame for coordinate input; Stop or
capability revocation cancels work. Cua and cross-platform desktop hosts are deferred.

`WorkspaceVisibleContext` captures bounded note IDs/titles/revisions and browser
HTTP(S) URLs/titles at Send, marking the selected tab. URLs lose user information
and fragments. The immutable snapshot survives local/backend/remote transport;
it carries no page contents, cookies, saved passwords, or browser-control access.

## Profiles and passwords

Profiles live under Application Support/Woven Matter/Browser/<bundle ID>.
Clear Browser Data deletes the selected profile before its first use after the
next restart, with no open Chromium database handles. Saved website passwords
and Connections credentials are separate and remain intact.

CEF uses Chromium Safe Storage for encryption. Startup requires a
consent-gated, noninteractive preflight. Preserve the existing shared secret;
never replace a denied read or disable encryption. This stable SDK does not
support a custom Safe Storage service name; do not patch its binary ABI.

CEF password preferences are enabled, but its macOS child-view integration lacks
Chrome's save bubble. Woven provides native Save/Update confirmation and an
app-scoped Keychain vault. Native code independently validates the main frame's
origin; lookup/fill requires exact HTTPS scheme/host/port (HTTP loopback allowed).
Autofill rejects cross-origin form actions, iframes, new-password/confirmation
fields, and existing user input. Manual account selection may replace input.

The renderer observes standard top-level HTML form submissions and dynamic
forms. Saving requires confirmation, not inferred login success. Scripted logins
without form submission, iframe forms, and multi-step passwordless flows are
outside this implementation. There is no Chrome/Safari password import.

## Build and maintenance

`app/Browser/cef-version.json` records the exact official CEF build and archive
SHA-1 for each Mac architecture. Builds use only that record.
`scripts/prepare-browser.sh` verifies checksums, builds the wrapper/adapter, and
bundles/signs Chromium, sandboxed helpers, and license notices. CMake 3.21+ is
required; select it with `WOVENMATTER_CMAKE` if needed. Downloads use
`~/Library/Caches/WovenMatter/CEF` or `WOVENMATTER_CEF_CACHE_DIR`.
Use the normal `scripts/build_and_run.sh` and `scripts/test-changes.sh --all`.

Dependency maintenance proposes the newest stable CEF build through a PR,
because Chromium security fixes ship only on its current major
(see [the dependency policy](../DEPENDENCIES.md)). Accepting one requires
building both architectures and checking lifecycle, profile recovery, and UI
behavior. Installed apps receive it only in a signed app or refresh build. Chromium does not include
all proprietary Chrome services, codecs, or DRM. Sources:
[CEF](https://github.com/chromiumembedded/cef) and
[official binary distributions](https://cef-builds.spotifycdn.com/index.html).

## Focused validation

- Core tests cover tab limits/selection, hidden-pane retention, address handling,
  and snapshot transport. Credential tests cover persistence, origin isolation,
  failed writes, and centralized prompt policy using fake Keychain operations.
- Native lifecycle fixtures cover retained owners, unload cancellation, restart
  recovery, and deferred shutdown without loading CEF or accessing Keychain.
  The normal build validates the actual framework/helper bundles and signatures.
- The opt-in password fixture exercises real CEF against synthetic loopback
  forms, with a mock Chromium Keychain, disposable profile, and hidden window:

  ```sh
  cmake --build "$CEF_CMAKE_BUILD" --target WovenBrowserPasswordTests WovenBrowserHelper
  python3 scripts/test-browser-passwords.py "$CEF_CMAKE_BUILD" "$BUILT_APP"
  ```

  `CEF_CMAKE_BUILD` is the build's `DerivedSources/cef-<architecture>` directory.
  Only the fixture target compiles the mock-Keychain switch. Never automate
  browser tests against the user's real Keychain/profile or provider accounts.
  Live websites, signed-in sessions, and UI acceptance remain human testing.

- `scripts/test-browser-automation.py CEF_CMAKE_BUILD BUILT_APP NODE BROWSER_SCRIPT`
  runs the opt-in `WovenBrowserAutomationTests` target against real CEF/Playwright
  with the same disposable profile, hidden window and mock Keychain. It covers
  snapshots, repeated connections, form input, upload/download, screenshot,
  navigation and shutdown. Build that target before invoking the script.
  Browser MCP/CLI, capability migration, revocation, admission digests and image
  transport have provider-free tests in the normal validation suite. Human testing
  still covers signed-app TCC grants, multi-display desktop input, Stop during
  active control, and provider acceptance in each harness.
