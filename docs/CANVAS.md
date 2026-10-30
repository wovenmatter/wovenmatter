# Canvas beta

Canvas is the fourth choice in New Note: a persistent workspace for thinking
with an agent. Start with a text card, collect existing notes, spreadsheets or
HTML artifacts, add tables, and arrange the work spatially while the ordinary
chat stays alongside it.

## Initial interaction sketch

```text
┌──────────────────────────────┬─────────────────────────────────────────┐
│ Chat                         │ Canvas title              History       │
│                              │ Canvas · Beta  Add card  Arrange  −100%+│
│ “Collect ideas and make      ├─────────────────────────────────────────┤
│  a comparison table.”        │ ┌ Text ────────────── ⋯ ┐               │
│                              │ │ The question          │               │
│ Agent reads the current     │ │ What are we exploring?│               │
│ Canvas and edits its cards. │ └───────────────────────┘               │
│                              │             ┌ Asset reference ──── ⋯ ┐ │
│                              │             │ Research spreadsheet    │ │
│                              │             │ Open asset              │ │
│                              │             └─────────────────────────┘ │
│                              │ ┌ Table ─────────────────────────── ⋯ ┐ │
│                              │ │ Option       Benefits      Questions│ │
│                              │ └─────────────────────────────────────┘ │
│ Composer                     │ Drag headers to arrange       3 cards   │
└──────────────────────────────┴─────────────────────────────────────────┘
```

This is an interaction sketch, not a screenshot. The implementation uses the
existing Green, Cognac and Dark theme surfaces and standard asset pane.

## What the beta does

- Creates Canvas from the Notes drawer and through `woven_notes_create` with
  `kind: "canvas"`.
- Adds text cards, editable table cards, and references to existing library
  assets. A reference opens the original asset in an asset tab; it does not
  copy, embed, fetch or grant access to that document.
- Moves cards by dragging their headers or using the card action menu. Offers
  two card sizes, grid arrangement, and 50–150% zoom. Scroll in both directions.
- Uses the existing note autosave, conflict handling, version history, folders,
  pinning, trash and agent attachment flow. Attach/reference the Canvas in chat
  as with an ordinary note; simply opening a Canvas does not authorize an agent.
- Lets agents append, replace and remove text/table blocks through existing
  revision-checked note tools. Layout stays intact when content changes. Agent
  additions receive deterministic grid positions until manually arranged.
- Exports the complete Canvas as JSON, including layout and reference IDs.
- Shows a linear, read-only view of text and tables on iPhone/iPad. The Mac
  central-library fallback can edit cards but cannot resolve asset references.

Text cards display plain text. Existing rich-text runs remain stored, and local
text edits preserve formatting/links outside the changed range. This beta does
not provide rich-text rendering or formatting controls inside cards.

## Working alongside an agent

Open a Canvas beside the primary agent chat (use Restore chat and assets if the
asset pane is focused). With Notes tools enabled, sending a message includes the
open Canvas ID, kind, and active-tab status. Canvas-specific guidance directs the
agent to read the current document and use note tools to add or edit its cards,
with revision checks protecting concurrent edits. For example: “On this canvas,
add three approaches and a comparison table.” The agent reads structured content;
it does not receive a screenshot of the board. Positioning and reference-card
creation remain manual. Merely opening a board does not start an agent run or
enable disabled tools.

## Architecture

`NoteArtifactKind.canvas` selects `DashboardCanvasEditor`. Its binding writes
through the same `DashboardNoteDraft` and write-behind machinery as other assets.
There is no additional storage service, background process or dependency.

Card content is an ordinary `NoteDocument.blocks` entry. Optional `canvas`
metadata maps the block's stable ID to `CanvasCardPlacement` (`x`, `y`, `width`,
`height`, optional `assetID`). Missing placement uses a deterministic grid. Asset
IDs point to existing library records; the card's text is a retained title.
Deleting a card never deletes its referenced asset. Missing references remain
visible and retain their ID.

The shared document validator rejects invalid coordinates, excessive sizes,
orphan placements, duplicate IDs and more than 200 cards. Unknown layout fields
remain read-only through the existing lossless round-trip guard. Canvas retains
document version 2 because old clients already reject unknown artifact kinds;
all clients should be updated before using Canvas. Ordinary notes emit no Canvas
metadata and retain their existing format.

Gestures keep transient movement local and commit only when released. Zoom is
view state. Position changes and agent edits share document revisions and the
existing conflict recovery path; this is not simultaneous multiplayer editing.

## Deliberate beta boundaries

- A bounded board (coordinates up to 20,000 points), not an infinite drawing app.
- No connectors, grouping, nested canvases, drawing, image uploads or live embeds.
- No agent layout tool yet; agents edit content, people arrange it.
- Layout actions use version history for recovery; no separate Canvas undo stack.
- Mobile arrangement and direct opening of references from mobile are deferred.

## Questions for the next iteration

1. Should this primarily be a freeform spatial board, a structured document, or
   switch between both views?
2. Which assets matter most: library notes/tables/HTML, images/PDFs, websites,
   files, or conversation excerpts?
3. Should the agent freely reorganize the board, suggest layout changes for
   approval, or only edit content?
4. Should clicking a reference open its original tab, show an inline preview,
   or expand an editable embedded view?
5. Should each Canvas have a dedicated continuing chat, or remain an asset that
   can participate in several chats?
6. Are sections, connectors, task statuses, or mobile editing the next priority?
