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
the grant is created. Creating and managing a new session needs no extra grant.
Revocation blocks future reads; it cannot erase content already retrieved.

## Sessions and coordination

New sessions inherit source harness, model, reasoning, working location, folder
and tool settings unless explicitly overridden. Creation supports another
configured harness/model and another folder or workspace. Creation binds the
working location before dispatch. Provider native subagents are not redefined.

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

The unified service is now connected to app startup/shutdown and shared message
admission, including native OpenCode. Session creation, management access approval,
message receipts in storage, persistent timer dispatch, scoped notes/usage reads,
General defaults and composer toggles are wired. The old exposed `woven-note`
entry point and resource have been removed. Native OpenCode prompt projection
retains original visible input and agent attribution separately from discovery.

This remains a draft. Automatic coordinator notifications, receipt rendering,
hover/sidebar indicators, user timer/coordination management and note recovery UI
still need completion. All harness dispatch semantics, creation recovery and
location inheritance still require end-to-end fixture review; native slash-command
attribution needs special handling because that API returns no input ID. Full
repository checks, rendered native UI proof and exact-head hosted checks remain
release-readiness gates.

At this checkpoint the unsigned Debug app build and 58 provider-free Core tests
passed, covering admission reservations, scoped access, creation completion,
notification controls, timer revocation, retention, and native OpenCode prompt
projection/recovery. This is focused verification, not production acceptance.
