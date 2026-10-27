# Streaming verification

Streaming has three independently verifiable boundaries: provider/adapter wire,
Woven's event projection and persistence, and the rendered desktop/mobile transcript.
A passing wire probe does not establish a UI pass. A synthetic provider fixture
does not establish that an account or model is currently available.

## T3 comparison and upstream boundary

The source audit used `pingdotgg/t3code` at commit
[`68339a084644540f176ce83d97dd4c768b65b52e`](https://github.com/pingdotgg/t3code/tree/68339a084644540f176ce83d97dd4c768b65b52e).
The comparison is pinned to that source, rather than a claim about a later T3 release.

| T3 source finding | Woven implementation/verification consequence |
| --- | --- |
| [`CodexAdapterV2.ts`](https://github.com/pingdotgg/t3code/blob/68339a084644540f176ce83d97dd4c768b65b52e/apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts) allocates reasoning identities from turn, item, summary/content stream and index, reserving order before delayed flushes; command output is incremental | Preserve native message identities and ordered work entries; append terminal output deltas rather than replacing preceding output |
| [`provider-opencode/v2/adapter.ts`](https://github.com/pingdotgg/t3code/blob/68339a084644540f176ce83d97dd4c768b65b52e/packages/provider-opencode/src/server/v2/adapter.ts) consumes `session.text.*`, `session.reasoning.*` and tool input/progress events, identifying blocks by assistant message, kind and ordinal | Subscribe to OpenCode's live `/api/event` stream in addition to durable history; maintain transient block projections and reconcile them with persisted snapshots |
| [`assistantStreaming.ts`](https://github.com/pingdotgg/t3code/blob/68339a084644540f176ce83d97dd4c768b65b52e/apps/server/src/orchestration-v2/assistantStreaming.ts) separates complete Markdown sections from an unfinished tail, respecting headings, lists and fenced code | Preserve stable rendered Markdown while showing the live tail; test partial fences, paragraph boundaries and terminal settlement |

There is a concrete Codex ACP upstream limit. Inspection of the installed adapter's
`dist/index.js` found both `item/reasoning/summaryTextDelta` and
`item/reasoning/textDelta` routed to `createReasoningDeltaEvent`, which emits
`agent_thought_chunk` with `messageId = itemId` and the supplied delta. It drops
the original stream kind and `summaryIndex`/`contentIndex`. Woven preserves the
text and identity that ACP supplies, but cannot reconstruct that discarded
summary/content distinction. Full parity with T3's direct Codex stream identity
requires the adapter to retain those fields or a transport that exposes them.
No test or UI change here claims to recover information absent from the wire.

## Repeatable offline contract matrix

Run `node scripts/streaming-contracts.mjs --portable` for the JavaScript contracts,
`--native` for the Swift contracts, or `--all` for both. `--skip-build` reuses already
compiled Swift tests. `--output /absolute/report.json` writes suite results and
durations. The runner uses the same frozen Swift resolution and validation cache
conventions as `scripts/test-changes.sh`. Install the committed Node graph with
`npm ci --prefix default-agent --ignore-scripts --no-audit --no-fund` first.

The manifest names actual suites rather than treating source-code pattern matches
as behavioral tests. No contract suite consumes a provider service.

| Boundary | Suites | Contract |
| --- | --- | --- |
| Pi Durable native engine | `native-message-stream`, `native-tool-stream`, `durable-engine` | Ordered text/thinking blocks, pending tool arguments, running tool output, snapshot replacement/removal, Unicode, completion, partial provider failure, and cancellation |
| Claude native translation | `claude-native-session` | Synthetic Anthropic SSE translation and native continuation, including signed thinking and tool validation |
| iOS inference bridge | `ios-inference-stream` | Actual bridge retains partial text/thinking/usage on disconnect, cancellation and missing terminal; ignores duplicate terminal frames |
| Remote execution | `durable-acp`, `task-gateway`, `client-execution-publisher` | Recovery replay, assistant snapshots, lost receipts, immutable event deduplication, persistence failures, reconnect while approval is pending |
| Swift ACP adapters | `ACPHarnessStreamingReviewTests` | Actual client fed fixture processes; reasoning phases, assistant snapshots, boundaries, model/thinking selection and tool deltas |
| Swift OpenCode | `OpenCodeLiveProjectionTests`, `OpenCodeIntegrationTests`, `OpenCodeWireCaptureTests` | Live event reduction, message identity, durable refresh/recovery, HTTP/SSE recording without credentials |
| Transcript persistence/presentation | `ACPAssistantStreamWriterTests`, `AssistantStreamingTextTests`, `ConversationWorkTimelineTests`, `StreamingPresentationTests` | Canonical prefixes, stable Markdown, commentary/tool order and presentation behavior |

The Pi engine cases exercise the shared Durable event contract. They must not be
described as independent live OpenAI, Anthropic, Gemini or other family passes.
The native suite requires macOS; the manifest does not replace required iOS or
application build validation.

## Manual live probes

Live probes are intentionally excluded from tests and CI. They consume provider
services only when separately authorized and explicitly invoked with `--live`:

```sh
node scripts/live-streaming-smoke.mjs --live --harness codex --model gpt-6.1-sol --output /private/tmp/codex-stream.json
node scripts/live-streaming-smoke.mjs --live --harness grok_build --output /private/tmp/grok-stream.json
node scripts/live-opencode-streaming-smoke.mjs --live --model opencode/glm-5.3-flash-free --output /private/tmp/opencode-stream.json
```

The ACP runner uses Woven's installed managed adapters for Codex/Claude and the
installed Grok agent-stdio command. `--executable` can select an existing adapter;
`--catalog-only` creates a scratch session without sending a prompt. It negotiates
the same protocol version as Woven (v1 for Codex/Claude). Models must use the
advertised config-option identifier when available, rather than the legacy
model-plus-effort identifier. The runner denies client permission requests,
supplies no filesystem/terminal/MCP client capabilities, disables Grok web and
subagent tools, uses an isolated temporary working directory, and bounds execution.

The OpenCode runner uses the existing loopback service registration in memory,
creates a temporary native session in a scratch directory, selects an explicit
provider/model, applies a wildcard deny policy, listens to `/api/event`, and deletes
only its own temporary session afterward. It records event field names and types
to help compare the installed protocol to fixtures. It never prints registration
credentials, headers, provider response text, or raw errors. A cleanup failure is
reported. Neither runner initiates authentication or recovers expired accounts.

Reports contain elapsed milliseconds, first-event timings, chunk counts and terminal
status. They establish incremental wire delivery before terminal completion only;
they do not prove visible rendering, semantic correctness, tool execution,
reconnection, or absence of duplication. Those require the offline contracts and
separate application verification. Only provider-exposed reasoning is observable.

## Live evidence: 2026-10-27 UTC

These probes used existing sessions and scratch directories. No production SQLite
database was opened. Raw response content and credentials were not retained in
repository evidence.

The offline verification run passed 30 Pi/native cases, 5 Claude translation
cases, 40 remote recovery cases, 4 iOS inference bridge cases and 2 probe-script
cases (81 total). The initial sandbox run blocked local fixture listeners with
`listen EPERM`; repeating through the approved execution path passed. Those
fixture listeners do not consume provider services. Native Swift and rendered
application evidence must be recorded separately by the platform validation run.

| Harness/model | Observed result | First reasoning | First text | Terminal |
| --- | --- | --- | --- | --- |
| Codex / `gpt-6.1-sol` | Passed incremental ACP wire check: 110 text chunks, 375 characters | Not exposed | 3,860 ms | `end_turn`, 6,616 ms |
| Grok / advertised default | Passed incremental ACP wire check: 11 thought chunks (243 characters), 105 text chunks (498 characters) | 2,549 ms | 13,818 ms | `end_turn`, 14,498 ms |
| OpenCode / `opencode/glm-5.3-flash-free` | Execution failed before any text | None | None | `session.execution.failed` |
| OpenCode / `opencode/deepseek-v4.1-flash-free` | Execution failed before any text; native error classified as authentication | None | None | `session.execution.failed` |
| Claude Code / advertised default | Passed incremental ACP wire check after the user restored sign-in: 37 text chunks, 393 characters | Not exposed | 2,002 ms | `end_turn`, 3,956 ms |
| Pi Durable live provider families | Temporary native-client probe initialized successfully, but the normal account API returned no connected providers or configured models for its global/local scopes; live inference blocked | Not run | Not run | Not run |

Installed command versions observed: Codex CLI 0.164.0, Claude Code 2.1.310,
Grok 1.0.67, OpenCode CLI 2.1.2. The already-running OpenCode service registration
reported 2.1.3, so the service schema—not the CLI version—owns those HTTP/SSE probes.
Its public `/openapi.json` was inspected to check native event field contracts.

Claude's initial status check returned exit 1 and `loggedIn: false`, including an
approved retry outside the sandbox. The user subsequently restored sign-in; the
01:18 UTC live probe succeeded and supersedes that blocker. The agent performed
no authentication recovery.

The Pi probe was a temporary manual Swift executable linked against the compiled
WovenMatterClient/Core/Companion modules. It started the actual `LocalACPClient`
and repository Pi runtime in a disposable directory. Its account coordinator used
`DefaultAgentSupport.snapshot(workspace:)` with silent Keychain access and with
credential renewal explicitly disabled; no payloads or credential values were
logged or written. Adding the existing `wovenmatter.desktop` public preferences
suite to its in-memory search path did not change the result: both global/local
scopes returned no configured models or connected provider identifiers, and the
session exposed no model options. This establishes an unavailable connection for
that standard namespace, not that another installed application instance lacks
credentials. No model request was submitted and no application database was opened.

The initial Codex attempt used a legacy `gpt-6.1-sol[low]` selection against the
config-option API and was rejected with JSON-RPC -32602 before inference. Selecting
the advertised `gpt-6.1-sol` configuration value produced the successful row above.
There is no claimed live OpenCode text, Pi family, UI, reconnect, error/abort,
or tool-output pass from these three successful wire probes.
