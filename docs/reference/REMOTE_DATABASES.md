# Remote database reference

For the user workflow, see [Notes and data](../guide/notes-and-data.md).
These limits apply to reads through the remote workspace service.

## Paths and access

The catalog operates inside `Databases/<name>/` and records format guidance in
`.wovenmatter/database.json`. External folder links and symlinks are not allowed.
Linked reads use the authenticated workspace connection; a remote path is never
treated as a Mac file. Older services need an explicit update in Settings.

## Read limits

| Resource | Limit |
| --- | --- |
| JSON file | 4 MiB |
| SQLite snapshot, including WAL state | 256 MiB |
| Query rows | 1,000 |
| Query columns | 128, with unique names |
| Query result | 4 MiB |
| SQLite native heap | 32 MiB |
| Linux helper address space | 128 MiB |

SQLite permits read-only SELECT/CTE queries. Mutation, ATTACH, PRAGMA, and
extension loading are denied. Busy or changing databases return a retryable
error; memory exhaustion returns a controlled error. Output conversion checks
the remaining response budget before encoding each value.

Database reads do not start agents or consume provider services. Format
preferences guide agents without enforcing how they write the underlying data.
The implementation lives in [database-catalog.py](../../remote/src/database-catalog.py).
