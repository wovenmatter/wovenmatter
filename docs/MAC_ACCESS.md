# Mac access

Sessions are often started from another machine while nobody is at the Mac
that runs them, so nothing a session does should wait on a macOS dialog there.
**Settings → Permissions & Access** grants everything once, ahead of time. It
lists five permissions, one row each, in this order:

| Permission | What it is for | How it is asked | How it is checked |
| --- | --- | --- | --- |
| Microphone | Dictation | `AVCaptureDevice.requestAccess` | `AVCaptureDevice.authorizationStatus` |
| Automation | Agents scripting System Events and Finder | Launches System Events hidden and asks with `AEDeterminePermissionToAutomateTarget`; the pane if denied | The same call without asking; a target that is not running is inconclusive |
| Full Disk Access | Files in protected folders (Desktop, Documents, Downloads, other apps' data) | Opens Privacy & Security → Full Disk Access and shows the app in Finder; macOS has no request API, so the person adds the app with + or by dragging it in | Opens a file only Full Disk Access unlocks (the TCC database, Safari bookmarks); a missing file is inconclusive |
| Accessibility | Computer Use input | `AXIsProcessTrustedWithOptions` prompt, then the pane | `AXIsProcessTrusted` |
| Screen Recording | Computer Use snapshots | `CGRequestScreenCaptureAccess`, then the pane | `CGPreflightScreenCaptureAccess` |

Each row shows a quiet "Allowed" mark or its own **Allow** button. Rows refresh
every two seconds while the page is open, so a grant made in System Settings
shows up by itself. When Accessibility or Screen Recording was asked for this
launch and still reads as off after the person comes back, the row offers
**Reopen**, which quits and reopens the app so macOS applies the change.

**Allow all** brings up each missing permission in turn: an in-app prompt moves
on once answered, a System Settings switch once it is on or when the person
comes back to the app. The Settings landing row shows "All allowed" or "N to
allow". Dictation settings and the Computer Use tool row show a one-line status
that links here instead of their own controls.

Automation for apps other than System Events and Finder still asks the first
time an agent controls them, and that dialog needs a person at the Mac. The app
declares `NSAppleEventsUsageDescription` and the hardened-runtime
`com.apple.security.automation.apple-events` entitlement for these requests.

The page saves its last results, including Automation's, in the app's user
defaults so later checks need no prompt. Linux machines have no TCC.

## Which process macOS credits

TCC grants belong to the responsible process's code identity. The background
server is the app's own signed program run as `--server` by a per-user launchd
agent, so it has the app's bundle identifier. The window, the server, and every
harness, shell and tool process the server starts are credited to Woven Matter,
and one grant covers them all. The bundled Cua Driver is started by the app for
the same reason. Exceptions:

- Processes started over SSH, from Terminal or by another app are credited to
  that app.
- Each development instance has its own bundle identifier and needs its own
  grants.

## Keychain

On a Mac the server keeps this machine's private key and its subscription
sign-ins as generic passwords in the login Keychain, under this machine's
identifier. Setting `WOVEN_SECRET_STORE=file` uses a private file in the data
folder instead, as on Linux; this suits development servers, which would
otherwise ask for Keychain access. Harness CLIs keep their own sign-ins.

The embedded browser keeps its profile in memory and saves no website
passwords. Before starting Chromium the app turns off Keychain prompts for the
whole process, and the browser refuses to start without that policy.

## Development builds

`scripts/build_and_run.sh` signs with the one Apple Development certificate in
the Keychain and remembers its fingerprint in the instance's build cache, so
macOS keeps grants across rebuilds. Set `WOVENMATTER_DEV_SIGNING_IDENTITY` to a
fingerprint to choose one when there are several, or to `-` to build unsigned,
in which case grants reset on every rebuild.

## Testing

Real TCC prompts and System Settings grants need a person at the Mac and are
checked by hand.
