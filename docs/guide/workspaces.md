# Workspaces and storage

All agents within a workspace work from the same root. They can use the same
files, instructions, research, and plans, whichever harness you choose.
WovenMatter saves your conversations, notes, and other items in one local SQLite
database, including conversations with agents in remote workspaces.

## Where your work lives

| Location | Contents |
| --- | --- |
| `~/.woven-matter` on your Mac | Shared local agent files and instructions |
| `/home/.woven-matter` in each remote container | That workspace's shared agent files and instructions |
| WovenMatter's Application Support folder | The app's SQLite database, including conversations and notes |
| Each harness's home or service | Its credentials, configuration, and independently maintained history |

The app's central work history and each workspace's files have different roles.
Remote files stay on their host; saving transcripts centrally does not synchronize
folders between workspaces. Agents use shared workspace files and the note tools
provided for their conversation, rather than editing the app's SQLite store directly.

## Shared folder layout

The [workspace tree](../../README.md#workspace-layout) shows the initial layout.
`Repos` holds repository checkouts and `Databases` holds named data folders.
Use `GUIDES`, `PLANS`, `RESEARCH`, and `WORK_LOGS` for work you want to keep,
`OUTBOX` for deliverables, and `.scratch` for temporary work.

`AGENTS.md` contains a managed instruction block. Initialization updates that
block and preserves the text outside it. New workspaces get a `CLAUDE.md` link
to `AGENTS.md`; an existing file or link is preserved.

In **Settings → Local agent workspace**, use **Choose repositories folder** or
**Choose databases folder** to link folders you already use. These controls and
**Open workspace** remain available if setup fails. Existing folders and links
are shared by development and regular builds; startup reads them without resetting
their destinations. Populated default folders also work normally.

When you replace a populated default folder, the app asks before changing it.
**Copy files and relink** keeps the original folder as a backup and copies its
contents into the selected destination. **Keep backup only** preserves the original
folder without copying. Neither option overwrites an existing destination item;
name conflicts remain in the backup and are listed afterward. Use **Open backup**
to review or move those files. Cancelling keeps the current folder in use.
If a copy fails, the original folder stays in use. Completed copies may remain
in the destination, but an incomplete repository is not left under its final name;
you can fix the reported error and retry.

The repositories folder is named `Repos`. Older `REPOS` folders are renamed while
preserving their contents or link destination; on case-sensitive filesystems the
old path remains as a compatibility link for existing sessions.

## Remote storage

Each remote workspace is a complete Linux container with a persistent home.
Several harnesses share that home, and several workspaces can run on one host.
Updates and recreation preserve the named home volume. Removing the container
and removing its data are separate choices.

Back up both your workspace files and WovenMatter's local data. Keeping a volume
across container updates does not protect it from loss of the host or disk.

Optional Buzz links connect existing local Buzz workspaces. Their files stay in
those workspaces, and linking them does not create a remote container.
