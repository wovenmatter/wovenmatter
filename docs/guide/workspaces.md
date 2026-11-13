# Workspaces and storage

Each project folder has one owning execution workspace and one fixed root
directory. Conversations, notes, and assets are organized in Woven's internal
SQLite history store; project files stay in their execution workspace.

## Create a project folder

Choose **New folder** in the sidebar, select its workspace, and enter a name.
The owning workspace must be connected. **Create New** makes a blank directory
with that name under the managed workspace root: `~/.woven-matter` on your Mac
while a native Linux host uses
`~/.local/share/wovenmatter/workspace` under its SSH account.

**Link Existing** lets you choose an existing project directory on the owning
execution machine, including an accessible directory on a native Linux host.
Woven preserves its files and project instructions. New projects receive no
preset directories, `AGENTS.md`, or `CLAUDE.md`.

The workspace and root are fixed at creation. **Rename** changes the folder's
name in Woven without renaming its directory. **Remove folder** asks whether to
remove only the UI folder or also its directory and contents. The directory
choice is available only for managed roots; external project directories are
preserved. Conversations and notes remain in Woven.

## Chats and reference locations

**New chat** opens the agent chooser. Choose an agent to start a draft in the
selected folder. The plus beside a folder opens the chooser for that folder,
and the **All Workspaces** plus opens it without assigning a folder. In the
sidebar, clicking an agent's name opens its most recent chat; the separate plus
beside it starts a new chat with that agent in the selected folder.

Before the first message, use the composer's folder selector to choose a folder
owned by that agent's workspace or **All Workspaces**. Sending the first message
fixes the folder and working directory.

Each chat in All Workspaces uses its own directory under `scratch` in the
workspace's managed root: `~/.woven-matter/scratch` on the Mac, or
`~/.local/share/wovenmatter/workspace/scratch` on a Linux host. Woven creates
the directory when the chat launches, with a date, the first words of its initial
message, and a short chat ID. The directory starts blank. Retries, resumes and
title changes keep the same directory; deleting the chat keeps its working files.
Scratch is reserved for these chat directories. Chats and project folders must
have an execution workspace and directory when they are created. A disconnected
workspace keeps that ownership; choosing another agent never assigns or changes
it. Folderless chats remain in All Workspaces with their own execution workspace.
Folders created on any device keep their workspace and root when they
synchronize; a device running an older version must update before it can
create folders. An unsent draft can still choose a project folder before its first message. Sessions
from the former workspace layout remain readable as archived history and cannot
be resumed; start a new chat for further work. Their existing files remain in
place.

Use a folder's **Reference locations** menu to link or unlink additional files
and directories on the same execution workspace. Agents are told the available
locations and use their harness's existing permissions. Woven does not inject
instruction files from every reference location. Unlinking is not operating
system permission revocation.

Copy files explicitly when moving work between devices. There are no live
cross-device project mounts or bidirectional folder synchronization.

## Where your work lives

| Location | Contents |
| --- | --- |
| Managed root or linked directory | Project files and your project instructions |
| Woven's Application Support folder on each Mac | That Mac's copy of your library (conversations, notes, schedules and settings), its managed dataset files, and copies of remote datasets |
| A Linux host's Woven data directory | That host's copy of your library and its managed dataset files |
| Each harness's home or service | Credentials, configuration, and independently maintained history |

Each named database is a separate SQLite file with one writable owner. Its
schema belongs to the dataset and can contain multiple tables. These databases
are linkable from any folder or artifact; they are separate from project roots
and Woven's internal history/settings schema. See [Notes and data](notes-and-data.md).

Woven adds a short tool-discovery instruction block only to Woven-launched
sessions, alongside native harness prompts and your project instructions. It
does not overwrite project instruction files or user-global instructions.

## Remote storage

Remote workspaces run Woven Matter directly on Linux under the selected SSH
account, reusing its installed tools and sign-ins. Full root or Normal user
permissions apply to the whole workspace; folders retain their ordinary Linux
permissions. Execution and SQLite state stay on Linux while disconnected. See
[Native Linux hosts](../reference/REMOTE_HOSTS.md).

Remote container workspaces are no longer offered. A saved container workspace
does not reconnect or launch agents, and its containers and data are left on
the host. The separate Docker Executor is unaffected.

Remote project files stay on their host; library sync carries conversations,
not project files. Back up project files and Woven's data on each host.
