# Pi Durable execution storage

Pi's authoritative conversations, entries, submissions, tasks, ownership, and
document checkpoints live in the execution owner's `workspace.sqlite`. Local
launches receive that path from `WorkspaceDatabase.fileURL`; a Linux host's
service uses `<workspace>/.wovenmatter/workspace.sqlite` under its workspace
directory (`~/.local/share/wovenmatter/workspace` on a native host). That
execution database is separate from the host's library copy
(`~/.local/share/wovenmatter/library/workspace.sqlite`), and remote execution
never opens or depends on a Mac's database.

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

## Activation

A session's first open creates its namespace and writes its activation receipt in
one SQLite transaction, so a failure leaves no partially activated namespace.

Transport archives and session manifests keep their existing formats. They are
not the authoritative Pi scheduler store. Backups must capture the complete
SQLite database with WAL-aware backup tooling; copying only the main database
file while an owner is running is insufficient.

## Validation

Provider-free fixtures cover activation rollback and retry, and recovery after
SIGKILL immediately following an acknowledged submission. The existing engine recovery and subagent suites run against SQLite.
Power-loss durability relies on SQLite FULL synchronization and the host's
storage guarantees; the tests do not simulate physical disk failure.
