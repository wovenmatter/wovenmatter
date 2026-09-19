# Agent tools recovery checkpoint

PR #61, branch `codex/unified-agent-tools`, replaces draft #40. The complete
product contract and acceptance matrix remain in `AGENT_TOOLS.md`; nothing in
this checkpoint narrows that scope. Do not merge or publish a release from this
feature task. The shared Dev checkout belongs to the integration manager.

## Recovered creation work

The temporary checkout was lost after usage exhaustion. These changes were
reconstructed from the task history on top of pushed `3429cc2`:

- Persist the first resolved creation configuration, including inherited tools,
  model/thinking, workspace, folder, title and native working directory.
- Atomically insert origin and initial title/folder/tool policy with the session;
  a retry preserves subsequent user edits to those fields.
- Recheck source Session management access during insertion, rolling back an
  interrupted creation if access was revoked.
- Supply the native OpenCode title at creation; preserve stable native IDs.
- Recover OpenClaw by describing its stable key before creating it. Adopting an
  existing native session must not reset its working directory. Repair missing
  gateway associations before configuration or first dispatch.
- Use the native OpenClaw gateway to inherit/apply/confirm model and thinking
  selections, rather than routing that work through the generic ACP adapter.
- Keep database lock/connection private, with narrow internal `withLock` and
  `changedRowCountUnlocked` operations for database extensions.
- Keep the usage service private. The feature calls the narrow async
  `recordedUsageSamples(from:to:limit:offset:) -> [UsageSample]` entry point.
  Organization can forward this through its usage owner during integration.

Restored regressions cover local and remote reopen recovery, changed source
settings, later user title/folder/tool edits, revocation rollback, native create
payloads, missing/existing gateway recovery, and unconfirmed model selections.

## Validation status

Before the temporary-directory loss, the creation batch passed 80 focused Swift
tests. The full run reported 211 Core and 112 Client tests passing, but its final
native build result was not obtained. Those logs no longer exist. Reconstructed
source requires fresh focused and full validation; old results are not current
proof. The previous pushed `3429cc2` had passed hosted checks.

The integration manager coordinates compiler/profiling windows. Performance owns
the next window after our focused pass below; do not start costly builds or foreground UI work until
that window is released. Keep new evidence in tracked checkpoints and commit
source promptly, not exclusively in temporary files.

## Required next fixes and acceptance

1. History searches must not match their own newly journaled CLI query and prevent
   folder-first fallback. Reproduce through the actual tool service.
2. Recheck claimed delivery authority at the final transactional/backend
   submission gate after asynchronous connect/staging. Cover policy, assignment,
   timer pause/removal and shutdown revocation during those awaits.
3. Bound concurrent Swift relay forwarding and serialize replies. A stalled call
   must not block an unrelated fast one; align deadlines and prove cleanup.
4. Distinguish deterministic preflight rejection from ambiguous post-submission
   disconnect. Do not consume a one-shot timer merely because an offline harness
   rejected preparation; do not retry a possibly accepted input blindly.
5. Finish cross-harness working-location inheritance and preserve later model
   choices during partial creation. Audit native imports, raw trace correlation,
   reconnect identity, steering and scheduled outputs across all eight harnesses.
6. Solve native OpenCode slash-command attribution without guessing message IDs.
7. Finish populated native receipt/coordination/timer/access/limit flows, links,
   selection, narrow/wide layouts, accessibility and spreadsheet/HTML recovery.
8. Complete full-diff review, required provider-free checks, native Debug/Release
   builds and exact-head hosted checks. Keep PR draft until acceptance is proven.

The isolated Tools profile previously proved General defaults, both limit ranges,
Calendar modes, the empty workspace and plain-note version recovery. Its old
bundle/cache was temporary and must be rebuilt before current UI verification.
Never use production profiles or the manager-owned shared Dev for feature work.

## Source iteration after recovery (awaiting fresh validation)

- Added an app-service SwiftPM test target compiling the actual tool handler,
  socket service and remote bridge sources. A bound-socket history search fixture
  proves current/prior CLI request audit rows cannot manufacture local matches;
  explicit audit kind filters remain readable and real local hits retain priority.
- Added final transactional delivery authorization checks to attributed local
  input insertion and native OpenCode submission, plus a native command gate.
  Gateway tests deliberately suspend connect and revoke source capability,
  timer pause/removal/disable, assignment or the delivery itself before resuming.
- Retire only assignments whose coordinator or target was tombstoned/missing.
  Collector and input-observation tests retain unrelated notifications and due
  timers; real database errors still propagate.
- Timer UI edits now retain exact seconds in a draft. Round-trip fixtures include
  fractional/sub-minute/non-integral-minute intervals and intentional changes.

The recovered creation batch is local commit `81f089f`; the authority, history and
scheduler batch is `0fc465d`. Fresh focused validation passed 91 Core tests and
4 app-service tests using actual Unix sockets, concurrent Swift relay calls,
shutdown cancellation and request-identity preservation. Four Python relay tests
also pass. The old native-command fixture now reserves and claims its delivery
instead of passing an invented authorization ID.

The relay now forwards at most four simultaneous calls, serializes responses,
interrupts blocked socket work at shutdown and retains retry identity on timeout.
Local forwarding has a 55-second total budget, below the remote 75-second relay
and 90-second CLI budgets. Creation records durable confirmed-configuration
progress so a later coordination failure cannot reapply old model preferences;
the initial OpenClaw native create also uses describe-before-create recovery.

The compiler window has been released to Performance. Source work continues on
delivery acceptance stages and timer recovery; request the next window before
`scripts/test-changes.sh --all` and native builds. Native application model changes
are not covered by the focused package pass. The built-CLI timeout test likewise
awaits a fresh native bundle. No current native evidence is claimed.
The original feature goal is stored as usageLimited and cannot be resumed via
available goal APIs. The authorized integration manager continues this full
feature through its active completion goal; do not narrow scope or bypass app UI.

## Delivery acceptance checkpoint

The relay/creation-progress checkpoint is `11ad4e8`. The next source batch records
the native HTTP submission boundary durably, after authorization and before
dispatch. Old in-flight records migrate conservatively as possibly submitted.
Local ACP and Gateway input insertion remain their transactional app-acceptance
point. Confirmed native HTTP acceptance is persisted independently of refresh.

An offline failure before acceptance leaves scheduler deliveries queued under the
same identity with a 30-second retry delay. A possibly accepted request stays
uncertain and cannot be claimed again. Revocation cannot mislabel an already sent
request as cancelled. Timer occurrences advance only on accepted/cancelled
receipts; failed and uncertain outcomes keep their pending occurrence. Explicit
HTTP rejection is recorded as failed without automatic resend.

Fresh focused validation passed 93 Core tests and 4 actual app-service tests,
including a real native coordinator disconnected before HTTP, followed by lost
HTTP response and absent reconciliation. One-shot identity persists throughout;
native command 204 acceptance and lost-response no-retry are also covered.
Performance has returned the compiler window. Full `--all` and native builds are
next; the desktop is locked, so foreground native review awaits manual unlock.

## Full validation after delivery recovery

`scripts/test-changes.sh --all` passed on the acceptance batch plus relay turnover
fix: 218 Core, 112 Client, 5 actual app-service tests, 5 built-CLI tests, remote
and static checks, unsigned native Debug build and bundle validation. The relay
fixture submits a replacement request while the preceding response write is
still returning. Completed socket admission is retired before publishing the
response, with serialized bounded writer ownership and single cleanup.
The full history fixture now expects the actual message, excluding its own audit
query. Logs are `/private/tmp/wovenmatter-tools-relay-full.log` (temporary).

The compiler window is released to the integration manager after this checkpoint.
Remaining feature work is source-only: working-location inheritance, trace
correlation and native command attribution, then remaining native acceptance.
Release configuration and final exact-head hosted checks still remain.
