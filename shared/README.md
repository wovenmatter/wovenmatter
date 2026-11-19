# Shared document and wire types

`WovenMatterShared` is a Foundation-only package used by iOS and macOS.
It owns the note model, Woven Matter tool grammar and the Codable wire contracts;
`WovenMatterCore` re-exports those types. It contains no credentials, execution,
UI state or persistence implementation.

Payload bounds live in `LibraryProtocol.swift`. Nothing here carries a format
or protocol number: every device updates together, an optional feature is a
named capability in a workspace's registry row, and what the release before
this one stored is converted once when a device first opens it.
`NativeRecordFormat` is the one place that names the tags on native history
records. Routes sit directly under the `/wovenmatter` mount, with no prefix.
A stream frame, record tag or command that a device does not know fails to
decode: nothing is skipped or guessed, because no other build is on the other
end. A device that a Mac no longer lists is refused, and asks to be paired
again. A note that holds structure this package cannot edit safely stays
read-only through `NoteDocument.editableDocument(from:)`, and its content
survives round trips without normalization or field loss.

See [distributed architecture](../docs/DISTRIBUTED_CLIENT_ARCHITECTURE.md) for
identity, ownership, replay and conflict semantics, and
[device testing](../docs/DISTRIBUTED_CLIENT_TESTING.md) for acceptance checks.
