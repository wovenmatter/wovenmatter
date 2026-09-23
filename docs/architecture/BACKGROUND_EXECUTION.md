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
