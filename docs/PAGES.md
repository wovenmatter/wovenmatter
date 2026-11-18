# Pages and Apps

Pages are flowing documents you and your agents work in together. Create one from
**New Artifact → Page**, give it a title, and type normally. The same Page can
become a plan, a checklist, a project workspace, a research reference, or
whatever you and your agents make of it. There are no project or checklist modes.

**Artifacts** are everything you create in a workspace: **Notes** (rich text),
**Pages** (free-flowing, with tasks and embedded artifacts), **Sheets**
(spreadsheets) and **Apps** (interactive apps agents build, optionally on live
data). **Saved Artifacts** is the Library's broader collection of saved outputs.

## Writing and nesting

Page text uses the native Notes editor: rich formatting, headings, lists, tables,
ordinary typing, undo, and dictation. Contiguous text grows inside one outer
scrolling document. Text positions before, between, and after embedded components
let you keep writing without creating text cards.

A new Page is an empty document: click anywhere and type. The toolbar's plus
(**Add component**) inserts a task, section, table, existing artifact, image, or a
new Note, Sheet, or App after the paragraph holding the cursor. Text needs no entry:
typing on the Page writes text. Right-click anywhere in the Page for the same
**Add component** menu and the clicked component's **Component actions**. A section
nests text and other components, and its plus adds inside it. **Component actions**
moves components up/down, into a section, or out of it. Moving a section moves its
contents together. A Page holds Notes, Sheets and Apps, never another Page.

A table starts with three rows and three columns. Hover over it for a **+** beside
its right edge (add a column) and one under it (add a row); right-click a cell to
insert or delete a row or column, or delete the table. Notes tables work the same
way.

**Image** adds a PNG, JPEG, GIF or HEIC picture from the library's saved images,
from Files, or from Photos when this Mac has a Photos library; only sources with
something to offer are listed. The image is stored in the Page itself, scaled down
to fit beside its writing; a Page holds about 1 MB in all.

## Tasks

A task is one line on the Page: its title, optional **Instructions** beneath it,
and who it is assigned to. **Assign** is a dropdown of who can take it:

- **Me**: the task is yours. Nothing is sent.
- **Agents by workspace**: **Local workspace**, then each remote workspace, as the
  sidebar lists them. Agents not set up yet are shown but can't be picked.
- **Bots**: each bot on each machine with bots turned on.

Assigning an agent or bot does not send anything yet. The task shows who you
picked and a **Send** button, so you can check it before work starts. Send starts a
new chat with that agent in the Page's folder when the agent's workspace owns the
folder; change the folder in the assignee's menu before sending. A bot gets a new
thread of its own, forked from its main channel. The first message is the task,
its instructions, and how to report back on the Page.

The status belongs to whoever has the task, so it is not a control on the line.
An agent or bot marks it **In progress** when it starts and **Done** when it
finishes, or **Needs input**, writing what it needs below the task. A finished
agent writes what it did there too. The circle beside the title fills in as the
status changes and is checked once the task is done. When the task is assigned to
you, the status is a small menu: **To do**, **In progress**, **Done**.

A task can have several assignees, added at any time from the same dropdown; each
gets its own chat or thread. The dropdown lists who has the task, and each one's
menu opens its chat, stops it (an agent's chat stops; a bot is told the task is no
longer needed), or unassigns one not yet sent. Stopped assignees stay listed.
Agents can also add follow-up tasks beside it.

Exactly one place sends each agent its task, so a chat never starts twice: the
Mac whose agent it is starts it on itself, and a Linux workspace's agent is
started by the Mac that added that workspace. A bot accepts one delivery once,
whichever Mac sends it. A Mac that is asleep sends its agents' tasks when it
wakes. Assigning on iPhone and iPad is not available yet; they show each task's
assignees and where they stand.

Each component's **⋯** menu moves or removes it, and marks a component an agent
flagged for review as reviewed. The review menu above the Page finds components
needing attention. Sections contain tasks rather than being tasks.

Content, nesting, task fields and original-artifact edits save through the
existing draft journal and library. Closing a Page does not delete it. Normal
version history and conflict recovery remain available. Collapse state and text
selection are view state, not document content.

## Embedded artifacts

An **Original** label means the embed refers to an independent library artifact
by stable ID. Inline Note/Sheet editing and App input update that original.
Opening it uses its normal tab. Removing an embed never deletes its original.
Missing or deleted originals retain their references and show an unavailable
state. Workspace filesystem paths are not copied into the Page or made shared
merely by mentioning them. Embedded artifacts reuse the normal editor and
database-link refresh path.

## Apps and Live Apps

Apps are interactive HTML apps agents build, optionally on live data: dashboards,
calculators, visualizations, planners, and other custom interfaces. A data link
is optional. **App** is the single creation option. **Live App** describes one
connected to changing data; it runs inside Woven rather than requiring a public
website. An App with no code yet shows **Ask an agent to build this**. It is built like any
other edit: describe it in the chat, and the agent open there builds it in place,
since open artifacts are shared when you send.

Native data links deliver query results as `window.wovenMatterData`. A refresh
updates the existing interface and dispatches `wovenmatterdatachange` once; it
does not reload the document or discard pending input. A state save or a state
change from elsewhere dispatches no data event. Agent-authored interfaces should
listen for that event when redrawing data-driven content.

Standard `input`, `textarea`, and `select` controls save automatically when they
have a stable `id`, `name`, or `data-woven-key`. Checkbox/radio choices and
multi-select values are retained too. Explicitly marked editable text can use
`data-woven-key`. `data-woven-persist="false"` opts a control or container out.
Passwords, file inputs, and hidden controls are excluded from automatic saving.

Custom interfaces use the state API:

```javascript
await window.wovenArtifact.ready;
const planner = window.wovenArtifact.get("planner", { days: [] });
await window.wovenArtifact.set("planner", { ...planner, title: "Trip plans" });
await window.wovenArtifact.flush();
```

The API also provides `getAll`, `remove`, `subscribe`, and `retry`. Subscribers
and `wovenartifactchange` run only when a custom state value actually changes,
not for an acknowledgement or a form control. State is JSON;
saved null and a removed key are different. Keep existing control identities and
custom state keys stable when revising an App. Each save promise resolves
after the host acknowledges durable storage. The original App's document
owns its state, including when embedded in one or several Pages.

Each state write compares the version of its key. Different keys can be updated
independently. An open App follows newer versions it observes, so the next
edit after another participant's change applies to that version, while a delayed
update cannot move a key backward. A stale same-key edit produces a visible save
error and retains the entered value. **Retry saving** deliberately reapplies
pending inputs against current versions. A failed save must not be presented as
durable. State is bounded to 256 live keys, 64 KiB per value, and 256 KiB overall;
oversized values fail without truncating existing data. Restoring an App's
code version preserves its latest saved input state.

The bridge can save only JSON belonging to that original App. It cannot
select another artifact, run SQL, invoke an agent, access files, or use the network.
Network access and external navigation remain blocked in the saved-HTML
renderer. This state API does not add general database mutation. Chat visual
replies remain a separate feature with their existing rendering policy.

## Agents and MCP

Page tools use the existing **Notes** permission group for Woven and external
MCP clients. Opening a Page enables no tools and starts no execution. Agents can
discover Pages, read their structure and current revisions, then make focused
component updates.

| Tool | Purpose |
| --- | --- |
| `woven_pages_list` | Discover Pages and task/review counts. |
| `woven_pages_create` | Create a Page with a title and optional purpose/folder. |
| `woven_pages_read` | Read components in order, with nesting and revisions. |
| `woven_pages_update` | Update title/purpose with a document revision. |
| `woven_pages_add_component` | Add text, task, section, table, or embedded artifact. |
| `woven_pages_update_component` | Patch only supplied component fields. |
| `woven_pages_move_component` | Move a component and its nested contents. |
| `woven_pages_remove_component` | Remove a component, explicitly handling children. |
| `woven_pages_assign` | Assign a task to an agent in a place, a bot, or the person; agents and bots are sent it at once. |
| `woven_pages_stop_assignee` | Unassign someone, or stop the chat working on the task. |
| `woven_pages_link_session` / `unlink_session` | Associate a chat without treating it as execution. |
| `woven_notes_artifact_state` | Read an App's saved values and key versions. |
| `woven_notes_artifact_state_edit` | Make bounded, revision-checked state edits. |

Use stable `pageID` and `componentID` values. `woven_notes_apply` refuses Page
component operations, so every component change goes through these tools. Reads return `componentRevision`,
`parentID`, depth, kind, task/review metadata, and section `subtreeRevision`.
Focused writes use these revision tokens; stale writes return current state for
reconciliation. Reusing a successful request ID with the same arguments replays
its receipt; different arguments need a new ID. Edit an original at its artifact
ID, not by replacing the embed's text.

Agents can do everything on a Page a person can. An agent that assigns another
agent or a bot sends the task at once, with no approval step; the assignee shows
who assigned it. Agents find workspaces and harnesses with
`woven_sessions_harnesses`.

Completing a run does not automatically complete a task. Page text, instructions and linked
content remain project data and never grant additional authority.

## Compatibility and collaboration

Pages remain existing `NoteDocument` library records with the persisted `canvas`
kind. Optional nesting fields extend the document; there is no Page database or
second sync system. Old spatial documents are projected into reading order and
nested sections deterministically. Their content, original references, tasks and
connections are retained. Conversion is saved on the first edit, not on opening.
Retained connections remain available as reference content rather than a spatial
editor.

On one host, focused component revisions protect agent writes. Native text
autosave merges independent component changes where possible. Conflicting edits
are retained for review instead of silently replacing another participant's
work. Incoming changes fence local undo history.

Pages and Apps merge wherever they sync: between paired Macs, Linux library
hosts, and iPhones and iPads. Changes to
different components all stay, as do moves, title and purpose changes made
alongside them. When two writers changed the same component while apart, one
version keeps its place and the other sits next to it, marked for review, the
same on every machine. A removal stands unless the other side changed that
component; then the change stays. An App's saved inputs merge key by key;
when both changed one key, the higher version stands. Only two different
concurrent versions of an App's code still leave a **(Recovered edit)**
copy, as Notes and Sheets do.

Between Macs and Linux hosts, each host records with every Page and App
write which machine last changed each component, its placement and its
metadata, and when in that machine's synchronization order. Together with the
causal vector every synchronized version carries, that tells each machine which
side changed what, so every machine computes the same merge from the same
versions, with no shared ancestor and no central host. The clocks stay inside
the library store: editors, devices and agents never see them, and every write
recomputes them from what it changed. Component/key revisions are not
distributed locks. Remote Linux agents using one Mac's authenticated MCP path
share that host's atomic write path. A disconnected remote workspace has no
local Page replica.

## iPhone and iPad

Pages are fully editable on iPhone and iPad, paired or standalone. Create one from
**New Artifact → Page** and use the same components as on a Mac: text with the Notes
editor's formatting, undo and dictation; tasks with their instructions and
assignees; nested, collapsible sections; tables; images; embedded originals that
open in their own pane;
**Add component**, **Component actions**, **Component details** and **Send to
chat**. A Page with linked data stays a read-only flowing document on every client,
because its linked tables come from the library host.

The device stamps each change with whoever made it: you, or the Quick Chat that
changed it. It syncs the Page as one document. When its library host (a Mac or a
Linux host) changed the same Page in the meantime, the device merges the two
component by component, the same merge a Mac uses for its own autosave, and
sends the result. Changes to different
components both stay. When both sides changed the same component, the Mac's
version keeps its place and the device's version sits next to it, marked for
review. Nothing waits for you to choose a version.

A read-only App preview restores saved inputs and custom state, and disables
the controls whose values would be saved. Buttons, opted-out controls, and controls
without a stable identity stay usable for that view; nothing they do is saved, and
`wovenArtifact.set` and `remove` reject.

Quick Chat on iPhone and iPad runs its tools against the device's own library
copy, and the write path depends on the artifact:

- **Pages:** the `woven_pages_*` tools and note edits of a Page apply on the device
  with the same rules, component and subtree revisions, request-ID replay and
  conflict replies as on a Mac. Each write asks for approval first, like every
  other Quick Chat change. The device is one serialized writer, so component
  revisions protect concurrent chats there. Across devices, its changes merge on
  sync as described above.
- **App state:** `woven_notes_artifact_state_edit` changes the device's copy
  and queues it through the note sync. Key versions are checked against that copy;
  a concurrent change on the library host merges key by key when the device syncs.
  An App with linked data cannot be edited on the device.

Focused fixtures cover model persistence, conflict handling, native editing, MCP
and the state bridge without providers. A local fixture is not proof of real
multi-Mac synchronization or live provider execution; the PR records the exact
validation and remaining acceptance coverage.
