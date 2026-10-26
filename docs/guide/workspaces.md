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

**New chat** starts a draft with the selected agent in the current folder. The
small plus beside a folder opens its agent chooser. Before the first message,
use the composer's folder selector to choose a folder owned by that agent's
workspace or **All Workspaces**. Sending the first message fixes the folder and
working directory. **New chat** opens the agent chooser. Clicking an agent's name
opens its most recent chat; the separate plus starts a new chat with that agent
in the selected folder. Folder plus buttons open the chooser for that folder;
the **All Workspaces** plus starts the same flow without assigning a folder.

Each chat in All Workspaces uses its own directory under `~/.woven-matter/scratch` on
the Mac or `/home/.woven-matter/scratch` in its remote workspace. Woven creates
the directory when the chat launches, with a date, the first words of its initial
message, and a short chat ID. The directory starts blank. Retries, resumes and
title changes keep the same directory; deleting the chat keeps its working files.
Scratch is reserved for these chat directories. Chats and project folders must
have an execution workspace and directory when they are created. A disconnected
workspace keeps that ownership; choosing another agent never assigns or changes
it. Folderless chats remain in All Workspaces with their own execution workspace.
Client-created folders carry their execution owner and root through synchronization.
Older clients that omit this binding must update before creating folders.
An unsent draft can still choose a project folder before its first message. Sessions
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
| Woven's Application Support folder on the Mac | Internal conversations, notes, schedules and settings; separate managed dataset files and remote replicas |
| Remote native service data directory | That workspace's managed dataset files |
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

The container workspace option is deprecated. Saved container workspaces do not
reconnect or launch agents. This does not change the separate Docker Executor.
No host containers or data are removed by this deprecation.

Remote project files stay on their host; centrally saved transcripts do not
synchronize them. Back up project files and Woven's native service data.
