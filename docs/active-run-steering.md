# Active-run steering

Sending another message during a run uses the harness's native steering path. It preserves the session, working directory, model selection, tool execution and Woven Matter run identity. Several corrections can be submitted while the model continues working. Delivery occurs at the harness's next supported input boundary; Woven Matter does not cancel and restart a run to imitate steering.

## Admission and completion

A steering acknowledgement means the harness accepted the input. It does not mean the work is finished. The composer waits for admission, then becomes available for another message. Each input is saved before dispatch with its own user and assistant transcript segment. A definite rejection removes that reservation and restores the draft; an uncertain receipt retains the input so retrying cannot silently duplicate it. The run stays active until the original prompt and every admitted continuation settle. A correction that races the native turn ending can start a continuation in the same session and Woven Matter run.

Local ACP admission is serialized per conversation. The stream writer pauses at the message boundary while native acceptance is pending, and buffered transcript events resume into the accepted message's segment. Native permission and interaction requests remain serviceable before acknowledgement. An unsupported or definitively rejected steer throws back to the composer after restoring the previous transcript segment. Storage failures prevent dispatch; failures after native acceptance belong to the saved run. Tool and timer authority is checked in the same transaction that reserves the input. A completion failure remains visible as a failed run. Stop closes further admission, fences late fallback prompts, and retires the local or workspace-owned Pi process if a pending preflight could start work after cancellation. Event and permission handlers remain installed until the whole logical run finishes, including late continuations.

OpenClaw retains its durable input identities and existing uncertain-delivery recovery. A lost acknowledgement is observed under its original identity; it is not automatically resent. The remote ACP/Pi relay admits same-run inputs, shares their transcript accumulator, and waits for their terminal lifecycle before publishing recovery. Its stdio attachment keeps forwarding after an admission receipt consumes the last request ID, through the entire final output batch. Relay dispatch errors carry an explicit uncertain-delivery marker instead of pretending to be native rejections. Recovery uses input order when concurrent responses arrive out of order. Separate Built-in operation IDs allow late continuation requests to share one Woven Matter run without colliding with the original request's idempotency fingerprint. Recovery combines those operations in submission order.

## Harness paths

| Harness | Active input | Completion ownership |
| --- | --- | --- |
| Codex | Advertised `_session/steering`, backed by native `turn/steer` | Injected input belongs to the original prompt. `startedNewTurn` follows buffered `_meta.codex.threadStatus` active/idle events, including completion before acknowledgement. Adapter-only commands such as `/status` complete on their receipt because they emit no native turn lifecycle. |
| Claude Code | Advertised `_session/steering` with `idleBehavior: promptRequired` | The adapter's original prompt owns injected input; a completion race returns `promptRequired` and Woven Matter tracks the subsequent prompt. |
| Built-in | Advertised `_session/steering` over Pi's `prompt` with `streamingBehavior: steer` | The engine keeps its subscription and selected account context through native preflight and any continuation. Idle returns `promptRequired`. |
| Pi | Native RPC `prompt` with `streamingBehavior: steer` | Preflight acknowledgement, then ordered `agent_settled` or confirmed idle state. Old settlement cannot finish an input still being admitted. This avoids `steer` queuing indefinitely after a native loop has ended. |
| Cursor | Concurrent ACP `session/prompt` | Every native prompt response participates in the same run's completion. |
| Grok Build | `_x.ai/interject`; existing concurrent ACP prompt path for attachments or an unavailable extension | Native receipt or prompt completion, without cancellation. |
| Hermes | Existing native `session.steer` | Native queued receipt; original gateway run owns completion. Its current steering API accepts text, not file attachments. |
| OpenCode | `delivery: steer` on ordinary prompts and commands | Native session events/history. Delivery intent is explicit even before the activity snapshot refreshes. |
| OpenClaw | `chat.send` with `queueMode: steer` | Native admission followed by existing per-input Gateway observation and history reconciliation. |

Codex and Claude require an advertised capability. Woven Matter does not assume that an older adapter accepts concurrent prompts. The catalog minimums are Codex ACP 1.13.1 and Claude ACP 0.81.2, matching the lifecycle and idle-fallback implementations inspected for this change. Native command support and attachment restrictions remain the harness's responsibility. Codex ACP does not return a separate prompt response for detached continuations; Woven Matter observes the lifecycle it exposes. Provider errors that the adapter exposes only as text remain transcript text rather than a structured failure result.

## Implementation research

Inspected the installed Codex desktop bundle and the public sources below on September 27, 2026. Woven Matter's implementation is independent; no proprietary desktop source was copied.

- [Codex App Server: steer an active turn](https://learn.chatgpt.com/docs/app-server#steer-an-active-turn): `turn/steer` targets an active turn with `expectedTurnId`, adds input without a new `turn/started`, and returns acceptance rather than completion. The installed desktop implementation waits for startup turn identity, retains an optimistic input while admission is pending, and distinguishes rejection from uncertain delivery.
- [T3 Code](https://github.com/pingdotgg/t3code/tree/ab099178a7b7f9728843e90fc95ed90bb61d710d/apps/server/src): Claude's streaming prompt queue preserves the turn; Cursor/Grok retain pending-input ownership through overlapping submissions; Codex and OpenCode use their native delivery semantics. The transferable design is one session and logical run, native admission, and completion that accounts for all pending inputs.
- [Codex ACP server](https://github.com/agentclientprotocol/codex-acp/blob/bf37821e8f3c1f1e9b6954171855a9e2579cd2c9/src/CodexAcpServer.ts): `performSteeringRequest`, `startNewTurnFromExternalPrompt`, and `getSteerableTurnId`. It can acknowledge a detached continuation before that continuation completes. [Event handling](https://github.com/agentclientprotocol/codex-acp/blob/bf37821e8f3c1f1e9b6954171855a9e2579cd2c9/src/CodexEventHandler.ts) forwards native thread status through ACP metadata.
- [Claude ACP](https://github.com/zed-industries/claude-agent-acp/tree/e6681d2a5734857727352474c8c9aa848f9210ee): the steering extension injects into its live SDK input stream and supports `promptRequired` when idle.
- The pinned `@earendil-works/pi-coding-agent` 1.0.0 source (`dist/core/agent-session.js` and `dist/modes/rpc/rpc-mode.js`): `prompt` performs input preflight before choosing live steering or an idle start; RPC acknowledges preflight before model completion. Preflight reports `started`, `queued`, or `handled`; Built-in acknowledges only `started`/`queued` as entering the conversation.
- [OpenClaw session control protocol](https://docs.openclaw.ai/gateway/protocol/rpc-session-control) and [chat send builder](https://github.com/openclaw/openclaw/blob/main/ui/src/pages/chat/chat-send-request.ts): steering is a `chat.send` queue-mode override. The deprecated `sessions.steer` interrupt alias is unsuitable here.

## Validation and acceptance

Provider-free regressions exercise repeated corrections, rejected/unsupported input, stop, transcript boundaries, detached Codex completion before/after acknowledgement, Claude idle fallback, Cursor/Grok dispatch, Pi preflight/settlement races, ordinary OpenCode delivery, Gateway admission/rejection, storage failures before dispatch, uncertain receipts, permission revocation at admission, remote concurrent-input isolation, out-of-order completion, idempotency and recovery. Built-in tests run the actual pinned Pi loop with synthetic model streams, including immediate input during startup and a preflight that overlaps the original loop ending.

Run `scripts/test-changes.sh --all` for the complete automated suite and unsigned native build. These checks do not establish live-provider acceptance. Live review should send several corrections during a tool-using run in each installed harness, confirm acknowledgement and continued work in the same conversation, repeat near completion, and verify Stop and reconnect. No provider calls, app installation, live account authentication or production deployment are part of the automated checks.

## Async database compatibility

The steering compatibility update depends on the async workspace database facade
and `AgentDispatchFence` from PR #86. Steering reservations cross the writer lane
as value-only receipts; definite local/native refusal settles rollback through
the cancellation-independent terminal writer. After an async reservation, the
coordinator checks run ownership and Stop intent again before dispatch. The same
dispatch fence reaches the native transport after outbound history persistence,
so an input revoked before send remains a definite rejection while uncertain
receipts retain their original continuation identity.

Gateway admission errors use the dispatch fence to distinguish a queued request
that never reached the socket from a lost receipt after dispatch. Recovered-run
idle reconciliation also shares the steering admission lock and checks the input
identity captured before fetching history, so an old snapshot cannot close a
newly admitted continuation. Regression sources cover both boundaries; this
audit has performed source parsing and diff checks, without executing them.

## Detached remote outcomes

Native receipt or observation loss does not prove that a service-owned task
stopped. Actual durable routes register the run, workspace and allocated native
session identity in one transaction before dispatch. Unknown initial prompts or
continuations retain `uncertain` run/assistant status and their original input
identities. They continue to count as active work, block another initial prompt,
and remain visible even without tool activity. PR #88's Trash guard includes
this status. Local Built-in and foreground SSH runs keep their existing local
process lifecycle.

Recovery requires a fresh attachment that fences older admissions. The durable
ACP service rotates an attachment token on its serialized admission queue;
delayed messages from replaced attachments cannot reach native stdin. Built-in
uses a separate setup queue per native session, with prompt execution outside
that queue. Prompt/steering/configuration/Stop and approval replies validate
their attachment; trusted workspace shutdown has a separate cancellation path.
Stop also invalidates pending setup before it can start native execution.
Read-only polling remains available. New adapters fail closed with an update
message if an old service cannot issue the attachment capability.

Only an explicit fenced idle result for the same workspace and native session
can reconcile uncertain rows. Exact terminal snapshots restore their content;
if that authoritative idle result has no retained receipt, the run becomes
failed with a missing-result explanation. Timeouts, disconnected clients, an
old logical-run snapshot, and another session's idle result cannot clear it.
Reopening the conversation's session configuration reattaches without resending
the input. Successful scoped recovery also clears the matching failed native
Stop identity from PR #86; the outer Stop barrier still requires explicit retry.

The route marker is additive. Startup preserves marked durable runs as
uncertain and backfills older remote Built-in runs only when their saved native
identity matches the run. Older non-Built-in remote rows do not reveal whether
they used foreground SSH or the durable relay, so they retain the prior startup
policy. Do not treat upgrading an already detached, unmarked remote run as proof
of its native outcome.

This audit passed all 34 durable-relay fixtures and eight new provider-free
Built-in attachment/admission/transport fixtures. The Built-in tests used an
exact source copy in a temporary directory with already installed dependencies;
no provider or account operation ran. New Swift regressions cover preserved
first-receipt identity, startup route classification, blocked admission, plain
snapshot rejection, wrong-session/workspace rejection, and fenced terminal or
missing-receipt recovery. Those regressions and the Gateway additions still
require execution after the PR #86 dependency is combined. Source parsing and
whitespace checks pass; native/provider acceptance remains separate.
