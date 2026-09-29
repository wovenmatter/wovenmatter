# Chat menu actions

Right-click a chat in either sidebar layout:

- **Pin / Unpin** moves it into or out of the pinned section in the current folder.
- **Rename** opens an editor with the current name. Save persists the trimmed,
  nonempty name; Cancel leaves it unchanged. User names survive automatic title
  generation and OpenCode transcript refreshes.
- **Move to Folder** moves the chat into a folder, or back to Workspace.
- **Export messages** saves the complete retained transcript as Markdown, with
  roles, timestamps, attachment metadata, and note/chat reference snapshots.
- **Export full run** saves JSON containing conversation metadata, all retained
  messages and runs, normalized activities, run events, trace events, and recorded
  history events. It includes older messages beyond the visible history page.
- **Move to Trash** hides the chat without deleting its messages. Stop active work
  first. Trash checks active runs again when committing and shares the message
  preparation reservation, so a new dispatch cannot race that operation.

The **Trash** sidebar entry lists trashed chats and offers **Restore**. Restoring
preserves the chat's name, pin, messages, and retained Library files, and returns
it to its previous folder if that folder still exists. Otherwise it returns to Workspace. Trashing pauses
session timers and cancels queued or claimed-but-unsent deliveries; restoration
does not resume them. Library entries are hidden while in Trash, and their retained
files are protected from cleanup while the chat is in Trash.

Exports are local snapshots of what Woven Matter has retained. They do not fetch
missing provider history or bundle attachment file bytes. The full-run JSON
includes a schema version and coverage description. Both export actions use the
native Save dialog and remove the temporary export on success, cancellation, or
save failure. Export contents are staged by the backend rather than carried in
an IPC response, so large chats do not hit the response-size limit.

Mutations go through the execution owner in both embedded and separate-backend
modes. The frontend never writes its read-only database projection. Database
revisions refresh both sidebar layouts, and removed chats are cleared from all
open chat panels.

`WorkspaceConversationActionsTests` exercises persistence across reopening,
folder moves, user-title preservation, validation and read-only boundaries,
active-run rejection, trash/restoration, timer/delivery behavior, and complete
exports with older messages, reference snapshots, and untruncated history events.

## Integration dependency and acceptance

This feature depends on PR #86 (async internal database workers) landing first.
Its SQL implementation extends `WorkspaceDatabaseConnection`; its public APIs
queue one complete write transaction or one coherent read snapshot. Export SQL
and JSON encoding run on a reader worker; staging and destination file I/O use a
dispatch queue. No full transcript is encoded into the backend RPC response.
Full-history queries use conversation subqueries instead of one bind parameter
per message or run.

Trash also rejects native OpenCode active snapshots and sending or uncertain
submissions before a normalized run exists. New submission admission checks chat
visibility inside its write transaction; terminal receipt settlement stays legal.
The app's shared send/Trash reservation covers native slash-command preparation.

Regression source covers the async worker boundary, queued/accepted/running and
native OpenCode admission, and exports under a reduced SQLite bind limit. These
checks were added during review but were not executed at the user's direction.
Native acceptance still needs narrow/wide sidebar menus, Rename Save/Cancel and
errors, concurrent restores, active-work rejection, and both Save dialog formats
including cancel and a destination write failure, in embedded and separate-backend
modes. Interrupted delivery of an export response can leave a staged temporary
export; normal Save,
Cancel, and error paths remove it.
