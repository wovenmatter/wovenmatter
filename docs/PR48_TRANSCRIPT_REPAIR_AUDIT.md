# PR 48 review and transcript repair audit

## Final review fixes

The full PR diff was reviewed from `ed2777a` in a fresh worktree, including
stream projection, cancellation, configuration, database reconciliation,
transcript rendering, and the accompanying provider-free tests.

- Activity sorting now keeps native positioned records in a consistent group.
  Mixing native positions with pairwise timestamp fallback could form a sorting
  cycle and scramble the transcript.
- OpenClaw history uses native sequence order when the entire group supplies it;
  otherwise it consistently uses timestamps. A regression demonstrated that
  mixing those rules could leave commentary in the visible final reply.
- Hydration requires the persisted input identity to match as well as the native
  message and Gateway run. A complete record for another input cannot replace a
  marked preview, including when both inputs share a Gateway execution.
- Hermes prefill, exec, and plugin commands report cancellation when Stop occurs
  during feedback or configuration refresh. They no longer report success after
  a cancelled command.

Each defect was reproduced by a failing provider-free regression before its fix.
The cancellation case covers all five command outcomes during dispatch and
feedback. The original repair evidence below remains useful context; its test
counts describe earlier checkpoints, not this final review.

Final validation: `scripts/test-changes.sh --all` passed with 266 Swift tests
(161 core/store and 105 client), 50 remote passes and one environment-dependent
skip, static/editor checks, macOS compilation, and native bundle validation.
An isolated `PR48Audit` variant with fabricated data passed native inspection of
empty and populated views, nested tool expansion and scrolling, visible final
answers, and Latest reply at standard and maximized window sizes. Shared Dev was
not restarted. Live provider acceptance remains for user testing; these checks
do not establish eight real provider integrations end to end.

## Earlier transcript repair evidence

September 16, 2026. Source audit and provider-free validation; no provider prompts,
shared Dev restarts, or modifications to user runtime data.

## Evidence and OpenClaw repair

The recorded Gateway payload shapes were checked against retained SQLite anchors
using a read-only connection. Tools have native call IDs shared by call/result
records. Commentary has `openclawStreamFallback` / commentary idempotency metadata;
final records carry native identity and a final idempotency suffix. The recorded
long final was marked `__openclaw.truncated=true, reason=display-cap` in history.
Tests use fabricated text, IDs and timestamps in those shapes, not transcripts.

History requests ask for 500,000 characters. Marked previews are hydrated through
`chat.message.get`, one request at a time, with cancellation and connection
checks. Only matching complete native records replace a preview. Unavailable or
still-truncated records retain their marked raw payload and cannot replace an
existing complete body. The 500,000-character bound is deliberate; this does not
promise arbitrary-size full-message retrieval. Current upstream in-flight history
budgeting includes all text or empty text; explicit truncation metadata is also
rejected by recovery. Empty snapshots do not erase a received body.

Native anchors remain distinct. Persisted input identity wins over the broader
Gateway run ID. Explicit commentary and mixed text/tool blocks enter the ordered
work transcript; ordinary distinct assistant records retain their own messages.
Historical tools merge through native call IDs with live activities. References
and attachments move to the reply owner before obsolete history-only rows are
removed. Local run-owned rows are retained. Only affected run groups are rebuilt;
parsed activities are cached during reconstruction. Tool calls without a result
have unknown status rather than fabricated success.

Payload sequences are sparse across individual streams and chat snapshots.
Their watermarks still reject replay, but spacing does not trigger recovery.
The existing outer WebSocket frame sequence-gap recovery and durable atomic
projection remain unchanged.

Expanded work is capped at 420 points and scrolls independently. Outer and nested
disclosures release conversation bottom-follow before changing geometry. Initial
conversation placement remains bottom-aligned; content resizing uses top
anchoring. Existing colors, labels and tool rendering remain in use. Exact visual
position across all window sizes still requires the manager's shared Dev smoke
check; compilation and source inspection are not that acceptance.

## Eight harness paths

| Harness | Live path | Saved / recovered path | Result |
| --- | --- | --- | --- |
| Codex | `LocalACPClient.projectedEvent`: separate message chunks and tool activities | Shared ACP persistence retains run activities; session load uses ACP updates | No tool-to-assistant conversion found; unchanged |
| Claude Code | Same ACP projection | Same shared persistence and supported session load | No confirmed issue; unchanged |
| Grok Build | Same ACP projection | Same shared persistence and supported session load | No confirmed issue; unchanged |
| Cursor | Same ACP projection | Same shared persistence and supported session load | No confirmed issue; unchanged |
| OpenClaw | Native Gateway tool activities | History previously emitted `**Tool:**` assistant text and empty result messages | Repaired as above |
| Hermes | `tool.start` / `tool.complete` produce activities in `HermesGatewayClient` | Native session export previously appended `tool_calls` JSON to assistant text and displayed tool results as messages | Import-only correction: call/result IDs, raw payloads and reasoning become activities; reply text stays text |
| OpenCode | Ordered native snapshot parts | `OpenCodeSessionSnapshot.activities` preserves tool parts and native IDs | No confirmed conversion; unchanged |
| Pi | `tool_execution_*` emits activities; assistant extraction reads text blocks | Shared persisted activities; native session reuse is handled by the Pi client | Read-only audit here; slash-command settlement, cancellation and reuse belong to the separate Pi task |

Hermes export ordering and supplied call IDs determine result ownership. An
unmatched result attaches to the preceding assistant, or a dedicated activity
owner if no assistant exists. The import retains raw result data; it does not
invent native call IDs when one is absent. This correction applies to new imports;
already-imported Hermes rows cannot be rebuilt losslessly without their original
export and are not silently migrated. No Hermes runtime/provider acceptance was
performed.

Shared successful activity-only completion no longer fabricates “completed
without a text response.” The reply row and its references remain; activities
render in the work transcript and the empty assistant body is omitted. Failure
text and cancellation paths remain intact.

## Validation

- `scripts/test-changes.sh --all` completed static and remote tests; its first
  package run caught steering/single-final reconciliation regressions, which were
  corrected rather than changing those existing expectations.
- `WOVENMATTER_TEST_CACHE_DIR=/private/tmp/wm-pr48-openclaw-validation scripts/test-changes.sh --macos`
  passed static checks, 253 package tests, isolated app compilation and native
  bundle validation.
- Subsequent targeted tests cover incremental tool pages with mixed prose,
  failed-result replay, Hermes call/result merging, hydration identity, late
  previews, reopen, cold history and activity-only completion.
- Final source changes were checked again with the OpenClaw/Hermes suites and
  incremental isolated app compilation. No shared Dev build or launch occurred.

## Follow-up: audit and preamble mirrors

The manager's Dev smoke exposed audit fallback duplicates after the original
repair. Upstream `src/audit/agent-event-audit.ts` hashes the native call ID with
SHA-256; Woven had compared that digest against its run-scoped live ID. Read-only
comparison proved all 18 saved audit digests matched native calls in the recorded
run. Audit ingestion now resolves that bridge using both live and persisted tool
IDs and merges results into the canonical activity, including failed results for
unfinished calls. History refresh removes only proven digest equivalents,
retaining native payloads/state and unmatched audit records.

Preamble thought rows are reconciled only when their scoped item ID matches an
explicit native commentary item ID, their text matches, and their raw event says
`kind=preamble`. The commentary retains raw provenance across subsequent refresh.
Unmatched thoughts remain. Provider-free tests cover both mirrors, richer native
payload retention, failure settlement, unmatched records, and database reopen.
