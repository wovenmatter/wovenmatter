# Internal database concurrency

This applies to Woven Matter's `workspace.sqlite`, including conversation history,
notes, scheduling, Library metadata, coordination, and usage. It does not change
connections exposed through the Databases feature or provider-owned databases.

## Ownership and execution

`WorkspaceDatabase` is an async facade. Its domain methods submit complete jobs to
`DatabaseWorker`; callers await a continuation instead of occupying the main
thread or a Swift cooperative executor while SQLite executes or waits for a lock.
Opening, schema migration, querying, committing, rolling back, and closing all run
on dedicated Dispatch queues. The synchronous implementation is internal and its
connection cannot escape the worker as a Sendable result.

A process-local registry, keyed by the canonical database path, shares one writer
lane and two reader lanes across workspace and usage owners. Each facade retains
its own connections on those lanes. Readers are opened query-only and execute
multi-query operations inside a deferred read transaction. A read can continue
while the writer is occupied, using WAL's last committed snapshot. The existing
execution-process lease and SQLite locking still govern cross-process ownership.
WAL, foreign keys, transaction semantics, and durability settings are retained.

The async boundary is outside each existing transaction. No transaction suspends
halfway through. Operations that look like reads but journal access, such as agent
history queries, remain writer jobs. Dashboard and tool-state refreshes read their
related records and revision together. UI views consume published model state;
they do not query SQLite while rendering.

Usage transcript enumeration, parsing, and external history queries run on a
separate preparation worker with at most four admitted jobs. It prepares one
source at a time; only normalized values enter the shared writer. Each source's
samples and fingerprint/range checkpoint commit atomically after revalidating the
previous source state. Partial or conflicted imports preserve the aggregate
coverage checkpoint for retry. Successful completion updates that checkpoint and
prunes retention in one writer transaction. Queued usage writes validate refresh
and account ownership when they start, and live observations allocate their
sequence from the durable cursor on that same lane. Provider network collection
remains asynchronous and outside database transactions. A single large source
replacement or retention prune can still occupy the writer until its SQL commits;
this change removes external I/O from that interval, not SQLite serialization.
Transport history recorders are async and awaited before a frame is consumed or
sent. Note write-behind retains its coalescing and recovery journal, while its
ordered batches await SQLite or backend RPC. An empty flush barrier still reports
unacknowledged failures from earlier batches. Quit and execution handoff commit
the active field editor, close note-edit admission, and await that barrier;
failure keeps the app open and restores editing. History loads publish their
revision and version list together and discard superseded requests.

## Admission, cancellation, and deadlines

The writer admits at most 256 jobs, including its running job. Each reader lane
admits at most 128. Excess work fails with `DatabaseWorkerError.atCapacity`; it is
not silently dropped. These bounds apply across facades sharing the same lanes.

Queued jobs have a 30-second default deadline. Cancelling or expiring a queued job
removes its closure from the FIFO and resumes its caller without waiting for the
running query. This prevents cancelled submissions accumulating behind a slow
operation. Executing reads use SQLite progress and busy handlers to observe their
cancellation/deadline; the read transaction is rolled back before reuse.

Once a write starts, cancellation does not interrupt it or turn a successful
commit into an ambiguous cancellation result. The caller receives the definitive
commit/rollback outcome. Existing SQLite busy waits remain bounded at five seconds.
Long writes should be reduced at their transaction boundary, not abandoned after
part of their work has committed.

Stream writers serialize their buffer transitions across awaits. Accepted chunks
and terminal run cleanup finish even when the driving task is cancelled. Tool toggles
perform their read/modify/write sequence in one writer transaction. Refresh generations
and pagination identity checks prevent older async results replacing newer UI
state. ACP prompt handlers and initial instructions are reserved before outbound
history waits. Gateway events serialize per run and merge stream updates without
overwriting concurrent steering or cancellation. Connection lifecycle checks run
after database waits as well as network waits. Note-edit replies trigger a fresh
workspace snapshot, so delayed replies cannot replace newer saved drafts.

Within the execution process, each input carries one `AgentDispatchFence` from app preparation through database
admission to the final transport write. Stop cancels pending fences synchronously,
including backend requests still loading their conversation. Transport senders
claim dispatch after history persistence; a cancelled input that has not reached
that point can be rejected durably. Once dispatch has started, a missing native
receipt retains the existing uncertain outcome rather than rolling back an input
that may have reached the agent. New sends use a new fence.

Independent frontend/backend request connections carry a backend-lifetime ID,
frontend ID, per-conversation Stop sequence, and observed shared Stop revision.
The execution owner rejects stale sends, including a delayed send from another
frontend that has not observed a newer Stop. A newer send may carry its own Stop
before the separate Stop request arrives; that late equal-sequence Stop becomes
a no-op. Native Stop completion is a shared barrier for frontend, local UI, tool,
and scheduled dispatch. Preparation revalidates its fence after waiting. Failed
native cancellation blocks later sends until an explicit Stop retry succeeds.
A failed local harness Stop retains its native session identity: a missing or
replacement client cannot clear the failure. Pi abort rejection preserves the
active turn for retry rather than pretending that native work ended. Exact-session
recovery can clear this state only with authoritative fenced idle evidence.

Calendar occurrences reserve their target and register the same input fence before
scheduled preparation begins. Stop during that preparation cancels the occurrence
and advances its existing checkpoint without dispatching it; concurrent user sends
cannot take over the reserved session while its settings are being prepared.
OpenCode affirmative permission/form replies and automatic approvals claim the
conversation's Stop fence after outbound history persistence. Denials remain
available. Pi and Hermes likewise revalidate permission responses after journal
waits, so an approval chosen before Stop cannot be sent afterward.

The ledger retains at most 4,096 conversations and client/conversation pairs and
never evicts Stop history; overflow fails closed. Conversation IDs use the same
exact string identity as backend lookup. Backend restart invalidates old frames;
frontends discard their old Stop sequences and ignore superseded state replies.
Reconnect within one backend lifetime preserves sequences. Updated frontends
require the `session.dispatch-epochs` readiness capability. Legacy sends are
rejected with reconnect guidance; legacy Stop still cancels current work and
invalidates older versioned sends. No uncertain send is automatically replayed.

`workerMetrics` reports pending/high-water counts, finished and failed jobs,
cancellation, timeout and rejection counts, and maximum queue/execution time. It
contains no SQL, document text, credentials, or provider payloads.

## Validation

`AsyncDatabaseWorkerTests` exercises concurrent sessions and snapshots, blocked
writers with responsive readers/main actor, bounded admission, queued cancellation,
executing read cancellation, queue/read deadlines, definitive write completion,
transaction rollback, connection teardown, cancelled-run tail preservation, stream
flush ordering, and shared usage/workspace lanes. Note writer tests cover async
flush ordering, journal failure and replay; transport tests cover delayed history
recording across timeout and disconnect, overlapping ACP prompts, failed history
writes, and shutdown during a pending connection read. Usage tests suspend a save
and supersede its refresh to check that stale results cannot replace the current
cache. Additional regression sources cover WAL snapshot coherence across a
concurrent commit, observed-only receipt loading, failed flush barriers, queued
usage ownership changes, and Stop during pending Gateway admission. Admission regression sources cover delayed sends, cross-client Stops, backend restart, non-evicting capacity, native Stop wait/retry, and superseded barriers. Gateway tests overlap unsequenced events behind a blocked writer and verify
that both deltas and their ordered trace records survive.

The production audit includes source inspection, Swift syntax parsing, and diff
checks. Its provider-free focused runs passed 75 database, ownership, admission,
Stop, Pi, and settings tests, plus 31 Calendar and 31 OpenCode/Hermes tests. The
final focused log is `/private/tmp/wm-pr86-adversarial-final-tests.log`. Full
repository validation and hosted CI must still run on the integrated dependency
head; these focused results do not validate the combined Dev app or live providers.

```sh
swift test --package-path app --filter AsyncDatabaseWorkerTests
scripts/test-changes.sh --all
```

The stress fixture uses 50 synthetic sessions, 500 persisted chunks, and 30
concurrent snapshots, then checks exact transcript contents and reopening. It does
not call providers or touch the user's workspace. Timing output is a local
synthetic observation, not a claim about provider throughput or native frame time.
