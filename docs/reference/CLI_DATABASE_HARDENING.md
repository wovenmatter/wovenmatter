# CLI and database hardening

PR85 depends on PR86's asynchronous database boundary. Land PR86 first, then
PR85. The SQL implementations run on `WorkspaceDatabaseConnection`; app callers
use the async `WorkspaceDatabase` facade. History queries journal access and
therefore remain writer operations. Bounded calendar/timer listings use coherent
read snapshots. Coordination mutations and their receipts commit on the writer.

The tool endpoint binds caller identity, validates command-specific options and
bounds encoded responses to 1 MiB. CLI audit events contain operation metadata
and result references, rather than request or response content. The history
migration scrubs legacy CLI bodies and rebuilds FTS without CLI payloads.

New destructive note writes require a revision. Completed pre-upgrade receipts
still replay with their original request, without modifying the current note;
current tool permissions are checked before replay. Coordination releases and
notification changes require the current assignment epoch so an old request
cannot change a later assignment.

Linked SQLite permits one SELECT or WITH query. PRAGMA statements are rejected
because some change process-wide SQLite state even on a read-only connection.
Execution, row, column and cell budgets apply, and the result budget counts JSON
escaping and repeated object keys. The remote CLI uses the same note-target
selection rules as the local CLI, with a total receive deadline and bounded
argument count.

The September 28 source audit corrected legacy note receipt replay, remote
attached-note inheritance, PRAGMA admission, escaped result-byte accounting,
quadratic argument parsing, and remote slow-request admission. Regression source
covers these cases. No test suites, CI, provider calls or live database mutations
were executed for that audit; validation was limited to source review, Swift
parse-only checks, Python AST parsing and diff checks. Combined native build and
post-merge test execution remain separate validation gates.
