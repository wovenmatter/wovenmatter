# Remote database reference

For the user workflow, see [Notes and data](../guide/notes-and-data.md).

## Ownership and storage

The remote service stores named SQLite datasets separately from project roots
and internal history/settings. Each dataset has one writable owner and a stable
identity. Woven tools create, query, and execute schema/data changes on that
owner. Arbitrary external JSON files, directory links, and database symlinks are
not catalog entries.

Reads use the owning service or a complete synced replica on the Mac. SQLite's
backup API captures committed schema and data together. Replicas are published
atomically, and older revisions do not replace newer ones. Copying creates a
new independent identity and writable destination owner.

## Service limits

| Resource | Limit |
| --- | --- |
| SQLite snapshot | 32 MiB |
| SQL submitted to the remote helper | 256 KiB |
| Query rows returned | 1,000 |
| Query columns | 128, with unique names |
| Encoded query result | 1 MiB |
| SQLite native heap for reads | 32 MiB |
| Concurrent service requests | 4 |

Local replica reads accept query text up to 64 KiB. Linked reads accept
read-only SELECT/CTE queries. Dataset writes run in one
transaction and can change tables and data. ATTACH, explicit transaction
control, PRAGMA, and extension loading are unavailable through these tools.

Oversized results, unavailable files, and failed queries return errors. Ask the
agent to use a smaller query or fix the link; no automatic schema repair runs.
Database operations do not start agents or consume provider services. The
helper lives in [database-catalog.py](../../remote/src/database-catalog.py).
