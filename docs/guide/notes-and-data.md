# Notes and data

Open a note beside your conversation to work on it with your agent. Keep a
research summary in view, develop a plan, or organize reference material without
scrolling back through the chat. Notes and conversations can share the same folders.

## Work beside a note

The **New Note** picker offers **Note**, **Spreadsheet**, and **HTML**. Each is
saved in WovenMatter's SQLite database. You can take and organize notes without
connecting an agent.

When you work with an agent beside a note, WovenMatter supplies that note's
context and editing tools. Ask the agent to read it, add text, update a table,
or create an HTML artifact. Changes appear in the editor. This access is tied
to the note associated with the conversation.

## Curate data with your agents

Use **Databases** to browse **All**, **Local**, or **Remote** locations. Select
a workspace to create a named database folder and choose its data preference.
Each database is a folder under `Databases/<name>/` where agents can keep data.
These folders are separate from the app's central SQLite database.

Choose no format preference, JSON, or SQLite to guide how agents store the data.
The preference is saved in `.wovenmatter/database.json` inside the folder.
Agents still control the files they write.

For example, have an agent collect research into a database folder, then use a
spreadsheet or HTML artifact to present it. Notes, tables, and HTML can link to
JSON or read-only SQLite query results. Remote data is read through the workspace
connection and stays on its host.

## Read linked data

Reconnect an offline remote workspace before reading its data. Older workspace
services may need an update in Settings before database operations are available.

Remote links must stay inside the workspace's database root and cannot follow
symlinks or point to external folders. If a read exceeds the service's limits,
reduce the data or query. See [Remote database limits](../reference/REMOTE_DATABASES.md)
for sizes, row limits, and supported queries.
