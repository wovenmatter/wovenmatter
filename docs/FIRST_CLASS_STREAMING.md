# First-class harness streaming

## Purpose and handoff

This is the starting point for rebuilding Woven Matter's streaming experience in
a different task or checkout. It records the September 15, 2026 read-only
assessment of PR #39 and the intended product direction. The subsequent handoff
pass updates documentation only.

The user intends to finish PRs #38 and #45, make broader UI changes separately,
and use #39 as a reference. This is a product and engineering handoff, not an
instruction to merge, publish, or start provider runs. Rebuilding the implementation
elsewhere is valid. Preserve useful behavior and acceptance criteria rather than
copying files wholesale. See [the patch reference](STREAMING_EXPERIENCE.md) for
what #39 actually contains.

## Definition of first-class

Every harness should provide the best experience its supported integration can
deliver. Harnesses need not emit the same information, use identical visual
presentations, or have equal feature depth. A provider with richer events should
retain that detail. A simpler provider should still feel responsive,
understandable, and dependable.

### Shared quality requirements

| Requirement | Observable result |
| --- | --- |
| Responsive output | Accepted input has immediate feedback; available text appears progressively without unnecessary client delay or repeated full-layout disruption. |
| Understandable ordering | Text around tools remains in the right relationship to those tools. Native message/part order is preserved when provided. |
| Visible answer | The final answer remains easy to find and select, including after late metadata, interruption, or reopening. Work disclosure cannot hide the only useful response. |
| Honest state | Working, waiting for approval/answer, reconnecting, uncertain delivery, stopped, failed, and completed are distinguishable when the transport can establish them. |
| Durable output | Useful received output survives failure/cancellation. Canonical corrections and history repair do not duplicate text or attach another run's output. |
| Reader control | Scrolling up, selecting text, expanding details, and switching conversations do not cause unwanted jumps or reset interaction state. Returning to the latest output is easy. |
| Useful native detail | Present exposed reasoning, tool input/output, plans, progress, and interactions with clear lifecycle and ownership. Do not fabricate missing detail. |
| Accessible interaction | Keyboard navigation, focus, accessible names/states, Reduce Motion, and manageable announcement frequency remain usable during streaming. |

There is no mandatory token animation or universal publication interval. Measure
provider event arrival separately from client persistence, projection, and paint
time before choosing a cadence. A 75 ms buffer does not establish smoothness,
and animation cannot repair delayed transport updates.

### Information to preserve across adapters

Keep these distinctions wherever the native contract supplies them:

- Conversation, run, message, content-part, and tool-call identity.
- Append-only text versus an authoritative replacement snapshot.
- Intermediate commentary versus a known final answer. When the role is unknown,
  preserve visible text rather than hiding it based only on event timing.
- A new activity versus an update to an existing activity; separate reasoning
  phases where useful and supported.
- Tool start, partial output, successful completion, failure, and cancellation.
- Provider sequence versus connection sequence versus local display order.
- Input accepted versus acknowledgement lost; execution interrupted versus merely
  disconnected; canonical history versus a partial live view.

These are semantic requirements, not a mandate for a new common event framework.
Use existing abstractions where they retain the native distinctions.

## Baseline: recheck before implementation

The following was verified on September 15, 2026. Branches and PR state can change.

| Reference | Assessed commit | Relevant state |
| --- | --- | --- |
| Main | `cc6d2882c11239623c7f0925bf8db481a4a6985a` | Includes native OpenCode v2 (#41), runtime management (#44), sidebar visibility (#43), and hover refinements (#42). |
| [#39](https://github.com/wovenmatter/wovenmatter/pull/39) | `b49707a02f209226ec94c65580f097c583fc2674` | Draft; one commit ahead and four behind main; GitHub reported mergeable, with review still required. |
| [#38](https://github.com/wovenmatter/wovenmatter/pull/38) | `ad454344973b5f34ff2307403fb0d709df2645a7` | Open; OpenClaw connection/history/recovery work, native imports, and related settings/composer work. |
| [#45](https://github.com/wovenmatter/wovenmatter/pull/45) | `8adb547489647fb5f03fe523f75796e92a51523a` | Open; local Hermes native Gateway, replay, authoritative text, interactions, and related UI. |

#39 started from `dc39c49620f1f0777acb2be0d713fe85507d5607`. Its source and green
checks do not represent the future combination of main, #38, #45, and new UI work.
The intended baseline is main after #38 and #45 are resolved. Verify actual merge
commits rather than assuming these heads were merged unchanged.

### Source map

These links identify the assessed implementations even if another checkout has
moved on. Read newer source in the target checkout before deciding what to reuse.

- #39: [shared writer](../app/Sources/WovenMatterDashboardStore/LocalACPSessionCoordinator.swift),
  [transcript projection](../app/Sources/WovenMatterCore/AssistantTranscriptProjection.swift),
  [work view](../app/App/Views/ConversationWorkTranscript.swift), and
  [streaming fixtures](../app/Tests/WovenMatterCoreTests/StreamingExperienceTests.swift).
- Main: [OpenCode native projection](https://github.com/wovenmatter/wovenmatter/blob/cc6d2882c11239623c7f0925bf8db481a4a6985a/app/Sources/WovenMatterClient/OpenCodeSessionSnapshot.swift)
  and [session following](https://github.com/wovenmatter/wovenmatter/blob/cc6d2882c11239623c7f0925bf8db481a4a6985a/app/Sources/WovenMatterDashboardStore/OpenCodeSessionCoordinator.swift).
- #38: [Gateway coordinator](https://github.com/wovenmatter/wovenmatter/blob/ad454344973b5f34ff2307403fb0d709df2645a7/app/Sources/WovenMatterDashboardStore/OpenClawGatewayCoordinator.swift).
- #45: [Hermes native adapter](https://github.com/wovenmatter/wovenmatter/blob/8adb547489647fb5f03fe523f75796e92a51523a/app/Sources/WovenMatterClient/HermesGatewayClient.swift)
  and [shared writer changes](https://github.com/wovenmatter/wovenmatter/blob/8adb547489647fb5f03fe523f75796e92a51523a/app/Sources/WovenMatterDashboardStore/LocalACPSessionCoordinator.swift).

## Independent harness plans

These describe repository behavior and work to investigate, not claims that every
installed provider exposes every listed event. Inspect current adapter/native
contracts and test supported behavior. Record unsupported features and transport
limitations explicitly.

### Codex

**Path:** `codex-acp` through `LocalACPClient` and the shared session coordinator.

**Carry forward:** flush before activity/interactions, preserve interrupted text,
durable commentary boundaries, and reader-controlled transcript behavior.

**Work:** check actual adapter ordering and identities for text, exposed reasoning,
tools, permissions, active input, and completion. The shared parser uses one
`thought` identity; decide how distinct reasoning phases should appear instead of
accumulating everything at the first row. Do not infer native Codex features from
the name if the ACP adapter does not expose them.

**Acceptance:** multi-tool turn with commentary between tools; permission pause;
supported active input; cancellation with buffered text; reopening the result.
Verify answer and tool ownership for each turn.

### Claude Code

**Path:** `claude-agent-acp` through the shared client/coordinator.

**Carry forward:** shared writer and presentation improvements.

**Work:** preserve actual assistant/tool boundaries and useful tool details across
multi-step execution. Check exposed reasoning and permission lifecycle without
requiring them to resemble Codex. Validate failure after useful output and session
resume behavior.

**Acceptance:** text → tool → text → another tool → answer; permission pause and
resolution; stop/failure after partial output; resumed continuation. Exercise
concurrent tools when the adapter/provider actually emits them.

### Grok Build

**Path:** agent stdio through the existing shared client/coordinator.

**Carry forward:** partial-output protection, ordered commentary, and shared UI.

**Work:** inspect Grok's actual update shapes and native interjection behavior.
Make available progress and tool detail useful even if the event vocabulary is
smaller. Confirm interjected input and later output retain the right message/run
association; an interjection acknowledgement is not turn completion.

**Acceptance:** progressive text; exposed tool lifecycle; active-turn interjection;
interruption; resumed work. Record absent event categories rather than rendering
invented activity.

### Cursor

**Path:** ACP plus existing Cursor question, plan, and todo extensions.

**Carry forward:** flush before interaction boundaries and shared transcript fixes.

**Work:** keep plans/todos and questions in context with text and tools. Preserve
offered choices and pending interaction state. Updates must not reset expanded
details or keyboard focus. Retain deferred persistence of new Cursor session IDs
until the native session is durable.

**Acceptance:** plan proposal/response; question/answer; tool updates; stopped work;
fresh session that later resumes. Check supported and unsupported active input
explicitly rather than assuming another ACP adapter's behavior.

### Pi

**Path:** native RPC through `PiRPCClient` and the shared coordinator.

**Carry forward:** #39's tool arguments, partial results, final results, error
status, and shared writer improvements.

**Work:** preserve message-end boundaries and distinguish result snapshots from
deltas. Check thinking phases, stable tool IDs, steer/abort behavior, and final
tool state. Prefer useful structured detail when available, retaining existing
raw-detail inspection.

**Acceptance:** start → partial update → successful/failed result; multiple message
boundaries; thinking/text transitions; steering; cancellation and transport failure
with buffered text. Include missing/malformed optional fields in fixtures.

### OpenCode

**Path:** native v2 HTTP and durable session-log following on main, using
`OpenCodeSessionCoordinator`; it bypasses the shared ACP writer.

**Carry forward:** canonical snapshots, durable cursor, identity checks, pagination,
pending interactions, and uncertain-input reconciliation; #38's later import work;
shared UI improvements that fit the new design.

**Work:** a dedicated implementation slice is required. Current projection
collects text separately from reasoning/tools, losing text/tool interleaving.
Preserve native part order and identity. Active snapshots refresh after a 500 ms
sleep; session-log events primarily advance recovery state. Investigate supported
native live updates and measure event-to-display delay before choosing incremental
application or a more responsive snapshot strategy. Preserve atomic cursor/snapshot
commits and stale-generation rejection.

**Acceptance:** interleaved native parts; progressive long replies; partial tool
results; forms/permissions; attachments; reconnect; pagination; changes from another
native client. Recovered and live presentations should agree. #39's fake ACP-driver
test does not cover this path.

### Hermes

**Path:** #45's local native Gateway adapts into the shared session coordinator.
Evaluate remote/container behavior separately from that local integration.

**Carry forward:** native durable/profile identity, replay sequence/epoch checks,
guarded uncertain submissions, interactions, interim/final snapshots, and steering
prefix tracking. Combine these with #39's buffered-tail protection.

**Work:** distinguish interim messages, deltas, authoritative final text, and late
reasoning. #45 can emit final text followed by reasoning metadata. #39's generic
boundary rule can move that answer into work disclosure if reasoning first appears
at completion. This is a source-level integration risk, not a reproduced live
failure. Keep final answers visible. Preserve earlier steering segments during
replacement, and reject late terminal updates consistently for append and snapshot.

**Acceptance:** final-only reasoning; interim → tool → final; corrected snapshots;
steering plus final replacement; approval/question/secure-input lifecycle; stop with
buffered output; same-epoch replay; changed epoch or truncated replay. Expose
uncertainty without resubmitting when recovery cannot establish acceptance.

### OpenClaw

**Path:** native Gateway for Gateway-backed conversations; ACP is a separate route
where used. Local and remote Gateway connections need their own evidence.

**Carry forward:** #38's newer connection, approval-generation, canonical-history,
import, duplicate-reply reconciliation, and session-observation behavior. Reuse
#39's useful commentary, mirrored-text filtering, tool repair, structured progress,
and scrolling after reconciling contracts.

**Work:** resolve the decisions below. Retain native tool/plan/progress detail
without conflating connection order, remote-run identity, and display order.
Check history import/recovery against the live presentation. Task/subagent or
media/widget presentation is an additional capability assessment, not something
established by a green #39 check or this plan.

**Acceptance:** mirrored agent/chat output; overlapping tools; progress updates and
clears; foreign-run events; sequence gaps/reconnect; lost send or steering receipt;
delayed canonical history; reopening during Gateway-owned execution. No duplicate
submission or attachment of another client's reply is acceptable.

## Integration decisions

| Decision | Evidence from assessed branches | Required outcome |
| --- | --- | --- |
| OpenClaw run identity | #39 adopts a different returned run ID; #38 requires a match with the submitted identity. | Follow the verified current contract and maintain durable input/reply ownership. Do not choose by convenience during conflict resolution. |
| OpenClaw uncertain delivery | #39 performs bounded probing then terminalizes uncertainty; #38 can continue observing Gateway-owned execution. | Preserve recoverable execution and distinguish unknown delivery from confirmed failure. Never blindly resend. |
| OpenClaw sequences | #39 filters per source/run and mirrored events; #38 detects run-sequence gaps and refreshes history. | Retain deduplication and gap recovery with the correct native sequence scope. |
| OpenClaw history matching | #38 has newer correlation and duplicate-reply handling; #39 changes the older helper. | Reuse bounded missing-history retry without reverting newer matching or creating duplicate rows. |
| Hermes writer | #45 adds replacement and steering-prefix tracking; #39 changes finish/cancel and boundaries. | Preserve both, including failure while paused and late snapshots after completion. |
| Final-answer classification | #39 infers commentary from subsequent activity; Hermes can report reasoning after final text. | A known final answer stays visible. Unknown semantics must not make useful output disappear. |
| OpenCode content | Native v2 is absent from #39's base; text and activities currently project separately. | Preserve native ordered parts through persistence/display; do not rely on obsolete ACP assumptions. |

File overlap indicates integration effort, not necessarily a textual conflict.
#39 overlaps main in `ApplicationModel.swift`, `DashboardConversation.swift`, and
`WorkspaceDatabase.swift`; #38 in the application model, database, shared
coordinator, and Gateway coordinator; #45 in the application model, conversation
view, database, and shared coordinator. A clean Git merge would not prove the
semantic decisions were resolved.

## Evidence required before calling a harness ready

Track each supported harness/transport/location combination independently. Local
success does not establish remote/container behavior; a fake driver does not
establish the real adapter.

1. **Contract and projection:** real-protocol-shaped fixtures exercise identity,
   order, delta/replacement semantics, tools, interactions, and terminal states.
   Test native adapters as well as the shared writer.
2. **Persistence and recovery:** temporary-database reopen, delayed/duplicate/stale
   events, canonical replacement, lost acknowledgements, and supported reconnect
   preserve ownership and useful output. Use disposable test state.
3. **Rendered app:** verify narrow/wide panels, long Markdown/code, text selection,
   expanded tools, history prepend, conversation switching, reader scrolling,
   keyboard/focus, and accessibility while updates arrive.
4. **Provider-backed acceptance:** after authorization for that work, exercise real
   normal/tool/interaction turns, stop, supported active input, and recovery.
   Record protocol limits rather than requiring unsafe automatic recovery.

For each result record the exact app commit, harness/adapter version, transport and
location, scenario, evidence type, outcome, and remaining limitation. Every
unexecuted scenario starts as **unverified**. Historical CI, fixture coverage,
live-provider acceptance, and release status remain separate.

## Starting in another task

1. Read this document and the patch reference. Inspect the target checkout's
   `AGENTS.md` and current style guide; use the configured GitHub SSH identity.
2. Verify main and the actual disposition of #38/#45. Establish work in the checkout
   selected for the broader UI changes; this old branch lacks their implementations.
3. Map actual local/remote routing for all eight harnesses. Resolve native contract
   questions and integration decisions before treating shared tests as coverage.
4. Implement the shared quality requirements within the new UI, preserving native
   distinctions. Use #39's functions/tests as references rather than transplanting
   entire files over newer code.
5. Complete OpenCode's native slice and Hermes/OpenClaw integration, then the
   per-harness evidence matrix. Review the resulting diff and run the target
   repository's provider-free validation, including `scripts/test-changes.sh --all`
   when implementation spans components.
6. Rewrite the resulting PR description around the final implementation and exact
   evidence. Do not inherit #39's broad all-eight or old fixture claims as proof of
   the rebuilt experience.

No implementation, provider runs, or broader UI decisions are completed by this
handoff. Another task should be able to start with the right baseline, priorities,
and definition of done without needing the original conversation.
