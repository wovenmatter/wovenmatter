# Streaming experience: PR #39 reference

## Start here

Read [First-class harness streaming](FIRST_CLASS_STREAMING.md) for the product
definition, individual harness plans, integration decisions, and rebuild checklist.
PR #39 is an implementation reference, not an all-eight-harness acceptance result.

The September 15, 2026 assessment found that this branch predates native OpenCode
v2 on main and native Hermes in PR #45. PR #38 also changes OpenClaw recovery in
ways that overlap this patch. Recheck their actual merged state before rebuilding
these changes alongside the separate broader UI work. Preserving this patch's
structure or exact visual layout is not a requirement.

## Historical implementation baseline

Implementation commit: `b49707a02f209226ec94c65580f097c583fc2674` in
[PR #39](https://github.com/wovenmatter/wovenmatter/pull/39).

Based on the OpenClaw UI streaming analysis prepared 2026-09-03 against
`openclaw/openclaw@6cd743c2a39fda64249213da58fd6ecf30242c3a`.
The original implementation notes report checking progress-card and startup-status
wire shapes against local `v2026.9.2` source. These are historical references, not
a fresh verification of the currently installed provider contract.
Woven Matter baseline: `dc39c49620f1f0777acb2be0d713fe85507d5607`.

## What the patch implements

These describe code in the original commit, not guarantees for every transport.

| Report lesson | Woven Matter behavior |
| --- | --- |
| Separate canonical replies from live work | Canonical reply text remains intact in SQLite. Frozen commentary segments join the existing activity projection, scoped to their reply. The displayed final/live tail is derived without duplicating commentary. |
| Text → tool → text barriers | Local ACP/Pi flush and persist text before activity, message boundaries, approvals, and questions. Gateway activity freezes the preceding reply. SQLite insertion positions break timestamp ties. |
| Cumulative replacement repair | Bounded SHA-256/byte-count checkpoints recognize the exact prefix represented by each frozen segment. A divergent snapshot starts a new segment; Unicode, whitespace and code fences remain lossless. Canonical history wins over live snapshots. |
| Pacing and stable rendering | Text publication is coalesced at 75 ms; activity/terminal boundaries flush immediately. Live-tail Markdown is prepared off the main actor and cached. Tool group identity no longer changes every time another tool arrives. |
| Inspectable work with a visible final answer | Commentary uses the existing Markdown renderer. Successful work folds when a final reply exists; failed, stopped, and tools-only work remains available. Concurrent tools are all shown as active. |
| Useful tool/progress detail | Pi now captures arguments, partial results, final results, and failures. Gateway structured plans preserve step status; `progressCard.changed` fetches the authoritative card asynchronously and handles clearing. Startup phases and approval/question waiting labels are explicit. |
| Preserve partial replies | Buffered tails drain before failure/cancellation, including a paused steering writer. Empty Gateway terminals do not erase useful output; late writer chunks are ignored. |
| Ownership and sequence fences | Gateway fences are remote-run/source scoped, dedupe mirrored tool events, reject stale deltas, and retire chat terminals. Foreign explicit run IDs never fall through to the selected session. Adopted server run IDs retain the local reply identity. |
| Avoid duplicate mirror text | Agent text can start immediately. Once cumulative chat text arrives it owns live text; ambiguous mirrored append-only text is not appended twice. |
| Bounded terminal recovery | Missing exactly-correlated history is retried even when the RPC succeeds. Recovery waits 100/400/1500/3000 ms between misses and bounds each request. Audit terminal results repair a missed live tool completion. |
| Ambiguous sends are not blindly retried | The local input/run is durable before transport. A lost send receipt triggers exact-run history probing, never another `chat.send`, and retains an explicit unconfirmed-delivery explanation. |
| Reader owns scrolling | Deferred follows are invalidated by user scrolling or conversation changes; history prepending cannot trigger follow. “Latest reply” uses the existing quiet button style. Reduce Motion disables work-disclosure animation. |

The shared coordinator changes benefit the harnesses routed through it. Catalog
membership does not establish transport coverage: native OpenCode bypasses that
writer, and Hermes gains authoritative replacement behavior in #45. Gateway-specific
behavior remains in its own adapter. Only provider-exposed reasoning/activity can
be presented.

Several choices need revision when rebuilding: the commentary/final classification
is heuristic; updating one reasoning row does not preserve separate reasoning
phases; #38 and #39 differ on Gateway identity, sequences, and uncertain delivery.
The [handoff](FIRST_CLASS_STREAMING.md#integration-decisions) records those decisions.

The original patch reused existing styling, including the return-to-latest button.
That historical choice does not constrain the user-directed broader UI work;
follow the target checkout's current style guide.

## Validation evidence and limits

Existing GitHub checks for the original commit passed CI and macOS validation on
September 8, 2026. Remote workspace checks were skipped. The September 15 assessment
inspected that evidence; it did not rerun implementation tests or submit provider
prompts. The original PR reports running:

```sh
# Avoid inheriting the agent runner's account location into an existing test
# that intentionally supplies a temporary account fixture. This affects only
# the test subprocess, not the user's configuration.
env -u CODEX_HOME scripts/test-changes.sh --all
```

Source tests cover persisted/reopened commentary, text-before-tool ordering,
replacement snapshots and Unicode, terminal fencing, mirror deduplication,
exact-run history recovery, progress-card clears, Pi tool details, and partial
output. Tests use temporary databases and fake drivers, not provider services.

The test parameterized over all eight runtime names injects the same fake driver,
emits one text chunk, and throws. It verifies shared buffered-failure handling;
it does not exercise eight adapters or eight provider executions.

The original PR reports identical before/after PNG hashes for selected
tool/reasoning/Markdown fixtures at 420 and 768 points in Green and Cognac. That
evidence does not establish full-app scrolling, new commentary layouts, interaction
continuity, performance, or VoiceOver behavior.

## Boundaries of this iteration

This is not full OpenClaw Control UI parity. It does not add a new offline
FIFO outbox, automatic replay, branch/settings compare-and-swap, session-wide
multi-client transcript import, or Gateway session recovery across app restart.
Existing local durable inputs and interrupted-run recovery remain in place.
PR #38 supplies separate import and session-recovery work. Inspect its actual merged
implementation before assigning remaining scope; this document does not claim
that it supplies every Gateway question/task/subagent surface.

Local ACP question and approval cards retain their existing resolution path.
Gateway approvals retain their existing handler. Gateway question/task/subagent
UI, observer snapshots, native media/widget rendering, and a smooth 60 Hz prose
reveal remain outside this first streaming slice. Rendering does not invent
capabilities a harness does not expose. Large raw details are display-capped at
120,000 characters while their durable payload remains intact.

Real-provider acceptance, live disconnect/reconnect interactions, scroll gestures,
and VoiceOver announcement behavior still require interactive acceptance. The
build and fixture tests do not establish those behaviors end-to-end.
