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

Explicit system sleep, closing the lid, logout, shutdown, and depleted battery
can still suspend or stop local execution. This feature does not wake a sleeping
Mac for future scheduled tasks or make a remote host stay awake.

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
