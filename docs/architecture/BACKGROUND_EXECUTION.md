# Background execution

Background execution moves execution ownership out of the macOS window process.
The local preference is off by default. Remote workspaces have independent
preferences, enabled by default. The normal app remains the execution owner when
local background execution is disabled.

## Local ownership

The backend runs the existing application services in a headless process. It owns
SQLite writes, session transports, remote connections, scheduled task admission,
credential operations, library maintenance, and usage collection. An exclusive
workspace lease prevents a standalone app and backend from owning the same
workspace simultaneously. The frontend has a separate window-process lease.

The frontend keeps the existing observable models and rendering caches. It reads
the same SQLite database through a read-only projection and sends mutations over
a private Unix socket. Socket permissions and peer-user checks restrict access to
the current user. Credential material is never part of state snapshots.

An event-driven, bounded invalidation journal identifies changed surfaces and
conversations. Idle clients wait rather than poll the database. Restarted services
have new cursor identities, forcing a fresh projection. A failed refresh discards
the cursor so reconnect cannot silently miss the update. OpenCode transfers
session revisions rather than transcript bodies; visible sessions load through
the existing database presentation path. The backend does not render chat text.

Execution-mode changes require idle sessions and completed approvals. Admission
is fenced before shutdown. Notes flush before the frontend exits or switches
modes. Failed transitions restore the previous preference and restart its owner.
Quitting the frontend does not shut down backend-owned sessions.

## Active work and display sleep

The execution owner automatically holds a Foundation `ProcessInfo` activity with
`.userInitiated` while agent work is active. This prevents App Nap and idle system
sleep, on battery as well as external power, while allowing display sleep and
screen locking. It applies in standalone and backend modes; the frontend never
owns an assertion. Keeping the backend awake lets active work continue after the
frontend quits.

A dispatch lease starts before asynchronous session preparation and ends on every
return, error, or cancellation. Running conversation state retains the same
activity after an asynchronous send is accepted. Concurrent dispatches and runs
share one activity, released when the last finishes. Shutdown releases it and
ignores late callbacks. Idle open sessions, future calendar tasks, and merely
having background execution enabled do not keep the Mac awake.

Without the optional closed-lid settings below, explicit system sleep and closing
the lid can still suspend local execution. Logout, shutdown, and depleted battery
can stop it regardless of settings. Neither feature wakes a sleeping Mac for
future scheduled tasks or makes a remote host stay awake.

### Optional closed-lid protection

General settings contains **Keep working when the lid is closed**, with independent
**When connected to external power** and **When running on battery** switches. Both
default to off. Enabling both covers both sources; neither applies when work is
idle. The execution owner persists the policy. Frontends route changes to the
backend and display its protection snapshot, so quitting a frontend does not
release backend-owned protection.

Normal sleep assertions cannot prevent forced sleep from closing the lid or
choosing Sleep. The optional feature instead uses a bundled, privileged
`SMAppService` daemon to temporarily set macOS `SleepDisabled`, using the fixed
`/usr/bin/pmset -a disablesleep 1` operation. This also prevents Apple-menu Sleep
while protection is active; settings explain that effect. The display can still
sleep. The system-wide flag cannot distinguish Woven Matter from other software.

The signed helper is bundled at `Contents/Library/LaunchServices/WovenMatterPowerHelper`
with its daemon plist under `Contents/Library/LaunchDaemons`. It is registered only
from an explicit settings action and requires macOS approval. Task execution,
backend startup, building, and testing never register it. Ad-hoc builds cannot
enable it. The daemon and client authenticate each other with XPC code-signing
requirements for specific identifiers and the same Apple signing team; there is
no sudoers change, shell execution, or general-purpose privileged command API.

The helper serializes all power changes. Each XPC connection has a 15-second
lease, renewed every three seconds while work is active. A two-second independent
watchdog expires stale leases and reads the actual power source. Unknown power
sources release protection. Disconnecting the client releases its lease; stopping
work closes the connection. Concurrent owners share the helper and cannot release
one another's protection. `pmset` calls have bounded timeouts and verify their
result before reporting protection as active.

Before a false-to-true change, a root-owned, exclusive recovery journal is synced
to disk under `/private/var/db/wovenmatter-power-helper`. The helper restores false
before clearing that journal. A restarted daemon restores an unfinished transaction
before accepting new work; failed restoration retains the journal and is retried.
The launch daemon stays available while idle so recovery does not depend on the
UI. A pre-existing `SleepDisabled=1` is never claimed or reset. Other utilities
changing the same global flag concurrently cannot be fully coordinated.

If the helper is manually removed, denied execution, or its bundle deleted while
an override is active, automatic restoration may be unavailable. Recovery is to
restore the approved helper or have an administrator run
`sudo /usr/bin/pmset -a disablesleep 0`. That command affects the system-wide sleep
setting, including settings from other utilities; inspect `pmset -g` first.
Normal app updates must finish work before replacement. No future tasks are kept
awake merely because these preferences are enabled.

Apple's [pmset implementation](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m)
provides the system-setting mechanism. [Amphetamine Power Protect](https://github.com/x74353/Amphetamine-Power-Protect)
is a relevant reference for the additional privilege needed for reliable
closed-display behavior on Apple silicon. No Amphetamine code is included.

### Codex research

The installed Codex desktop app (ChatGPT bundle version `26.917.71314`, inspected
2026-09-27) uses Electron `powerSaveBlocker.start('prevent-app-suspension')` for
active-work sleep protection and stops the blocker when no requester needs it.
Its separate display blocker is stronger and is not needed here. A read-only
`pmset -g assertions` check during a Codex run showed an Electron
`NoIdleSleepAssertion` with no display-sleep assertion.

This behavior matches the official [Codex settings documentation](https://developers.openai.com/codex/app/settings/)
and [Electron powerSaveBlocker contract](https://www.electronjs.org/docs/latest/api/power-save-blocker).
Woven Matter uses the native [Foundation activity API](https://developer.apple.com/documentation/foundation/processinfo/beginactivity(options:reason:))
to provide the equivalent system-sleep protection and prevent App Nap. The macOS
SDK documents that `.userInitiated` includes idle-system-sleep prevention but not
idle-display-sleep prevention. No Codex code is included in Woven Matter.

## Remote ownership

Each remote workspace service owns its task schedule and durable session relay.
The Mac fences local scheduling before publishing remote ownership. Disabling
remote execution drains results and retrieves the remote schedule checkpoint
before local ownership resumes. Revisions reject obsolete schedule updates;
import receipts prevent duplicate results on reconnect.

A task is claimed durably before sending its prompt. An ambiguous interrupted
send is recorded as uncertain and is not automatically repeated. Recurring tasks
retain their session binding. Stream output is batched while accepted inputs and
terminal results use durability barriers. Idle relays use long waits, and output
wakes them immediately.

Built-in credentials keep the existing Mac-unlock boundary. A remote restart can
wait for reconnection and unlock; the gateway does not persist additional secrets
remotely. Remote services must be running on their hosts for autonomous execution.
A sleeping or powered-off host cannot execute tasks.

## Verification

Run `scripts/test-changes.sh --all` for provider-free regression checks and native
compilation. `scripts/test-backend-process.sh` exercises separate processes with
an isolated database and socket: frontend write rejection, continued backend work
after client exit, reconnect, and restart invalidation. These tests do not sign in
to providers, install login jobs, or deploy remote workspaces. Live provider and
remote-host acceptance remains separate from fixture validation.

For sleep protection, the package tests cover concurrent dispatches, asynchronous
run handoff, failures/cancellation, frontend ownership, and shutdown. On a Mac,
`pmset -g assertions` can verify the named Woven Matter idle-system assertion
while work runs and its removal after the last run. A display-off provider run
remains a separate manual acceptance check.

Closed-lid tests use fake power settings and a temporary user-owned journal. They
cover both policy switches, AC/battery changes, multiple clients, lease expiry,
helper restart, mutation/journal failures, pre-existing overrides, peer identity
validation, frontend ownership, approval waiting, and late callbacks. Native
build validation checks the bundled executable and launchd configuration without
registering or running the daemon.

Manual acceptance on a signed build remains required: approve the helper, start
a long provider run, close the lid on AC and battery according to each switch,
change power source while closed, then verify completion/stop restores sleep.
Repeat with background execution enabled and the frontend closed, and verify
recovery after terminating the owner/helper. Confirm `pmset -g` and
`pmset -g assertions` before and after each case. Do not infer hardware acceptance
from the provider-free tests.
