# Chat and note menus

## Chats

Right-click a chat in the sidebar:

- **Pin / Unpin** pins it for the person. This Mac's server writes the pin,
  whichever machine owns the session, and it syncs.
- **Rename** opens an editor with the current name; Save is enabled for a
  nonempty name. The owning machine's server writes it.
- **Move to Trash** archives the session on its owning machine and closes it in
  any open chat panel. It is disabled while the chat is running.

## Notes, pages, sheets and apps

Right-click one in the sidebar:

- **Pin / Unpin**, **Rename** and **Move to Folder** (a folder, or back to
  Workspace).
- **Export artifact** saves a note as Markdown, a sheet as CSV and an app as
  its HTML; a page is always saved as its JSON document.
- **Export document** saves the complete document as JSON.
- **Move to Trash** marks it trashed and closes its tab.

The actions are disabled while one is already running for that item. These
documents live in the library, so this Mac's server writes every change.

## Trash

**Trash** in the sidebar lists archived chats and trashed notes. **Restore** brings
one back. Items stay in Trash until they are restored.
