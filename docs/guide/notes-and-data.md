# Notes and data

Keep a note beside a conversation, organize results in folders, or work with a
spreadsheet or HTML artifact. The **New Note** picker offers **Note**,
**Spreadsheet**, and **HTML**. These app records live in the local store.

## Database folders

**Databases** lets you browse **All**, **Local**, or **Remote** locations. Choose
a workspace to create a named database folder and set its data preference.
A database here is an ordinary folder under `Databases/<name>/`, not a hosted
database service.

A preference of no format, JSON, or SQLite tells agents how you want data stored;
it does not force them to use that format. The preference is recorded in
`.wovenmatter/database.json` within the database folder.

Notes, tables, and HTML artifacts can link to JSON or SQLite data. For remote
data, the app reads through the existing workspace connection; remote paths are
never opened as Mac files. Linked SQLite queries are read-only. Agents can
still work on the underlying files through their normal workspace access.

## When data is unavailable

A configured remote workspace can remain listed while offline. Reconnect it
before reading its data. Older remote services may require an explicit service
update in Settings before database operations are available.

Remote links must stay inside the workspace's database root and cannot follow
symlinks or point to external folders. Reads have size and query limits; reduce
the data or query if it exceeds them. See the
[remote database reference](../reference/REMOTE_DATABASES.md) for exact limits.
