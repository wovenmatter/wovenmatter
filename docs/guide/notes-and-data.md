# Notes and data

Open a note beside your conversation to work on it with your agent. Keep a
research summary in view, develop a plan, or organize reference material without
scrolling back through the chat. Notes and conversations can share the same folders.

## Library

**Library** collects files, links, and photos, including screenshots, exchanged
in new messages after the feature becomes available. Existing conversation
history is not added. An item appears when you send an attachment or link, or
when an agent hands back a file, image, link, or citation. Files only mentioned
in internal tool activity are not collected. Notes and conversation references
remain message attachments and do not appear as Library files.

Combine workspace, agent type, individual agent, sender, and item-type filters.
Workspace and agent filters allow multiple selections, all, or none. Date
filters include Today, Last 7 days, Last 30 days, Last 90 days, and All time.
Search by title, link, or conversation, and sort newest or oldest first. Each
item shows its sender, workspace, and sent date and time.

Choose **Open** to open the link, photo, or file, or **Show in conversation** to
jump to its source message. Archived conversations show a read-only source
message. Separate exchanges have separate entries, even when they share a URL
or file. Deleting a source message, clearing its conversation, or deleting the
conversation removes its Library entries. Archiving keeps them.

Web URLs stay links. Uploaded files reuse existing attachment storage. Files
handed back from a local workspace or a connected remote container are saved
as local snapshots, up to 25 MB each, so they remain available after the
workspace disconnects or the original changes. Remote reads use the existing
workspace connection and are restricted to its working folder and temporary
output folders. Unavailable files show the reason and a **Retry** action;
reconnect the workspace or ask the agent for a smaller file when needed.

File bytes live on disk, outside SQLite. Identical saved content shares one
stored copy; unreferenced Library copies are cleaned up after a short grace
period. Original workspace files are not deleted or edited by the Library.

## Work beside a note

The **New Note** picker offers **Note**, **Spreadsheet**, and **HTML**. Each is
saved in WovenMatter's SQLite database. You can take and organize notes without
connecting an agent.

With **Notes** enabled in the conversation's **Tools** menu, the agent can find,
read, create, and edit workspace notes. Opening a note beside the conversation
supplies its context. Ask the agent to add text, update a table, or create an HTML
artifact; changes appear in the editor. Disable Notes to stop further tool access.

## Restore a version

Choose **Version history** in the note toolbar to preview a retained version and
restore its title and content. The current saved document is retained before
restoration. If the document changed while you were reviewing, refresh before
trying again.

WovenMatter retains up to 50 versions and 20 MB per document, within a 256 MB
workspace limit. This covers notes, spreadsheets, and HTML; externally linked
data files are not versioned.

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
