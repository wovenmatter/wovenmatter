# Shared document and wire types

`WovenMatterCompanion` is a Foundation-only package used by iOS and macOS.
It owns the note model, Woven Matter tool grammar and versioned Codable contracts;
`WovenMatterCore` re-exports those types. It contains no credentials, execution,
UI state or persistence implementation.

Protocol version and payload bounds live in `CompanionProtocol.swift`. Update
both apps together when the wire contract changes. Unknown note structures remain
read-only through `NoteDocument.editableDocument(from:)`; unsupported content
must survive round trips without normalization or field loss.

See [distributed architecture](../docs/DISTRIBUTED_CLIENT_ARCHITECTURE.md) for
identity, ownership, replay and conflict semantics, and
[device testing](../docs/DISTRIBUTED_CLIENT_TESTING.md) for acceptance checks.
