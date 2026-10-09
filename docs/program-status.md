# Program status

Woven Matter uses the [OSC 7501 Program Status Protocol vocabulary](https://www.superlogical.com/rex/docs/build/program-status)
(revision 0.3) for session orchestration. The five states are `idle`, `working`,
`blocked`, `done`, and `error`. `blocked.kind` is `permission`, `question`, or
`auth`. `clear` removes records; it is never a displayed state.

This is a structured projection of the specification. ACP, Pi RPC and native
service transports retain their JSON framing. We do not inject terminal escapes
into those streams or claim that a harness supports OSC 7501 on its terminal.
Pi's interactive terminal reporter does not make its RPC transport or Durable
API an OSC emitter. Our direct Pi Durable integration emits the same semantics
from its native lifecycle.

## Lifecycle and authority

`ProgramStatus` contains optional `id`, `app`, `kind`, `progress`, `title`, and
`msg`. Structured `msg` is decoded UTF-8, rather than terminal wire base64.
Every update replaces the entire record: omitted details disappear. Hierarchical
IDs use the specification's ASCII segments, depth and byte limits. `clear` with
an ID removes that subtree; root `clear` removes all of that reporter's records.
Each reporter retains at most 256 records, evicting the least recently updated.
Text is bounded and control characters are rejected. Locally generated status
text is sanitized and contains operational descriptions, not prompts, answers,
tool output, credentials or authentication payloads. There is no heartbeat.

Status is advisory execution information. A native final message, child result,
or `done` report cannot complete a parent run. Only the existing authoritative
harness settlement path can do so. While that path is active, terminal root
reports are provisional and the session remains `working`, or `blocked` when a
decision is outstanding. Child blocks contribute attention without taking over
the parent's completion authority.

Run execution facts remain separate. A confirmed cancellation maps to `idle`
with `executionStatus=cancelled`; delivery/recovery uncertainty has no fabricated
program state and retains `executionStatus=uncertain`. Native tool, delivery,
submission and database status values remain unchanged at their compatibility
boundaries. This preserves recovery and historical data.

Records are persisted by run and trusted reporter source. Incoming Pi Durable
reports must include the run ID; the coordinator rejects a different run's
report. Writes also require an active, device-owned run. Decision handlers have
independent sources, so a concurrent native `working` update cannot clear an
unresolved permission/question. Resolving a decision clears only that source.
Settled outcomes expire active records; older records cannot affect a later run.

## Harnesses

| Harness | Source of status |
| --- | --- |
| Pi Durable (direct) | Native prompt, compaction, authentication wait, child conversations and durable settlement, including attached child reports and archive completion. Child IDs are `children/<native conversation id>`. |
| Codex and Claude Code | Existing ACP prompt/settlement and permission/interaction callbacks. |
| Pi RPC | Existing settled-event fence, compaction/retry events and extension decision callbacks. |
| Cursor, Grok Build, Hermes | Existing common coordinator settlement and decision callbacks, with their native transports preserved. |
| OpenClaw ACP / Gateway | Common ACP lifecycle or confirmed Gateway outcome, plus native approval requests and resolutions. |
| OpenCode | Native full-session active/permission/form snapshots. Individual assistant message completion cannot end an active session; unresolved submissions retain uncertainty. |

Remote ACP and Durable bridges carry the same structured updates. No screen text,
spinner, silence timeout, final-message guessing or harness-specific terminal
heuristic is used for this status model. A harness can report only the details
its native transport actually exposes; we do not invent authentication waits
or progress percentages for it.

`wovenmatter sessions list/status` expose the standard `status` plus
`programStatus` (effective status, records, run ID and execution facts).
Run IDs and free-text status details follow existing transcript grants; session
discovery without those grants retains only status metadata. Advisory write
failures never fail a native run or approval response. Producers coalesce
unchanged non-blocked reports; blocked reports can repair a lost advisory write.
Every report actually received still updates record order for LRU eviction.
Coordination notifications use `done`, `error`, `idle (cancelled)` and
`blocked (kind)`. Existing session and subagent labels use the shared vocabulary;
the sidebar layout and interaction remain unchanged. Cancellation keeps its
existing feedback in the same row as `Working (cancelling)` / `Idle (cancelled)`.

## Validation

Provider-free fixtures cover whole-record replacement, subtree clearing,
validation and capacity, durable parent/child settlement, cancellation,
authentication pause/resume, ACP wire decoding, run identity fencing, persistence
across database reopen, all common harness runtime kinds, and OpenCode's native
session boundary and decision kinds. Existing permission, steering, recovery,
Gateway and remote suites exercise the surrounding contracts. Run
`scripts/test-changes.sh --all` for the repository validation gate. Live provider
acceptance is a separate manual check; fixtures never consume provider services.
