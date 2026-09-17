# Workspaces and storage

A workspace gives agents a place to work and keep files. Woven Matter also has
its own local store for the app's notes, conversation records, and activity.
These are separate kinds of data.

| Location | What belongs there |
| --- | --- |
| `~/.woven-matter` on your Mac | Shared local agent files and instructions |
| `/home/.woven-matter` in each remote container | That remote workspace's files and instructions |
| The app's local Application Support store | Notes, conversation records, and other app state in SQLite |
| Runtime homes and services | Provider authentication, configuration, and runtime-owned session history |

## Shared folder layout

The [README's workspace tree](../../README.md#your-workspace) matches the shared
initializer. `REPOS` holds repository checkouts; `Databases` holds named data
folders. `GUIDES`, `PLANS`, `RESEARCH`, and `WORK_LOGS` give durable work a home;
`OUTBOX` is for deliverables, and `.scratch` is disposable working space.

`AGENTS.md` contains a managed instruction block. Initialization updates that
block while preserving material outside it. A new workspace gets a `CLAUDE.md`
symlink to `AGENTS.md`; an existing file or link is left alone.

On your Mac, Settings can point `REPOS` and `Databases` to existing folders using
symlinks. The app refuses to replace a nonempty default folder with a link;
resolve its contents before changing the location.

## Local and remote are separate

A remote workspace is one complete Linux container, with multiple runtimes
sharing its persistent home. Workspaces can coexist on one host or span several
hosts. Their files are not automatically synchronized with your Mac.

Container updates and recreation preserve the named home volume. Removing a
container and removing its persistent data are separate choices. Persistence
is not a backup: protect both your workspace files and the app's local data.

Buzz links are optional connections to existing local Buzz workspaces. Their
files remain in those workspaces; linking one does not turn it into an
app-managed remote container.
