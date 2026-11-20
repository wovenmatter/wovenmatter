# Notes and data

Notes, pages, sheets and apps live in your library beside your chats. Any
machine can edit them at any time, online or not, and the changes sync. You can
write them without an agent, or open one beside a chat and work on it together.

## Notes, pages, sheets and apps

Choose **New Artifact** in the sidebar and pick **Note**, **Page**, **Sheet**
or **App**.

- A **Note** is plain writing.
- A **Page** is a flowing document of components: text, tasks, tables, nested
  sections, and embedded notes, sheets or apps.
- A **Sheet** is a table.
- An **App** is a live HTML document, such as a dashboard or calculator. It keeps
  what you type into its controls, and it can show data from a database.

Artifacts, browser pages and document previews share one tab strip beside the
chat. Closing a tab keeps the saved item.

Agents work with these through the Woven tools: they can find and read all four,
create and edit notes, pages and apps, and rename sheets. You see their changes
in the editor.

## Version history

Choose **Version history** in the toolbar to preview an earlier version and
**Restore version**. If two machines edited the same item while apart, the
newer edit becomes current and the other is kept in its version history.

## Library

**Library** collects the files, links and photos exchanged in your chats. Filter
by machine, agent, sender, type and date, search, and sort **Newest first** or
**Oldest first**. Choose **Open** to open an item or **Show in conversation** to
jump to its message.

## Preview documents

Click a file to open a read-only preview beside the chat. This works for files
you send, files an agent hands back, and Library files. The preview uses macOS
Quick Look. Use **Reveal in Finder** or open the file in its own app to edit it.

## Browse beside your work

The browser opens in the pane beside the chat; the tab-strip plus opens another
tab. Its menu offers **Find in Page…** and **Clear Browser Data…**. Agents use
this same browser through the browser tool, so you can watch what they do.

## Databases

A database is a named SQLite file that belongs to one machine. Open
**Databases** to see them under **All**, **Local** or **Remote**, and choose
**New database** to make one on a connected machine. Agents create tables and
write data through the Woven database tools.

- Only the owning machine writes to a database. An agent on another machine can
  still write: the write is carried out by the owner, and fails with a message
  when the owner is offline.
- After each write the owner shares a copy, and every machine reads from its
  latest copy. While the owner is offline, linked content shows the last copy
  and says so.
- **Copy to workspace…** makes an independent database on another machine. It
  does not follow later changes to the original.

## Show live data

An app can read a database: choose the **Database** and query in its toolbar,
and the result reaches the page as `window.wovenMatterData`. It refreshes when
committed data changes. Notes, pages and sheets can also link to a database
for tables or single values; ask your agent to set up the link. A broken query
shows an error; ask the agent to fix it.

Next: [Scheduled work and usage](schedules-and-usage.md).
