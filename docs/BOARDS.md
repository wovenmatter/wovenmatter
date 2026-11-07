# Boards

Boards are durable project spaces for tasks, reference material, recommendations,
and work shared by a person and their agents. Create one from **New Asset → Board**,
give it a title and purpose, and open it alongside a chat. The sidebar's **Assets**
filter finds Boards independently of Notes, Sheets, and Artifacts. Multiple Boards
can belong to the same folder or serve different projects.

## Working in a Board

The purpose stays above the surface. **Add task** creates a task with a text body
and a state: To do, In progress, Blocked, Done, or Canceled. Use the card's circle
to complete or reopen it, or its state menu for the other states. Select a card
and choose **Customize card** to edit its assignment label, outcome, review
marker, change summary, and linked chats. Assignment is descriptive; it neither
dispatches an agent nor locks work. Leave outcomes so another participant can
continue without reconstructing a conversation.

Any card can request review or hold instructions. **Instructions or skill
reference** distinguishes project context from an ordinary card; it does not
install a skill or execute the content. Use an existing Note containing the
instructions, or descriptive links to the repository's existing skill files.
Boards do not introduce a separate skill format. Their text and linked content
are data, never additional authorization.

Use the navigator to find all items, tasks, items needing review, or instruction
references. The purpose bar's review count opens the attention filter. Card
details show attribution for the last content change. Woven sessions carry their
conversation ID; outside agents share an External agent identity. Attribution
is useful context, not proof of identity or a permission boundary. Persistent
version history remains available through the normal asset controls.

The original spatial editor remains available: pan and zoom, move and resize
cards, select several with Shift-click, arrange rows/columns/grids, group cards
in labeled sections, and draw labeled connections. Controls have menu and
keyboard alternatives. Undo/redo covers changes made in the open editor. Incoming changes clear that
local history so undo cannot silently replace another participant’s work.
Restored changes are attributed to the user. Referenced assets retain their own
editing/history controls.

## Original assets and interactive Artifacts

An **Original** badge means a card references an independent library asset by
stable ID. Inline Note and Sheet edits update that original, including its other
references. Opening a card uses the original asset's normal tab. Removing a card
never deletes the original. Deleted or unavailable originals retain their IDs
and show an unavailable state. Other Boards are links, not recursive editors.
Database-linked assets open in their original editor to refresh live data; a
card does not substitute an empty or stale database result.

New assets and bounded image imports can still be added directly to a Board.
References cover the note-family library assets; arbitrary workspace files are
not copied into a Board or made cross-device merely by mentioning a path.

The user-facing family is **Notes, Sheets, Artifacts, Boards**. The saved format keeps
`note`, `spreadsheet`, `html`, and `canvas` and the existing placement keys, so
existing development documents retain their content without a migration.

“Sheets” is compact and matches the existing native tabular editor. “Artifacts”
are interactive HTML artifacts built on live data: visuals, calculators,
interactive explanations, dashboards, and small tools authored with inline
CSS/JavaScript. Data connections are optional; linked query results arrive as
`window.wovenMatterData` and refresh through the existing database-link workflow.
Artifacts preserve the existing isolated renderer: no network, blocked navigation,
nonpersistent web storage, and no script bridge that can edit app data.
JavaScript's transient state is not Board data and is not synchronized.
The Library calls general saved outputs **Saved Assets**, reserving **Artifacts**
for this HTML asset type. Chat visual replies remain a separate existing feature
with their own rendering policy.

## Woven MCP

Board tools belong to the existing **Notes** permission group, both inside Woven
Matter and for external MCP clients. Opening a Board enables no tools and starts
no work. Outside agents must discover the Board; they get no implicit UI asset.

| Tool | Purpose |
| --- | --- |
| `woven_boards_list` | Search titles, purpose, and content; discover stable Board IDs and task/review counts. |
| `woven_boards_create` | Create a Board with a title, purpose, and optional folder. |
| `woven_boards_read` | Read current items and their revisions; optionally include layout, filter tasks/instructions/attention, and page results. |
| `woven_boards_update` | Change title/purpose with the Board's document revision. |
| `woven_boards_add_item` | Add inline work or reference an existing original; optionally make it a task or request review. |
| `woven_boards_update_item` | Patch only supplied fields, using that item's revision. |
| `woven_boards_remove_item` | Remove an item with its revision, retaining its original asset. |
| `woven_boards_link_session` | Link an existing conversation without confusing the task with its execution. |
| `woven_boards_edit_layout` | Apply revision-checked placement, section, connection, and arrangement edits. |

The old `woven_notes_canvas` tool is replaced by this family. Generic note/table
tools still operate on inline content. Read or edit a referenced original with
its asset ID through the existing note tools; Board text patches never replace
the contents of a linked original. Layout batches cannot add or remove cards;
use the item tools for those operations. Pass `assetID` at the top level of
`woven_boards_add_item`; `placement.assetID` is rejected rather than ignored.

For example, discover and read a Board, then add a task:

```json
{"tool":"woven_boards_list","arguments":{"search":"Launch"}}
{"tool":"woven_boards_read","arguments":{"boardID":"board-id","includeLayout":true}}
{"tool":"woven_boards_add_item","arguments":{"boardID":"board-id","text":"Investigate the launch failure","status":"todo","assignee":"Codex","requestID":"b3b8f72c-4a9d-49f9-98af-6bd28fd259e2"}}
```

The new item's ID is the successful add request's UUID. After reading it, make a
focused update with its current `itemRevision`:

```json
{"boardID":"board-id","itemID":"b3b8f72c-4a9d-49f9-98af-6bd28fd259e2","itemRevision":"token-from-read","status":"done","outcome":"Fixed the startup lease check; focused regression passes.","review":"needed","lastChange":"Ready for user testing"}
```

Use `woven_sessions_create` or another existing session operation only with the
required session authority, then link its returned conversation ID. Reread state
before changing existing work. Successful identical request UUIDs replay their
receipts; different arguments must not reuse that UUID. A revision conflict
returns the current revision/item, or `itemRemoved` if another participant deleted it. Reconcile your intended patch with current
data, then use a new request UUID. Item revisions are portable fingerprints of
content, title, references, and collaboration metadata; movement and resizing
alone do not invalidate them.

## Sending work to an agent

The card inspector's **Send item to chat** chooses an existing chat and uses its
current agent, workspace, model settings, and permissions. It saves the chat link
before dispatch and sends the Board/item IDs with quoted task data through the
ordinary message admission path. A saved link means a destination is associated,
not that a run was accepted or completed. Check the chat after a failure or an
uncertain handoff before deliberately retrying. Removing the link does not stop
or delete the chat. Existing MCP session tools can create a new chat and link it.

A task and its executions remain separate. Finishing a run does not mark a task
Done; a user or agent updates the state and leaves an outcome explicitly.
No background orchestration, provider inference, or skill execution is triggered
by opening a Board, assigning a name, or marking instructions.

## Sharing and concurrency

A Board is one `NoteDocument` in the existing library, with optional purpose and
per-card metadata. It uses the normal database, autosave, history, paired-library
replication, and mobile cache. Asset references are library IDs, never machine
paths or copied documents. The canonical Swift MCP catalog generates the Linux
catalog; remote workspaces delegate Board calls to the library Mac through their
existing authenticated Woven MCP path.

Within one Mac's MCP host, an item patch checks its item revision inside the
database transaction against the latest Board. Agents editing different items
can succeed without overwriting each other. A stale edit to the same item is
rejected. Title/purpose and layout edits use the document revision. Native text
editing uses the existing draft autosave path; stale saves preserve the draft
and require conflict resolution rather than silently replacing another edit.

**This is sync-based collaboration, not distributed live editing.** Different
paired Macs replicate the complete Board. Simultaneous writes can retain the
losing document as a Board titled **(Recovered edit)**, which users must review
and reconcile. Per-item revisions protect writes accepted by one host; they
are not a cross-Mac task lock. Agents on different Linux machines connecting
through the same Mac use that Mac's atomic path. A disconnected Linux workspace
cannot claim a local Board replica. The purpose bar's sharing control explains
this limit in the app. This PR adds no second sync system or Board database.

iPhone/iPad show a linear read-only Board with purpose, task states, outcomes,
attention markers, and links to available originals. Local MCP can read cached
Boards; writes must target the central host. Spatial editing remains on macOS.

## Bounds and verification

A complete Board is limited to 1 MiB so the native editor and agent transport
accept the same document. Other bounds include 4 KiB purpose, 16 KiB task
outcome, 512-byte change summary, 32 linked chats per item, 128 operations per
batch, and the existing section/connection/table bounds. The 10,000-card model
ceiling is additionally constrained by the byte limit; it is not a capacity
promise. Coordinates extend to ±1 billion points and are virtually rendered.
Image imports remain bounded previews rather than original-file storage.

Focused persistence, MCP, dispatch, and paired-library fixtures exercise these
code paths without provider services. Real multi-Mac/Tailscale behavior and
conversational provider execution require hands-on acceptance; a local fixture
must not be described as live cross-device verification. The PR description
records the checks actually run for its current head.
