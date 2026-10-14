# Project roots and managed data

A folder is a display name plus one fixed execution workspace and root directory.
Local folders create a blank named directory in the managed workspace, or link an
existing directory. Remote folders create a blank directory on the connected
owner. Woven never initializes or normalizes a linked project, copies instruction
files into it, or renames its directory when its display name changes.

Draft chats can choose a folder in their agent's workspace or All Workspaces. The first
accepted send locks the saved owner and cwd. Each chat in All Workspaces launches in its
own blank directory under its execution workspace’s `scratch` directory. Its date/message/id name is reserved durably
before filesystem creation and retained through launch retries, resumes and title
changes. Drafts can switch folders before sending; returning to All Workspaces reuses
the chat’s reservation. Folder changes retain the confirmed model, thinking level,
permissions, and tool selections. Native draft reconnection uses the saved directory
and reapplies those selections on its next use, without clearing the composer controls. Chat deletion preserves working files. Scratch is reserved
for these chat directories. The database saves these roots for UI, orchestration,
calendar tasks, and child sessions. A scheduled task keeps its captured root even
if its UI folder is removed. Old sessions without this execution contract remain
archived, readable SQLite history and cannot execute.

Reference paths describe additional locations on the same owner. They use native
session permissions and do not inject instruction files from every location.
Unlinking removes the reference, not OS permissions. There are no cross-device
mounts or directory synchronization. Folder removal can optionally trash/delete
its root only when that root is a managed direct child; external roots never have
that option. These operations require the normal destructive confirmation.

## Databases

Each named dataset is a separate UUID-named SQLite file with one writable owner,
kept under Woven application/service storage, outside history SQLite and projects.
`wovenmatter databases --help` exposes create, list, execute, and query. The
existing Notes tool permission grants this data tool; discovery documents that
relationship. Dataset transactions can freely change their own tables and schema.
They cannot attach other files, load extensions, or take over transaction control.

Remote tasks use the remote owner's local CLI, so collection does not depend on a
Mac socket or connected chat bridge. Woven reads complete replicas at app open,
on reconnect, and through the existing coordination tick at a two-minute minimum
interval. Local committed tool writes refresh immediately. SQLite online backup
captures schema and data together; bounded temporary files are verified and
atomically published under a store lock. Revisions are committed in the same
transaction as changes. Older snapshots cannot replace newer replicas.

Copy to workspace creates a new identity under an available destination owner.
An online source is freshly snapshotted; an offline source uses its last complete
replica, with freshness shown in the UI. Original artifact links keep their source
identity. There is no merge back or multiwriter reconciliation.

SQL links feed tables, spreadsheets, HTML's existing `window.wovenMatterData`
bridge, and inline note values. Committed data refreshes the linked presentation
while preserving prose, formatting, and layout. An inline value requires one row,
one column, and a single line. Broken queries and schema changes surface errors;
an agent or user fixes the link. There is no automatic repair.

Snapshots currently cap at 32 MiB; rendered queries cap at 1,000 rows and 128
columns, with bounded result sizes and execution time. Table schemas may be wider
than rendered results. This implementation does not support arbitrary external
file editing of datasets.

## Acceptance checks

Provider-free automated checks cover blank creation, root/owner persistence,
archived history, deletion confinement, atomic SQL, schema changes, WAL backups,
stale replicas, copies, binary values, wide schemas, and owner-local CLI writes.
The AppKit note fixture covers inline rendering, editing, paste identity, and undo.

Trey should exercise these remaining integration checks on the PR build:

- Create local managed and external folders and a remote folder; verify blank
  creation, display-only rename, references, and correct delete choices.
- Start each retained harness from the folder plus and agent sidebar; choose a
  draft folder, send, and verify locked cwd and one native Woven instruction block.
  Verify New chat opens the agent chooser, agent names open their latest chat,
  and their separate plus buttons create in the selected folder. A plus for an
  agent in another execution workspace is disabled. Verify All Workspaces has
  the same folder-plus flow, and a rejected first send still permits choosing a folder.
- Verify the composer lists All Workspaces and every sidebar folder. Existing
  virtual folders bind once on first use, retain their root after rename, and
  preserve existing files. Folders owned by another workspace are shown disabled.
  Switch an unsent draft between All Workspaces and a folder; its model, thinking,
  permissions, and tools should stay visible and keep the same selections.
- Start two chats in All Workspaces on the Mac and on each remote workspace. Verify
  separate initially empty `scratch/<date>-<message>-<id>` directories, retry and
  resume reuse, stable paths after rename, and preserved files after chat deletion.
- Read an old chat and confirm it offers no resume/send action.
- Collect remote scheduled data while the Mac is disconnected, reconnect, and
  verify last-updated state, linked table/value/spreadsheet/HTML refresh, and Copy
  to workspace identity. Change a table schema and verify clear link errors.
- Remove only a scheduled task's UI folder and verify it retains its captured cwd.

No application launch, production deployment, or release is part of this PR's
local validation. Existing user directories and the internal history schema are
preserved.
