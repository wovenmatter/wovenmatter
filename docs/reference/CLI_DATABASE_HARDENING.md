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


## Adversarial audit follow-up

- Remote relay overload now returns `busy` before dispatch and drains the refused request within a shared 250 ms deadline. Remote replies use the same 1 MiB ceiling as local tool responses; synthesized failures retain stable codes and echo only validated UUID request IDs.
- Linked SQLite text decoding preserves embedded NUL characters, including the suffix in encoded-response budgeting. The companion PR86 change makes workspace text binding and reads length-aware, preserving receipt identity/content and distinguishing empty TEXT from SQL NULL.
- Legacy endpoint scrubbing pages only event identities, loading one body at a time instead of retaining 500 potentially large wire payloads. Existing content, the transaction, and the final FTS rebuild remain intact.
- History character windows use PR86's NUL-safe UTF-8 scalar SQL functions. Offsets, lengths, and `has_more` include leading, middle, and trailing NULs without allocating the complete Swift string for a bounded substring.
- Regression sources cover NUL/Unicode pagination, migration across its 500-row boundary, a saturated four-request relay, bounded overload cleanup, linked SQLite NUL/result-budget behavior, and durable delivery replay containing NUL text across connections. The provider-free Python remote relay suite passes all nine checks. The new SQLite binding/window and cancellation regressions are included in the shared PR86 Swift test batch; the PR85 history and migration regressions require combined PR85/PR86 validation.
