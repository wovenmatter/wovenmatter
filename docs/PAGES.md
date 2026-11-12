# Pages and Artifacts

Pages are flowing documents for work with your agents. Create one from **New
Asset → Page**, give it a title, and type normally. The same document can become
a checklist, project workspace, research reference, or another structure you
shape as you work. There are no project or checklist modes.

The asset family is **Notes, Sheets, Artifacts, Pages**. **Saved Assets** is the
Library's broader collection of saved outputs.

## Writing and nesting

Page text uses the native Notes editor: rich formatting, headings, lists, tables,
ordinary typing, undo, and dictation. Contiguous text grows inside one outer
scrolling document. Text positions before, between, and after embedded components
let you keep writing without creating text cards.

Use **Add component** for text, a task, section, table, existing asset, or a new
Note, Sheet, Artifact, or Page. A section nests text and other components. The
section's plus adds inside it. **Component actions** moves components up/down,
into a section, or out of it. Moving a section moves its contents together.
Nested Pages link to their original document and open in the normal asset tab.

Type in task paragraphs and click their checkbox to complete or reopen them.
Enter continues a task list; Enter on an empty task returns to ordinary text.
**Component details** holds state, assignment, outcome, review, instructions,
change summary, and chat links. Assignment is a label; it starts no work.
Outcomes leave useful context for the next participant. The review menu finds
components needing attention. Sections contain tasks rather than being tasks.

Content, nesting, task fields and original-asset edits save through the existing
draft journal and library. Closing a Page does not delete it. Normal asset
version history and conflict recovery remain available. Collapse state and text
selection are view state, not document content.

## Original assets

An **Original** label means the embed refers to an independent library asset by
stable ID. Inline Note/Sheet editing and Artifact input update that original.
Opening it uses its normal tab. Removing an embed never deletes its original.
Missing or deleted originals retain their references and show an unavailable
state. Workspace filesystem paths are not copied into the Page or made shared
merely by mentioning them.

Embedded assets reuse the normal editor and database-link refresh path. A nested
Page is a link rather than a recursively mounted editor, avoiding cycles and
keeping each Page's history and save boundary understandable.

## Artifacts and Live Artifacts

Artifacts are interactive HTML artifacts built on live data: dashboards,
calculators, visualizations, planners, and other custom interfaces. A data link
is optional. **Artifact** remains the single creation option. **Live Artifact**
describes one connected to changing data; it runs inside Woven rather than
requiring a public website.

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
custom state keys stable when revising an Artifact. Each save promise resolves
after the host acknowledges durable storage. The original Artifact's document
owns its state, including when embedded in one or several Pages.

Each state write compares the version of its key. Different keys can be updated
independently. An open Artifact follows newer versions it observes, so the next
edit after another participant's change applies to that version, while a delayed
update cannot move a key backward. A stale same-key edit produces a visible save
error and retains the entered value. **Retry saving** deliberately reapplies
pending inputs against current versions. A failed save must not be presented as
durable. State is bounded to 256 live keys, 64 KiB per value, and 256 KiB overall;
oversized values fail without truncating existing data. Restoring an Artifact's
code version preserves its latest saved input state.

The bridge can save only JSON belonging to that original Artifact. It cannot
select another asset, run SQL, invoke an agent, access files, or use the network.
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
| `woven_pages_add_component` | Add text, task, section, table, or original link. |
| `woven_pages_update_component` | Patch only supplied component fields. |
| `woven_pages_move_component` | Move a component and its nested contents. |
| `woven_pages_remove_component` | Remove a component, explicitly handling children. |
| `woven_pages_link_session` / `unlink_session` | Associate a chat without treating it as execution. |
| `woven_notes_artifact_state` | Read an Artifact's saved values and key versions. |
| `woven_notes_artifact_state_edit` | Make bounded, revision-checked state edits. |

Use stable `pageID` and `componentID` values. `woven_notes_apply` refuses Page
component operations, so every component change goes through these tools. Reads return `componentRevision`,
`parentID`, depth, kind, task/review metadata, and section `subtreeRevision`.
Focused writes use these revision tokens; stale writes return current state for
reconciliation. Reusing a successful request ID with the same arguments replays
its receipt; different arguments need a new ID. Edit an original at its asset ID,
not by replacing the embed's text.

**Send to chat** uses that existing chat's agent, settings, and ordinary admission
path. Its link is saved before dispatch. A saved link does not prove that a run
was accepted or finished; inspect the chat after an uncertain handoff. Completing
a run does not automatically complete a task. Page text, instructions and linked
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

Paired Macs still replicate complete documents. Concurrent writes on different
Macs can preserve a losing version as a **(Recovered edit)** Page or Artifact.
Review and reconcile that copy. Component/key revisions are not distributed
locks. Remote Linux agents using one Mac's authenticated MCP path share that
host's atomic write path. A disconnected remote workspace has no local Page
replica.

iPhone/iPad retain their existing editing boundary: Pages and Sheets are
previews, while supported Notes remain editable. Pages show nested content and
links to originals. Mac library clients show a Page that has linked data the same
way: a read-only flowing document whose linked tables come from the library host.

A read-only Artifact preview restores saved inputs and custom state, and disables
the controls whose values would be saved. Buttons, opted-out controls, and controls
without a stable identity stay usable for that view; nothing they do is saved, and
`wovenArtifact.set` and `remove` reject.

Quick Chat on iPhone and iPad runs its tools against the device's own library
copy, and the write path depends on the asset:

- **Pages:** writes never apply on the device. Page tools and note edits of a
  Page are refused before approval is requested, with nothing changed. Edit Pages
  on a Mac, where agents share the host's atomic write path and component revisions.
- **Artifact state:** `woven_notes_artifact_state_edit` changes the device's copy
  and queues it through the existing whole-document note sync. Key versions are
  checked against that copy only, so a concurrent change on a Mac follows the
  existing sync conflict path rather than a key-level conflict. An Artifact with
  linked data cannot be edited on the device.

Focused fixtures cover model persistence, conflict handling, native editing, MCP
and the state bridge without providers. A local fixture is not proof of real
multi-Mac synchronization or live provider execution; the PR records the exact
validation and remaining acceptance coverage.
