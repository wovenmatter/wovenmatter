# Workspaces and storage

Each project folder has one owning execution workspace and one fixed root
directory. Conversations, notes, and assets are organized in Woven's internal
SQLite history store; project files stay in their execution workspace.

## Create a project folder

Choose **New folder** in the sidebar, select its workspace, and enter a name.
The owning workspace must be connected. **Create New** makes a blank directory
with that name under the managed workspace root: `~/.woven-matter` on your Mac
or `/home/.woven-matter` in a remote container.

For **This Mac**, **Link Existing** lets you choose an existing project directory.
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
workspace or **Ungrouped**. Sending the first message fixes the folder and
working directory. Clicking an agent in the sidebar starts a new chat.

Ungrouped sessions use one default directory per execution workspace. Sessions
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
| Remote service storage in the persistent container home | That workspace's managed dataset files |
| Each harness's home or service | Credentials, configuration, and independently maintained history |

Each named database is a separate SQLite file with one writable owner. Its
schema belongs to the dataset and can contain multiple tables. These databases
are linkable from any folder or artifact; they are separate from project roots
and Woven's internal history/settings schema. See [Notes and data](notes-and-data.md).

Woven adds a short tool-discovery instruction block only to Woven-launched
sessions, alongside native harness prompts and your project instructions. It
does not overwrite project instruction files or user-global instructions.

## Remote storage

Each remote workspace is a Linux container with a persistent home. Updates and
recreation preserve its named home volume. Removing the container and removing
its data are separate choices. Remote project files stay on their host;
centrally saved transcripts do not synchronize them.

Back up both your project files and Woven's application/service data. Keeping a
volume across updates does not protect it from loss of the host or disk.

Optional Buzz links retain existing local agent definitions. Woven-launched
chats use their selected Mac project root or the Mac's default directory.
Linking Buzz does not create a remote container.
