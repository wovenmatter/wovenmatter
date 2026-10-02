# Companion domain and wire contract

`WovenMatterCompanion` is a Foundation-only Swift package shared by iOS and the
Mac. It contains note document types and versioned Codable DTOs. It has no
provider execution, credentials, UI selection, process or workspace store code.
`WovenMatterCore` re-exports it so existing desktop clients remain compatible.

Protocol v1 has one authoritative Mac workspace and one paired phone. Workspace,
device, folder, note, conversation, run, interaction and operation identities are
stable and separate. Resource revisions are monotonic integers; the existing
local note CLI represents the same integer as a string.

## Documents

`CompanionNote.content` is the exact canonical raw document. A supported edit
must pass `NoteDocument.editableDocument(from:)`; unknown versions, fields,
blocks, ragged tables and unsafe dimensions remain read-only. IDs, rich run
attributes, table data and links survive supported edits. Table normalization
cannot allocate an unbounded sparse matrix or silently trim populated cells.

All note metadata is discoverable in a snapshot. Bodies fit a bounded aggregate
budget and may be omitted (`contentIncluded == false`, with original
`contentByteCount` and `kind`). An omitted body is not an empty document. Clients
retain a cached body only at the same revision, or fetch `/v1/notes/{id}`. Changes
coalesce repeated invalidations and advance through exactly the log rows scanned.

## Mutation and replay

Clients persist the operation ID, original base and exact submitted mutation
before sending. Folder creation precedes dependent notes. Update/delete require
the observed integer revision. Mutation plus permanent receipt commits in one
SQLite transaction; an ID reused with different content is rejected. Receipts
retain status and original accepted revision, without a full document copy per
edit. A client reconstructs an accepted body from its immutable submitted request;
it fetches current canonical bodies to resolve a conflict. Deletion never permits
recreating the same ID. Folder deletion moves retained children to workspace root.

Database triggers publish every canonical note/folder/session/message/activity
writer into a bounded replay journal. An expired cursor explicitly requires a
fresh snapshot. Desktop autosave uses the same compare-and-set boundary, keeps
its exact committed receipt and journals both failed writing and its base. Only
a proven predecessor acknowledged by the same writer permits queued-draft
rebasing. Explicit recovery copies use a distinct canonical ID.

## Agent commands

The Mac reserves a durable command receipt before routing through its execution
and interaction broker. Repeated IDs never execute twice, even after a crash or
lost acknowledgement. A command whose execution result was not recorded is
`outcomeUnknown`; clients recover receipts with GET and require explicit user
action for new commands. Agent commands are online-only, and a phone disconnect
never cancels a Mac-owned run. Provider and per-session capability descriptors
report the route's actual negotiated differences.
