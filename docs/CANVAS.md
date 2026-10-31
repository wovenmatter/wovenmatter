# Canvas workspace

Canvas is a spatial workspace alongside an agent chat. Create one from New Note,
open it beside a chat, and ask the agent to create, compare, connect, or arrange
work. Existing boards retain their content and placement.

## Working on the board

- Drag the empty background, scroll with a trackpad or mouse, or focus the
  background and use arrow keys to pan. Turn on the hand tool to pan across
  cards without editing them. Pinch, Command-scroll, or use the header
  controls to zoom from 10% to 400%. The surface extends in every direction.
- Add text/table cards, create independent documents, spreadsheets or HTML
  artifacts, import an image, or reference an existing asset. The new work appears
  in the current viewport. HTML supports interactive inline CSS/JavaScript and
  embedded data-URI images using the existing isolated artifact renderer.
- Documents and spreadsheets can be edited directly in their reference cards.
  HTML renders in place. The open button expands the original in its normal tab.
  Multiple references share one original; removing a card never deletes it.
- Drag a card header to move it; Shift-click headers for multiple selection.
  Drag the lower-right handle to resize. Customize titles, colors, dimensions,
  and section membership through the selection inspector.
- Arrange all cards or a selection in a row, column, or grid. Group selected
  cards in a labeled, colored section. Drag the section's leading handle to
  move its members together. Removing a section keeps its cards.
- Connect selected cards to make a workflow. The inspector labels, renames, and
  removes connections. Connections follow cards and disappear when an endpoint
  is removed.
- The navigator finds cards anywhere on the board. Fit all, fit selection,
  actual size, and return to origin are available in the zoom menu.
- Canvas undo/redo covers structural changes and incoming agent edits while the
  editor is open. Original assets retain their own editing/history controls.
  Persistent version history remains available after closing the board.

The full-bleed editor and narrowly filled bottom corner cutouts are preserved.
Controls remain immediately before history and database in the title bar.

## Working with an agent

With Notes tools enabled, sending a chat message includes the selected Canvas ID,
its kind, viewport world coordinates, zoom, and selected card IDs. This is a
structured snapshot, not a screenshot or authorization. The agent reads current
contents, positions, sections, and connections through `woven_notes_read`.

`woven_notes_canvas` accepts a current revision and up to 128 edits, applied
atomically as one note mutation/history checkpoint. It supports:

- `add`: a new card ID, optional text (or a complete note block), and placement.
- `place`: an existing card ID and complete replacement layout; the asset
  reference is preserved even if omitted. To use a different asset, add a new card.
- `remove`: a card ID; only the placement/content on this board is removed.
- `section`: a section record and optional member IDs; updating its position
  translates its member cards.
- `removeSection`: remove a section and ungroup its cards.
- `connect` / `disconnect`: create/update or remove labeled connections.
- `arrange`: optional card IDs and `grid`, `row`, or `column` layout.

For example, after reading a board's current revision:

```json
{
  "noteID": "board-id",
  "revision": "current-revision",
  "edits": [
    {"action":"add","id":"option-a","text":"First approach",
     "placement":{"x":0,"y":0,"width":360,"height":300}},
    {"action":"add","id":"option-b","text":"Second approach",
     "placement":{"x":408,"y":0,"width":360,"height":300}},
    {"action":"connect","connection":{"id":"comparison","from":"option-a",
     "to":"option-b","label":"compare","color":"blue"}}
  ]
}
```

Use `woven_notes_create` to create independent assets, populate them with normal
note/table/HTML tools, then add cards whose placement contains `assetID`. Creation
and board placement are separate revision-safe operations: retain the returned
asset ID and reuse it if placement must be retried. Edit the original asset ID to
change a reference's contents. Existing append/table tools still work for inline
cards. For visual checking of authored HTML, the existing `woven_html_preview`
tool can render that artifact; board context alone must not be described as a
visual inspection.

Every layout edit requires the latest revision. On conflicts, read again and
apply the intended change to current data. A repeated request ID replays its
receipt instead of duplicating work. Disabled Notes tools remain disabled.
Opening a board does not start a run or widen permissions.

## Storage and rendering

The Canvas remains a version-2 `NoteDocument` with ordinary text/table blocks and
optional placement metadata keyed by stable block ID. References contain library
asset IDs, not copied documents or machine-local paths. Sections and connections
are optional arrays, and unsupported fields remain read-only on older clients.

The viewport transforms world coordinates into screen coordinates and only
constructs card editors near the viewport. No giant native scrollable surface
is allocated. Navigation state is local; content/layout uses existing autosave,
revision checks, and conflict recovery. This is optimistic concurrency, not CRDT
multiplayer editing. Other document types and their appearance are unchanged.

Practical bounds protect memory and document transport: coordinates ±1 billion
points, 10,000 cards, 1,000 sections, 20,000 connections, 128 edits/selection per
batch, and existing note byte/table limits. Card dimensions are 200–4,000 by
120–4,000 points. Image imports accept PNG/JPEG/GIF up to 20 MB and downsample larger images
to an embedded preview under 650 KB in an independent HTML asset. Large animated
GIFs become a still preview. The source file is unchanged. Large file/PDF/video
embeds and unrestricted external webpages are not added by this implementation.
The existing HTML renderer's network/navigation restrictions remain intact.

The macOS standalone app supplies asset resolution and inline editing. The
central-library fallback retains Canvas structural editing. iPhone/iPad retain
linear read-only Canvas viewing; mobile spatial editing is outside this desktop
workflow.
