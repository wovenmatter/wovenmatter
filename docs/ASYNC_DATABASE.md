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

Usage transcript scanning and its import transaction run on the writer worker.
Provider network collection remains asynchronous and outside that transaction.
Transport history recorders are async and awaited before a frame is consumed or
sent. Note write-behind retains its coalescing and recovery journal, while its
ordered batches await SQLite or backend RPC; lifecycle flushes are async barriers.

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
perform their read/modify/write sequence in one writer job. Refresh generations
and pagination identity checks prevent older async results replacing newer UI
state.

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
recording across timeout and disconnect.

```sh
swift test --package-path app --filter AsyncDatabaseWorkerTests
scripts/test-changes.sh --all
```

The stress fixture uses 50 synthetic sessions, 500 persisted chunks, and 30
concurrent snapshots, then checks exact transcript contents and reopening. It does
not call providers or touch the user's workspace. Timing output is a local
synthetic observation, not a claim about provider throughput or native frame time.
