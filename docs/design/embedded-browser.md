# Shared workspace browser

## Decisions (approved)

- Retain Swift and SwiftUI. Embed Chromium through CEF, with a narrow
  Objective-C++ AppKit adapter. No Electron, Rust subsystem or WebKit browser.
- Browser tabs and note-like assets share the existing resizable asset pane,
  its side switching, compact presentation and focus mode. The pane presents
  one chat alongside it. Tabs belong to the workspace, independent of chats.
- Allow four notes/spreadsheets/HTML assets and eight browser tabs. Reopening
  an asset selects it; capacity shows a close-first message, without eviction.
- Use native, minimal browser chrome: globe entry point, mixed tab strip,
  address/search, back, forward, reload/stop, find, and a browser menu.
- Tabs are ephemeral and disappear on exit. Browser tabs never become notes,
  sidebar entries or database assets. Hiding the pane retains its tabs.
- Use a dedicated persistent Chromium profile for cookies/site sessions.
  Provider credentials and workspace database storage remain separate.
  Website password saving and autofill are enabled. General Credential access
  owns Keychain authorization; the browser menu offers an explicit site-data reset.
- Capture one small immutable snapshot when Send is pressed: bounded note IDs,
  titles/revisions and browser URLs/titles, with the selected tab marked active.
  This travels through the normal local/backend/remote message transport.
  No page contents, screenshots, cookies, passwords or browser automation tools.
  URL awareness does not give an agent access to the signed-in browser session.
- Page sharing, browser/computer use, saved tabs and
  bookmarks are outside this pass. Normal browser use is not restricted to a
  preselected set of websites.

## Ownership and integration

Swift owns workspace tab membership, selection, limits and native toolbar UI.
Each browser page retains its AppKit container and CEF browser reference across
SwiftUI redraws and view reparenting. CEF clients hold weak references back to
pages. The runtime retains every page until `OnBeforeClose`; that callback drops
CEF references before releasing the page. CEF creation, navigation and close
run on its UI/main thread. CEF's external message pump is integrated with common
AppKit run-loop modes, including modal loops. The app's existing asynchronous
quit barrier waits for browser cleanup before allowing process exit.
Updates and execution-mode changes resolve browser unload prompts before stopping
the backend or scheduling a relaunch. This preparation blocks new tabs but keeps
CEF initialized, so failed updates can restore browsing without reinitializing
Chromium. Final process termination performs CEF shutdown.

CEF is loaded dynamically. Each Chromium helper initializes the CEF macOS
sandbox before loading the framework. No remote debugging port, sandbox bypass,
certificate-error bypass or Node bridge is exposed to websites. Website content
cannot call Woven Matter tools. Existing HTML artifact WebKit isolation stays
independent of the general-purpose browser profile.

Popups use CEF's original popup creation, preserving opener relationships and
POST navigation while placing the result in the shared tab strip. Download
requests use a save dialog and never automatically execute downloaded files.

## Build and maintenance

`app/Browser/cef-version.json` pins an official stable CEF binary distribution
for each supported Mac architecture. `scripts/prepare-browser.sh` verifies the
published archive checksum, builds the official C++ wrapper and our adapter,
and bundles/signs Chromium, helpers and license notices. CMake 3.21 or newer is
required (`brew install cmake`); `WOVENMATTER_CMAKE` can select an existing binary.
Use the normal `scripts/build_and_run.sh` and `scripts/test-changes.sh --all`.
CEF downloads are cached under `~/Library/Caches/WovenMatter/CEF`; override with
`WOVENMATTER_CEF_CACHE_DIR` for an isolated build.

Browser data lives under Application Support/Woven Matter/Browser/<bundle ID>.
Development variants have separate profiles. Clear Browser Data marks that
profile for deletion before its first use after the next restart, when Chromium
has no open database handles. It does not touch Connections, app credentials or saved website passwords.

CEF security updates require a new pinned version/checksum, rebuilding both
architectures and rerunning native lifecycle, profile and UI checks. CEF includes
Chromium, not all proprietary Chrome services/codecs/DRM; compatibility must be
described accordingly without claiming Chrome-equivalent licensed components.

## Review and validation boundary

Core tests cover independent limits, selection/close behavior, hidden-pane
retention, address handling and snapshot preservation through Codable and file
staging. Build-phase fixtures cover fresh output directories, both architecture
selections, helper bundles and signing arguments using fake tools. Adapter
lifecycle tests compile the production bridge with CEF entry points substituted:
they exercise retained owners, cancellation, failed-restart recovery and deferred
shutdown without loading Chromium, opening windows or accessing Keychain.
The normal gate builds and validates the unsigned app without launching it.
The isolated password fixture additionally exercises real Chromium against a
synthetic loopback form. Live website and UI acceptance remain human testing.

Future browser automation must use Chromium's fake Keychain and disposable
profiles, separately from the shipping adapter and user data. Ad-hoc test apps
must never access the user's real Chromium Safe Storage entry.

The pinned stable CEF uses Chromium's macOS Safe Storage Keychain service for
encryption. The browser profile itself is dedicated to Woven Matter; no browser
credential import occurs. Custom Keychain service naming is an upstream CEF
addition not present in this stable SDK. Do not patch the binary ABI or turn off
encryption to work around it.

### Website passwords

The pinned macOS CEF child-view integration does not provide Chrome's password
save bubble. Woven supplies native Save/Update and Not Now controls, with the
actual website origin visible, plus Fill Saved Password in the browser menu.
CEF password preferences are explicitly enabled. Passwords are stored in the
app-scoped Keychain vault, with no import from Chrome or Safari.

The renderer observes standard top-level HTML form submissions. Native code
validates the actual frame origin independently; lookup/fill is restricted to
exact HTTPS scheme/host/port (HTTP loopback is allowed). Cross-origin actions,
iframes, opaque URLs and insecure remote origins cannot receive passwords.
Autofill avoids new-password/confirmation fields and user-entered values;
manual account selection can replace the current form's values. Dynamic forms
are observed. Successful login is not inferred: saving requires the user's
explicit confirmation. Nonstandard scripted logins without a form submission,
iframe forms and multi-step passwordless flows are outside this implementation.
Passwords are never included in workspace snapshots or agent-visible metadata.

To run the opt-in live fixture after the normal app build:

```sh
cmake --build "$CEF_CMAKE_BUILD" --target WovenBrowserPasswordTests WovenBrowserHelper
python3 scripts/test-browser-passwords.py "$CEF_CMAKE_BUILD" "$BUILT_APP"
```

`CEF_CMAKE_BUILD` is the build's `DerivedSources/cef-<architecture>` directory.
The test-only target compiles the mock-Keychain switch into its bridge; the
shipping runtime cannot select that switch. No real credentials or provider
services are used, and the copied framework and profile are temporary.

Human review should cover mixed-tab layout, switching chats with pages open,
keyboard/focus behavior, limits, downloads and uploads, full-pane/compact
layouts, encrypted cookie recovery after restart, unload confirmation and
signed-in web apps using the user's own browser interactions.

## References

- CEF source and macOS embedding sample: https://github.com/chromiumembedded/cef
- Official build distribution: https://cef-builds.spotifycdn.com/index.html
- Mini styling/architecture reference supplied by Trey:
  https://x.com/rauchg/status/2104428800134013205

The Mini post is a visual reference; its private source was not used. The
implementation follows CEF's published embedding contracts and Woven Matter's
existing SwiftUI workspace behavior.
