# Woven Matter agent tools

## Product contract

This work replaces the draft implementation in PR #40. The new branch starts at
`main` (`a345811`) and retains the existing native harness integrations. All
conversations remain ordinary sessions in their existing folders; there is no
new parent/child hierarchy or sidebar grouping.

One bundled `wovenmatter` CLI replaces `woven-note`. Every supported harness,
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
| Calendar | Read, create, update and delete events, subject to the configured access mode |
| Library | Discover/read existing retained Library items; broader Library repair is a later iteration |

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
them. Ordinary in-session timers remain distinct from provider Cron Jobs;
broader scheduled-job authoring can grow through the same command surface.

General settings provides these independent limits:

| Setting | Default | Range |
| --- | --- | --- |
| Sessions managed by one coordinator | 4 | 1–16 |
| Simultaneously running Woven Matter sessions | 16 | 1–48 |

The explanatory copy is exactly: **Maximum sessions running simultaneously.**
The count covers Woven Matter sessions, not provider-internal subagents. There
is no configurable per-destination coordinator count: the fixed rule is one.
At the active-session limit, a user send in another idle session is blocked with
a pop-up before dispatch. No limit message is sent to a harness. Existing work
and supported steering continue; there is no automatic global capacity queue.

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

## Implementation and acceptance

- [ ] Durable schema, migrations, access policies and immutable source attribution.
- [ ] Unified local/remote CLI, discovery, per-session endpoints and revocation.
- [ ] Complete observable transport capture for every harness with deterministic fixtures.
- [ ] Notes discovery/editing and retained versions; Calendar, usage and Library access.
- [ ] Session creation, messaging, exclusive coordination, grants, notifications and timers.
- [ ] Composer controls, Settings defaults/limits, attachments, receipts and hover indicators.
- [ ] Provider-free tests for migration from current main, access boundaries, retries,
      competing coordinators, fanout, lifecycle, timer recovery, queue fallback and retention.
- [ ] Required `scripts/test-changes.sh --all`, native Debug/Release verification,
      local/remote CLI exercises, rendered narrow/wide UI review and exact-head hosted CI.
- [ ] Full diff review and accurate PR handoff. No merge or release publication.

PR #40 is reference material, not the final architecture. T3 Orchestrator V2
(`1affc9a`) informs durable receipts, explicit context and app-owned scheduling;
Herdr informs concise CLI discovery/control; Codex informs same-session wakeups
and distinct read/start/steer operations. No source from those projects is copied.

## Integration checkpoint

The unified service is connected to app startup/shutdown and shared message
admission, including native OpenCode. The old exposed `woven-note` entry point
and resource have been removed. General defaults, composer controls, scoped
notes/usage reads, creation, management access and persistent timer dispatch are
wired. Native OpenCode prompts preserve original visible input and attribution
separately from discovery, and agent deliveries explicitly request steering.

Durable coordination observations produce completion, failure and needs-input
notifications once per assignment. Notification-only turns do not trigger another
completion notification. Finishing a turn leaves the assignment managed. Access
approval requests return immediately, retain their result across retries, and
cannot acquire a conflicting or disabled assignment after the user approves.
Failed or interrupted creation releases the reserved fanout slot while retaining
its target identity for recovery.

Note create/edit/restore, timer mutations and Calendar mutations now commit a
caller-bound request receipt with the write. Reusing the same request ID and
payload acknowledges the original operation across restarts without repeating
it, resetting a schedule, resurrecting a removed item or overwriting later user
edits. Reusing the ID with a different payload fails. Current capabilities and
Calendar mode are still enforced on replay. Note edit/restore replay responses
contain `replayed: true` and the original revision, without an old document that
could be adopted into the editor. Use `notes read` for the current document.
Receipts retain hashes and acknowledgements, not extra note snapshots.

The transcript now presents incoming source links and outgoing creation/message
receipts; receipt history uses insertion-order pagination. Hover cards include
permanent creation provenance and current coordination. Sidebar additions are
limited to active coordination and timer indicators. Session controls include
notification preferences, release/end coordination, and timer editing/pause/
removal. Note version history includes previews and revision-checked restoration.
Native inspection of the isolated Tools preview on 2026-09-19 confirmed the
empty workspace and General tools defaults, the 1–16 coordinator and 1–48 running
session menus, and both Calendar modes. A populated note recovery exercise
confirmed version preview, restore confirmation, live editor restoration and
retention of the replaced revision. Populated session activity, timer and
management flows still require rendered verification.

| Requirement | Implemented and checked | Remaining acceptance |
| --- | --- | --- |
| Unified CLI, seven capabilities, defaults, limits | Service routing, bound local/remote endpoints, access-policy and admission tests; bundled CLI and remote relay fixtures | Audit discovery and dispatch across all eight harnesses; composer proof |
| History and attachments | Folder-first retrieval, bounded bodies, ID references, backend grants and revocation tests | Review all native imports, steering and scheduled output paths against the capture contract |
| Notes and recovery | Bounded versions, revision-checked restore, durable mutation receipts and concurrent/reopen/revocation tests | Spreadsheet/HTML recovery and narrow-window acceptance |
| Calendar, usage, Library | Calendar mode checks, CRUD and durable retry tests; recorded usage only; explicit unavailable response for the empty Library surface | App-facing acceptance; broader Library work remains a later iteration |
| Session creation | Durable resolved configuration and target identity; transactional origin/title/folder/tools; confirmed native selections with retained progress; partial Gateway recovery; local/remote directory routing, native Hermes/OpenClaw cwd and OpenCode workspace identity fixtures | Actual ApplicationModel local/remote creation and launch-routing proof; final cross-harness audit |
| Scoped management | Durable immediate pending response, user-only resolution, shutdown cancellation, conflict/capability checks and replay tests | Render approval sheet and failure feedback; exercise app-lifetime recovery |
| Notifications | Durable completion/failure/input observations, epoch-based dedupe, revoked-assignment cancellation and notification-only loop tests | Review native turn/steering association and reconnect request identity across all harnesses |
| Bidirectional activity | Incoming attribution, larger creation cards, compact receipts, links and paged history; native OpenCode commands retain separate incoming actions with sender/outcome without guessing provider message IDs | Render narrow/wide, navigation and selection, including incoming command actions |
| Timers | Persistent exact-cadence definitions/occurrences, runtime scheduling, pause/revoke and durable mutation tests; preflight retry/backoff and no resend after possible acceptance; native editing controls | Render confirmation and icon lifecycle; verify all-harness steering/queue fallback |
| Sidebar and folders | Existing peer/folder structure retained; provenance in hover card, active indicators only | Populated and empty native visual/accessibility proof |
| Full validation | Required provider-free repository checks and unsigned Debug build passed; bundled CLI fixture passed | Final Release build, full-diff remediation, local/remote app exercises and exact-head hosted checks |

This remains a draft. The table records implementation evidence separately from
outstanding acceptance; unchecked product requirements are not waived by passing
tests. No merge, installation or release publication is part of this checkpoint.
