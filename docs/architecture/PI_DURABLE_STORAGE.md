# Pi Durable execution storage

Pi's authoritative conversations, entries, submissions, tasks, ownership, and
document checkpoints live in the execution owner's `workspace.sqlite`. Local
launches receive that path from `WorkspaceDatabase.fileURL`; the remote service
uses `<workspace>/.wovenmatter/workspace.sqlite` on its persistent volume. Remote
execution does not open or depend on the Mac's database.

The existing per-session Harness model is retained. Each manifest's stable store
ID selects its own `wm_pi_<storeID>_` namespace using the upstream Pi Durable 1.4
SQLite storage adapter. `wm_pi_runtime_stores` records the session binding and
activation. Namespaces must have a single Harness owner; the existing workspace
lease and session ownership rules still apply. This creates a set of SDK tables
per native session, deliberately retaining upstream recovery semantics rather
than implementing a second scheduler or storage engine.

The Node runtime has its own SQLite connection. It writes only its Pi namespaces
and activation registry; it does not use the Swift worker queue or claim atomic
transactions with app-domain writes. SQLite WAL and a five-second busy timeout
serialize cross-process writers. Every Pi connection sets `synchronous=FULL`,
preserving durable acknowledgement rather than the adapter's NORMAL default.
SQLite commits storage atomically; Harness recovery, durable task checkpoints,
and request identities still determine safe execution and avoid duplicate sends.

## Existing sessions

The first open validates the legacy JSONL store using the SDK's storage recovery
code without opening a Harness or running tools. A format-1 migration reader
resolves reclaimed sidecars and imports committed writes in sequence. Namespace
creation, all imported commits, and the activation receipt share one outer
SQLite transaction. An import failure leaves the source available and no
partially activated namespace; opening fails instead of silently choosing JSONL.

After activation, `native/main.jsonl` is made read-only and retained with its
sidecars as a recovery backup. Older app versions cannot append a competing
history under ordinary user permissions. Rollback to an older binary requires
an explicit data recovery decision; do not restore write permissions while the
SQLite owner is running. A backup chmod failure also fails opening and retries
protection on the next open, while the committed SQLite activation remains final.

Transport archives and session manifests keep their existing formats. They are
not the authoritative Pi scheduler store. Backups must capture the complete
SQLite database with WAL-aware backup tooling; copying only the main database
file while an owner is running is insufficient.

## Validation

Provider-free fixtures cover native child ownership, pending tasks, receipts,
rewindable and latest-document checkpoints, migration rollback/retry, namespace
isolation, and recovery after SIGKILL immediately following an acknowledged
submission. The existing engine recovery and subagent suites run against SQLite.
Power-loss durability relies on SQLite FULL synchronization and the host's
persistent-volume guarantees; the tests do not simulate physical disk failure.
