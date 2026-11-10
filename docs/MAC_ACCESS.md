# Mac access

Sessions are often started from another device while nobody is at the Mac
that runs them. Nothing a session does may wait on a dialog, Keychain prompt or
password there. **Settings → Permissions & Access** (directly after General)
sets everything up once. Its lead sentence: "Agents running on this Mac or your
other devices stop and wait for a prompt here unless Woven Matter has these
permissions." Cards group the items by what they let Woven Matter do: Files and
folders (Full Disk Access), Saved sign-ins (Keychain), Control apps and see the
screen (Accessibility, Screen Recording, Automation) and Dictation (Microphone).

| Item | Why sessions need it | How it is granted | Detection |
| --- | --- | --- | --- |
| Keychain access | Saved provider, workspace and browser credentials | Enable/Restore Keychain access (below) | The existing owner-process checks |
| Full Disk Access | Files in protected folders (Desktop, Documents, Downloads, other apps' data) without a per-folder prompt | Opens Privacy & Security → Full Disk Access; macOS has no request API | Reads a file only Full Disk Access unlocks (`~/Library/Application Support/com.apple.TCC/TCC.db`, Safari bookmarks); a missing file is inconclusive |
| Accessibility | Computer Use input | `AXIsProcessTrustedWithOptions` prompt, then the pane | `AXIsProcessTrusted` |
| Screen Recording | Computer Use snapshots | `CGRequestScreenCaptureAccess`, then the pane | `CGPreflightScreenCaptureAccess` |
| Automation | Agents scripting System Events and Finder (`osascript`) | Launches System Events hidden and asks with `AEDeterminePermissionToAutomateTarget`; the pane if denied | The same call without asking; a target that is not running is inconclusive |
| Microphone | Dictation (attended) | `AVCaptureDevice.requestAccess` | `AVCaptureDevice.authorizationStatus` |

Rows show one of four statuses and refresh every two seconds while the page is
open, so a grant made in System Settings is detected without a button:

| Status | When | Action |
| --- | --- | --- |
| Allowed | macOS reports the permission granted | None; the row collapses to one line |
| Not allowed yet | Not granted, or never asked | Allow (Keychain, Automation, Microphone prompt in the app) or Open System Settings (the rest) |
| Switched off | Known denied: Microphone denied/restricted, Automation `errAEEventNotPermitted` | Open System Settings |
| Reopen to finish | Accessibility or Screen Recording was asked for this launch and still reads as off after the user returns to the app | Reopen Woven Matter (quits and relaunches the frontend) |

macOS has no "denied" signal for Full Disk Access, Accessibility or Screen
Recording, so those never claim Switched off. These presentation states are local
to the page; the published record keeps its three wire states.

**Set up all** works through every permission not yet allowed in this order:
Keychain, Full Disk Access, Automation, Microphone, Accessibility, Screen
Recording (Screen Recording last because macOS may offer Quit & Reopen). For each
it triggers the prompt or opens the System Settings pane, shows that step's hint
(Always Allow for Keychain, which item to switch on in System Settings), and
moves on once the permission reads as allowed. Ask again/Open System Settings,
Skip and Stop are available throughout; items that only a reopen can finish are
left out. With nothing left the card reads **All set**. The Settings landing row
summarizes "All allowed" or "N to allow". Dictation settings and Computer Use's
tool descriptions show a one-line status linking here instead of their own
controls.

Automation for other apps still asks the first time
an agent controls them, and that macOS dialog needs a person at the Mac; it is a
known remaining prompt, so grant frequently scripted apps ahead of time. The app declares `NSAppleEventsUsageDescription` and the hardened
runtime `com.apple.security.automation.apple-events` entitlement for these requests.

## Which process macOS attributes permissions to

TCC grants belong to the *responsible* process's code identity, not to an
executable path. Woven Matter's background server is the same signed app binary
(`Contents/MacOS/WovenMatter --backend`) started by its LaunchAgent, so it has
the app's bundle identifier and designated requirement; the frontend, the server
and every harness, shell and tool process they spawn with `Process`/`posix_spawn`
are attributed to Woven Matter. One grant therefore covers the processes that
run sessions, and checks made in either process agree. The bundled Cua driver is
spawned by the signed GUI for the same reason. Exceptions:

- Processes started over SSH, by Terminal or by another app are attributed to
  that app, not Woven Matter. Linux workspaces have no TCC.
- The closed-lid helper is a separate launchd daemon and needs no privacy access.
- Production and each Dev profile have different bundle identifiers and need
  their own grants. Ad-hoc signed Dev builds lose grants when rebuilt; use a
  stable signing identity (below).
- An OpenCode service that was started outside Woven Matter keeps its starter's
  attribution and environment.

## Status on every device

Each Mac publishes its status as `CompanionMacAccessStatus` inside its
`CompanionExecutionWorkspace` record (`macAccess`): a map from item to
`ready`/`needsAttention`/`unknown` plus the app name, with no credentials, paths
or timestamps, so only a real change bumps the record. The central Mac includes
it in its five-second registry refresh; a secondary Mac republishes on change
during its library refresh. The fields are transport-agnostic Codable values;
unknown items and states from newer Macs decode as unknown, and older Macs that
never checked report nothing. The background server combines prompt-free probes
with the last Keychain and Automation results saved by Settings
(`wovenmatter.mac-access.v1` in the app's defaults).

A session on a Mac missing Full Disk Access or Keychain access — or Accessibility
and Screen Recording when Computer Use is enabled for it — shows a quiet notice
above its composer, for example "Mac Mini is missing Full Disk Access for Woven
Matter. Open Settings → Permissions & Access on that Mac." `CompanionMacAccessStatus.sessionNotice`
produces the text for any client, so every device shows the same message.

## Password prompts fail fast

Sessions launched by Woven get an environment in which credential prompts fail
at once with a message instead of hanging a PTY:

- `sudo` resolves to a Woven `session-tools/sudo` first on `PATH`. It runs the
  real `/usr/bin/sudo -n`, so passwordless rules (Linux Full root) work unchanged
  and anything needing a password fails immediately with "This command needs
  <device>'s password…". Under Linux Normal user (`NoNewPrivileges`) it explains
  that sudo is unavailable. A `sudo -n true` probe, which runs nothing, decides
  this; the command itself runs with its output untouched (nothing is
  captured or buffered).
- `GIT_ASKPASS`, `SSH_ASKPASS` (with `SSH_ASKPASS_REQUIRE=force`) and
  `SUDO_ASKPASS` point to a helper that refuses with a message;
  `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`, `DEBIAN_FRONTEND=noninteractive`.

The scripts live in `remote/host/session-tools` and ship in the Linux host
bundle; the Mac writes byte-identical copies (a test enforces this) to
`~/Library/Application Support/Woven Matter/Session Tools`. Mac native harnesses,
Pi Durable and the OpenCode service Woven starts receive the overlay from
`WovenSessionEnvironment`; Linux sessions receive it from `wm-exec` and
`nonInteractiveSessionEnvironment` in `remote/src/config.mjs` (harnesses, Pi
Durable's worker and scheduled tasks). Macs have no Full root mode; their
sessions keep normal-user behavior.

## Keychain access and prompt policy

**Settings → Permissions & Access → Saved sign-ins → Keychain** is the single deliberate
recovery entry. Its **Allow** action shows the consent disclosure the first time and
reruns the recovery after a failure.
When macOS asks, **Always Allow** remembers access to that item; it is not a blanket
authorization for future credentials. Background checks stay noninteractive.

The row reports **Allowed** only after checking the browser encryption key,
website-password vault, saved Pi Durable/Usage items, and remote workspace keys.
The checks run in the process that owns each credential. Accepting the disclosure
alone is not proof of access. Failure or cancellation shows **Not allowed yet**
with the reason.
No credentials or Keychain values are returned to the presentation layer.

## Audited paths

| Credential or activity | Background behavior | Deliberate access |
| --- | --- | --- |
| OpenRouter usage key | Attributes-only presence checks; noninteractive secret reads; successful reads cached for the session and used by limits; device analytics does not read credentials | Saving/removing the key stays silent; Keychain recovery may authorize access |
| Claude subscriptions | Usage reads the saved Pi Durable profile; native Claude owns its credential permissions | Sign-in lives in Pi Durable and Usage settings; Permissions & Access does not probe unrelated native profiles |
| Remote workspace API token | Cached by workspace; noninteractive on service calls; denied reads are not repeated; disabling access clears the cache | Keychain recovery; provisioning, reconnect and deletion stay noninteractive |
| Codex/Grok usage limits | Saved account API reads only; no native CLI fallback during refresh | Account management lives in Usage settings; the limits page has no authentication controls |
| Browser encryption key and website passwords | Consent-gated, noninteractive preflight before CEF starts; exact-origin password vault cached in memory; writes suppress UI | Keychain recovery preauthorizes Chromium Safe Storage and the website-password vault |
| Local runtime readiness | Startup, reopen, Settings, and passive refresh resolve installed executables without starting credential-sensitive provider sessions | Installed harnesses are available without an Enable step; explicit Sign in opens only the chosen native CLI flow |
| Codex title options | No automatic session solely to discover models | Existing Refresh options action |

OpenCode service registration does not call Keychain. Existing
user-enabled service restoration and actual conversation runs can start external
provider processes; those processes own their own credential storage and system
permissions. Woven Matter's process-local suppression does not control another
process. Usage/status polling therefore must not start those processes merely
to discover account state.

## Enforcement

All app-owned `SecItem` operations use `KeychainAccess`. App startup disables
legacy login-Keychain UI process-wide, covering Chromium's asynchronous OSCrypt
calls as well as Swift callers. Browser helpers independently suppress UI before
loading CEF. Failure to install that policy blocks browser startup.

The Keychain recovery action establishes a task-local authorization scope. Wrapped
operations serialize process-wide policy changes, enable UI only inside that
scope, then restore suppression before returning. Background operations also
supply a noninteractive `LAContext`, even during recovery. A policy already
disabled before app startup remains disabled. The scope crosses backend IPC only
through the dedicated saved-credential recovery commands; normal connect/retry
commands cannot authorize UI. Recovery finishes before refresh work starts.

Browser startup requires app consent and readable Chromium Safe Storage. A denied
read blocks initialization and points to Permissions & Access rather than falling back to an
unencrypted profile or prompting from the browser. The existing shared Chromium
secret is preserved. A missing secret is generated in the format expected by the
bundled Chromium build. Website passwords use a separate Keychain item under
`wovenmatter.browser.passwords`, scoped by app bundle ID, and never enter agent
context, snapshots, diagnostics, defaults or plaintext files. Dev and production
have separate password vaults as well as separate Chromium profiles.

A denied read is different from a missing item: it must never erase a token or
imply that a user needs a replacement key. Credential values are never written
to diagnostics. Tests use
in-memory operations and synthetic credentials rather than the user's Keychain.

## Development builds

The old Dev launcher disabled signing, so each changed binary had a different
ad-hoc identity. `scripts/build_and_run.sh` now uses a unique existing Apple
Development certificate and pins its fingerprint in the build cache. Set
`WOVENMATTER_DEV_SIGNING_IDENTITY` to select an existing identity explicitly.
A previously signed cache never silently falls back to ad-hoc signing when its
identity becomes unavailable. Machines without a certificate can still build
ad-hoc; an explicit `-` opts out of certificate signing.

This does not modify Keychain ACLs, migrate or copy provider credentials, create
certificates, or weaken Keychain protection. macOS still controls initial
approval for individual items. A stable app signature permits persistent system
approval to survive compatible rebuilds; one-time Allow only authorizes the
current access. The app caches successful app-owned reads for its session. Always Allow granted
to an older ad-hoc test binary does not authorize a differently signed Dev app.
The saved app consent centralizes recovery; it cannot combine macOS approval for
distinct pre-existing Keychain items into a single OS dialog.

Apple references: [Code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[Mac Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

## Validation

Mac access tests cover the status record's wire format and notice text
(`CompanionMacAccessTests`), the page's statuses, grouping and Set up all
sequencing against fake probes (`MacAccessSetupModelTests`), the session-tools scripts with a fake sudo on both
platforms (`WovenSessionEnvironmentTests`, `remote/test/session-tools.test.mjs`)
and the environment overlays. Real TCC prompts and System Settings grants need a
person at the Mac and are verified manually.

Provider-free regression suites cover read/write suppression and policy
restoration, denied/missing credentials, concurrent operations, last-good usage
retention, one-time authorization reuse, remote-token caching, provider-scoped
CLI fallback, and
passive runtime discovery. `scripts/test-dev-signing.sh` verifies certificate
selection, persistence, ambiguity handling, and failure without identity
downgrade using fake tools. The normal full test command also builds and
validates the native app.

Browser credential tests inject synthetic Keychain operations for consent,
origin isolation, persistence, failed writes and recovery. An opt-in real CEF
fixture uses a disposable profile, mock Chromium Keychain, synthetic loopback
form and hidden window; see `docs/design/embedded-browser.md` for its command.
