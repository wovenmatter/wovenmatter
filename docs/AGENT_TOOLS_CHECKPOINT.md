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
the current first window; do not start costly builds or foreground UI work until
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
