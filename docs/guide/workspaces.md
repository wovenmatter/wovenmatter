# Folders and storage

A folder is a name plus a directory on one machine. It belongs to that machine
for good, and chats in it run there. Conversations, notes and other items are
kept in your library; project files stay in the folder's directory.

## Create a folder

In the sidebar, choose **New Folder** in the section of the machine that should
own it. That machine must be online.

- **Create New** makes an empty directory with the folder's name in
  `~/Woven Matter` on that machine. A number is added when the name is taken.
- **Link Existing** uses a directory that is already on that machine. Its
  files and project instructions are kept as they are. For another machine,
  you browse its directories through its own server.

New folders get no preset files, `AGENTS.md` or `CLAUDE.md`.

**Rename** changes the folder's name in Woven Matter, not its directory.
Removing a folder offers **Remove Folder Only** or, for a directory Woven
Matter made, **Delete Folder and Directory**. A directory you linked is never
deleted.

## Chats without a folder

A chat started without a folder gets its own empty working directory in the
server's data folder on its machine. Before the first message, the composer's
folder selector can still move the chat to a folder on the same machine. After
the first message the folder and working directory are fixed; start a new chat
to work somewhere else.

Project files do not sync between machines. Copy them yourself when you move
work from one machine to another.

## Where your work lives

| Location | What it holds |
| --- | --- |
| A folder's directory | Project files and your project instructions |
| The Woven server's data folder on each machine | That machine's copy of your library, its databases, and working directories for chats without a folder |
| Each harness's own storage | Its sign-ins, configuration and native session history |

Each database is its own SQLite file owned by one machine; see
[Notes and data](notes-and-data.md).

Woven Matter adds a short instruction block about its tools to the sessions it
starts. It does not change your project instruction files or your own global
instructions.

Back up project files on each machine yourself; the library syncs your chats
and notes, not project files.

Next: [Conversations](conversations.md).
