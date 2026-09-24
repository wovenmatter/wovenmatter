# Woven Matter agent tools

Woven Matter exposes app data and session actions through its bundled CLI.
Conversations remain ordinary sessions in their existing folders.

The bundled `wovenmatter` CLI replaces `woven-note`. Every supported harness,
locally and in managed remote workspaces, receives a session-bound invocation
and compact discovery instructions. Commands call the owning app's services;
agents do not receive unrestricted SQL or credentials. Capability checks are
enforced at the service, not only described in prompts. Help is available without
loading unrelated history or tool documentation into the conversation.

## Tools and access

The composer has a compact Tools dropdown with seven independent groups:

| Group | Contract |
| --- | --- |
| Notes | Discover, read, create and edit notes, spreadsheets and HTML; retained version recovery |
| Conversation history | Search and selectively read conversations and full observed traces |
| Session management | Discover session metadata, create sessions, message, inspect managed sessions and manage coordination |
| Timers | Create, inspect, update, pause, resume and remove persistent session follow-ups |
| Usage data | Read recorded usage; no mutation or credential access |
| Calendar | Read, create, edit, copy, detach and delete events and scheduled tasks, subject to the configured access mode |
| Library | Reports that retained items are unavailable; Library storage is not implemented yet |

All groups initially default to enabled. General settings, below Conversation
titles, defines defaults for newly opened sessions. Session controls enable or
disable groups without changing the General defaults. Calendar defaults to Full
access, with Read only configurable in General; the composer indicates the mode
but does not change it. Usage data is always read-only.

History enabled permits relevant retrieval at the agent's discretion or at the
user's instruction. Nothing preloads the complete database or entire transcripts.
Search starts in the current folder, then broadens when no match is found; All
Workspace searches globally. Results include stable IDs, locations, harnesses,
activity/status and bounded excerpts so the agent can resolve ambiguous names.

The plus-button conversation attachment sends a session reference, never a full
transcript. It grants read-only access to that specific session even if history
is disabled, and the UI explains that exception. A plain pasted ID does not
create an attachment grant. With Session management enabled, metadata/status and
messaging are available independently of history. An active coordinator may
read its managed sessions. With history disabled, managing an existing,
unattached session requires an actual user confirmation in Woven Matter before
the grant is created. The CLI returns a durable pending request immediately; retries
with the same request ID inspect that request instead of opening another sheet.
Approval rechecks ownership, fanout and current capability. App shutdown cancels
unanswered approvals. Creating and managing a new session needs no extra grant.
Revocation blocks future reads; it cannot erase content already retrieved.

## Sessions and coordination

New sessions inherit the source harness, working location, and folder unless
explicitly overridden. A Buzz source uses the selected local or remote destination
root; this command does not create Buzz-bound sessions. Model and thinking accept
the existing explicit creation arguments. Remaining selections resolve from the
user's destination workspace/harness defaults, harness defaults, and native
defaults, in that order. The source chat's selections do not become defaults for
the new chat. General Agent tools settings supply the native tool fallback.

Permissions and tools come from user controls and cannot be overridden by agent
commands. A user-saved empty Tools default disables every tool group for new chats
in that scope. Creation binds the working location before resolving defaults and
freezes every choice with the request, so retries survive changed defaults.
Native settings must be accepted before the initial instruction is sent. Provider
native subagents are not redefined.

An agent-created work session is coordinated by its creator unless explicitly
requested as independent. Existing sessions become managed only on an explicit
manage/monitor action. One-off status checks or conditional messages do not
establish coordination. Exactly one session may coordinate a destination at a
time. A competing request fails with a CLI error identifying the coordinator.
Coordination can end explicitly, when the coordinator declares the assignment
complete, or from a user control; creation provenance is permanent.

Messages use normal session dispatch, with durable backend-bound source identity,
retry protection, and agent-authored context. Steering is used when supported;
otherwise messages queue for the next turn. Never kill a run to deliver a message.
Agent-authored incoming messages show a clickable sender session/harness. A
creation action produces a larger outgoing card with purpose, destination,
harness/model/status and coordination intent. Later sends have compact outgoing
receipts with destination details and a link. Both directions remain inspectable.

Managed-session completion, failure and needs-input events notify the coordinator
by default, with notification controls. A notification steers an active session
or wakes an idle one. A finished turn is not automatically a completed assignment.
Deliver notifications once, preserve attribution, and prevent notification-only
reply loops. The user retains ownership of permission approvals.

The conversation hover pop-out shows Created by only for agent-created sessions
and Managed by only while coordination is active. Creation has no sidebar icon.
Minimal sidebar indicators show active coordination and active timers only.
All existing folder organization/moving behavior remains intact.

## Timers and concurrency

Timers return to a session with a saved instruction, supporting one-time and
recurring follow-ups. Definitions persist, but execute only while Woven Matter
is running. Pausing, disabling or deleting removes active timer indicators.
Disabling the Timers group with active timers asks the user to confirm pausing
them. Ordinary in-session timers remain distinct from provider Cron Jobs and
Calendar tasks that create or reuse a configured session.

General settings provides these independent limits:

| Setting | Default | Range |
| --- | --- | --- |
| Sessions managed by one coordinator | 4 | 1–16 |
| Simultaneously running Woven Matter sessions | 16 | 1–48 |

The running-session count covers Woven Matter sessions, not provider-internal
subagents. There is no configurable per-destination coordinator count: the fixed rule is one.
At the active-session limit, a user send in another idle session is blocked with
a pop-up before dispatch. No limit message is sent to a harness. Existing work
and supported steering continue. Calendar tasks wait for capacity and an idle
destination; ordinary user sends do not enter an automatic capacity queue.

## Calendar events and scheduled tasks

`wovenmatter calendar help` describes the shared Calendar command surface.
`create` and `update` accept a title, description, start/end, all-day or timed
status, time zone, and `--repeat-unit day|week|month` with `--repeat-interval`.
Add `--prompt` to schedule a normal agent session. Task configuration supports
`--harness`, `--model`, `--thinking`, `--workspace local|UUID`, `--directory`,
`--folder UUID|all`, and `--session-mode same|new`. Creation requires both
Calendar write access and Session management. Permissions and tools are
captured from user-owned session defaults, and can be changed by the user in
the Calendar editor; an agent cannot raise these through CLI flags.

Updates preserve unspecified settings. `--regular-event` removes execution;
`--no-repeat` removes recurrence. `update` changes the entire series. To edit
one occurrence, use `detach ID --occurrence N`; the resulting independent event
keeps the settings and creator, records the editor, and no longer repeats. There
is no linked single-occurrence override. `copy ID --starts-at ISO_DATE` creates
a new one-time event. `remove` deletes the series, or only `--occurrence N`.

`read ID` returns the event, revision, attribution, and run-to-session links.
Pass `--revision` to reject stale updates/deletions. `list` returns paginated
definitions; recurring definitions can span the requested range. Use
`occurrences ID --since ISO_DATE --until ISO_DATE` for the actual occurrence
indices in a window of at most one year.

Calendar tasks persist through restarts. Every overdue independent task runs;
each recurring series catches up once. The default recurring mode reuses one
session, with an option to create a new session for every occurrence. Durable
receipts prevent duplicate submissions. A lost native acknowledgement remains
uncertain and is never blindly retried; later recurring occurrences still run.
Edits and deletion cancel pending sends before transport starts, and completed
sessions remain accessible after event deletion.

## Capture, recovery and compatibility

Preserve observable original protocol data for all eight harnesses, including
native OpenCode and Hermes paths, imports, steering, reconnects and scheduled
results. Exclude authentication material. Retain provenance and honest partial
coverage for older data; never invent unobserved historical frames.

Use the existing workspace database with transactional migrations and bounded
reads. Note versions cover notes, spreadsheets and HTML, with before/after agent
edits, coalesced editor checkpoints, conflict-safe restore and count/byte budgets.
Do not version externally linked data files. Reference retention remains separate
from event journal retention and should be described honestly.

## Retry behavior

Note create/edit/restore, timer mutations and Calendar mutations commit a
caller-bound request receipt with the write. Reusing the same request ID and
payload acknowledges the original operation across restarts without repeating
it, resetting a schedule, resurrecting a removed item or overwriting later user
edits. Reusing the ID with a different payload fails. Current capabilities and
Calendar mode are still enforced on replay. Note edit/restore replay responses
contain `replayed: true` and the original revision, without an old document that
could be adopted into the editor. Use `notes read` for the current document.
Receipts retain hashes and acknowledgements, not extra note snapshots.

## Validation boundaries

`scripts/test-changes.sh --all` exercises provider-free transport fixtures,
access policies, migrations, mutation retries, timer recovery, note retention,
local sockets, the remote relay, and the bundled CLI. It also builds and validates
an unsigned native app. The interactive hover fixture runs separately through
`scripts/test-conversation-popover.sh`.

Fixtures do not establish live provider compatibility or rendered UI behavior.
Before release, check the session settings and local/remote workflows you use,
including attachments, timer delivery, permission requests, and note recovery.
Older imported history remains partial, and Library storage is unavailable.
