# Embedded browser and Computer Use

For the browser's controls, see
[Notes and data](../guide/notes-and-data.md#browse-beside-your-work). Permissions
are in [Mac access](../MAC_ACCESS.md).

## Ownership

`WorkspaceAssetSession` owns the browser tabs, independently of chats, so
switching chats, resizing or hiding the pane never destroys a page. `AssetPane`
draws the tab strip and toolbar; `DesktopNotePane` supplies the note editor.
Up to ten browser tabs can be open. Popups open as tabs in the same strip.

The browser is Chromium through CEF (`app/Browser`). Helpers start the macOS
sandbox before loading CEF. Pages have no Woven bridge, no remote debugging
port and no certificate-error bypass. A download the person starts uses a save
dialog and never opens by itself.

## Profile and passwords

The browser runs on an in-memory profile, so cookies and site data last only
until the app quits. Website passwords are not saved or filled. Before
starting Chromium the app turns off Keychain prompts for the whole process, and
the bridge refuses to start without that policy.

## Agents

The Woven MCP's `browser` and `computer` tools are defined once in the server
(`server/Sources/WovenServerKit/Tools/Catalog.swift`). Because macOS ties these
permissions to the app, the server hands each call to the newest connected UI
on its own Mac and waits up to 90 seconds for the answer; with no UI connected
the call fails at once. A Linux machine has no UI, so these tools fail there.
`WovenAutomationHost` carries out one call at a time, stops an action after 25
seconds and refuses results over 1 MiB.

- **browser** drives the tabs in that Mac's window; the person sees them. For
  each action the app runs the bundled Node with `browser-runtime.mjs` from
  `default-agent/`, which drives the one page with Playwright over CDP that the
  app relays to CEF. The helper gets only that page. Agent downloads go to a
  private temporary folder under opaque identifiers.
- **computer** controls the Mac's apps through the bundled Cua Driver
  (`app/Automation/cua-version.json` records its release and checksums). The
  app starts the driver itself so macOS credits its grants to Woven Matter,
  gives each session its own connection, and never hands agents the driver's
  socket. Every action except `status` needs Screen Recording and
  Accessibility.

When the person sends a message with the pane open, `WorkspaceVisibleContext`
records the open artifacts (id, title, kind, last edit) and browser tabs (HTTP(S) URL
without user information or fragment, and title), marking the selected tab. It
carries no artifact or web page contents, and no cookies.

## Build and maintenance

`app/Browser/cef-version.json` records the exact CEF build and each Mac
architecture's archive SHA-1; builds use only that record.
`scripts/prepare-browser.sh` downloads and checks the archive, builds the
wrapper and bridge, and bundles and signs Chromium, the helpers and license
notices. It needs CMake 3.21 or later (`WOVENMATTER_CMAKE` selects one) and
caches downloads in `~/Library/Caches/WovenMatter/CEF` or
`WOVENMATTER_CEF_CACHE_DIR`. The app's Xcode build runs it.

Dependency maintenance moves to the newest stable CEF, because Chromium ships
security fixes only on its current major (see
[the dependency policy](../DEPENDENCIES.md)). Chromium lacks some proprietary
Chrome services, codecs and DRM.

## Tests

The CMake project has opt-in fixtures that are not part of the normal build:
`WovenBrowserLifecycleTests`, which never loads Chromium, and
`WovenBrowserPasswordTests` and `WovenBrowserAutomationTests`, which run real
CEF with a disposable profile, a mock Keychain and a hidden window.
`scripts/test-browser-passwords.py` and `scripts/test-browser-automation.py`
run the last two against a built app. Never point browser tests at the person's
own Keychain, profile or provider accounts.
