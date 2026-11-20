import Foundation
import WovenProtocol

// Typed reads and writes for notes, pages, sheets and apps, and their version
// history. Rows travel by the newest-wins-loser-kept rule; a local write that
// replaces a version its writer had not seen keeps that version the same way.

extension Library {
  /// While a document is edited, the version it had is saved at most this often.
  static let checkpointInterval: Int64 = 5 * 60 * 1000

  public func artifacts(includeTrashed: Bool = false) async throws -> [Artifact] {
    try await read { db in
      try db.query("SELECT id, kind, title, folder_id, pinned, trashed, created_at, stamp, preview FROM artifacts " +
                   "WHERE deleted = 0\(includeTrashed ? "" : " AND trashed = 0") ORDER BY stamp DESC, id").map(Self.artifact)
    }
  }

  public func artifact(_ id: String) async throws -> ArtifactDocument {
    try await read { db in
      guard let row = try db.query("SELECT * FROM artifacts WHERE id = ? AND deleted = 0", [.text(id)]).first else {
        throw LibraryError(.notFound, "No artifact \(id).")
      }
      return ArtifactDocument(artifact: Self.artifact(row), body: row.text("body") ?? "")
    }
  }

  public func createArtifact(id: String = UUID().uuidString.lowercased(), kind: NoteArtifactKind, title: String,
                             folderID: String?, body: String?) async throws -> ArtifactDocument {
    let body = try body ?? NoteDocument(kind: kind).encoded()
    try await write { writer in
      try writer.put("artifacts", id: id, [
        "kind": .text(kind.rawValue), "title": .text(title), "folder_id": folderID.map(SQLValue.text) ?? .null,
        "body": .text(body), "preview": .text(Self.preview(body)), "created_at": .integer(Writer.now()),
      ])
    }
    return try await artifact(id)
  }

  /// Writes a title, a document or both. When the artifact changed since
  /// `basedOn`, the version this write replaces unseen is saved in its
  /// history; otherwise the version it replaces is saved as a checkpoint when
  /// none was saved for a while. Returns whether it replaced a version unseen.
  public func writeArtifact(_ id: String, basedOn: String, title: String?, body: String?) async throws
    -> (ArtifactDocument, replacedUnseen: Bool) {
    var values: [String: SQLValue] = [:]
    if let title { values["title"] = .text(title) }
    if let body {
      values["body"] = .text(body)
      values["preview"] = .text(Self.preview(body))
    }
    let changes = values
    let replaced = try await write { writer -> Bool in
      let current = try Self.liveArtifact(writer, id)
      let stamp = current.text("stamp") ?? ""
      if changes.allSatisfy({ current[$0.key] == $0.value }) { return false }
      let kept = current.values(excluding: Table.standardColumns)
      let table = try Self.artifactsTable()
      var replaced = false
      if stamp != basedOn {
        replaced = true
        try writer.saveLoser("artifact_versions", of: table, id: id, stamp: stamp, values: kept)
      } else if try Self.checkpointDue(writer, id, stamp: stamp), !Self.isBlank(current) {
        try writer.saveLoser("artifact_versions", of: table, id: id, stamp: stamp, values: kept, reason: "checkpoint")
      }
      try writer.put("artifacts", id: id, changes)
      return replaced
    }
    return (try await artifact(id), replaced)
  }

  /// Renames, moves, pins, trashes or restores. Nil leaves a field;
  /// `folderID` of `.some(nil)` takes it out of its folder.
  public func updateArtifact(_ id: String, title: String? = nil, folderID: String?? = nil, pinned: Bool? = nil,
                             trashed: Bool? = nil) async throws -> Artifact {
    var values: [String: SQLValue] = [:]
    if let title { values["title"] = .text(title) }
    if let folderID { values["folder_id"] = folderID.map(SQLValue.text) ?? .null }
    if let pinned { values["pinned"] = .integer(pinned ? 1 : 0) }
    if let trashed { values["trashed"] = .integer(trashed ? 1 : 0) }
    let changes = values
    try await write { writer in
      let current = try Self.liveArtifact(writer, id)
      if !changes.allSatisfy({ current[$0.key] == $0.value }) { try writer.put("artifacts", id: id, changes) }
    }
    return try await artifact(id).artifact
  }

  /// Deletes an artifact and its history for good, in every library.
  public func deleteArtifact(_ id: String) async throws {
    try await delete("artifacts", id: id)
  }

  /// An artifact's saved versions, newest first.
  public func artifactVersions(_ artifactID: String) async throws -> [ArtifactVersion] {
    try await read { db in
      try db.query("SELECT id, artifact_id, version_stamp, kind, title, saved_at, reason FROM artifact_versions " +
                   "WHERE artifact_id = ? AND deleted = 0 ORDER BY version_stamp DESC", [.text(artifactID)]).map(Self.version)
    }
  }

  public func artifactVersion(_ versionID: String) async throws -> ArtifactVersionDocument {
    try await read { db in
      guard let row = try db.query("SELECT * FROM artifact_versions WHERE id = ? AND deleted = 0", [.text(versionID)]).first else {
        throw LibraryError(.notFound, "No version \(versionID).")
      }
      return ArtifactVersionDocument(version: Self.version(row), body: row.text("body") ?? "")
    }
  }

  /// Makes a saved version's title and document current. The version it
  /// replaces is saved first.
  public func restoreArtifactVersion(_ artifactID: String, versionID: String) async throws -> ArtifactDocument {
    try await write { writer in
      let current = try Self.liveArtifact(writer, artifactID)
      guard let version = try writer.row("artifact_versions", versionID), !version.bool("deleted"),
            version.text("artifact_id") == artifactID else {
        throw LibraryError(.notFound, "No version \(versionID) of this artifact.")
      }
      try writer.saveLoser("artifact_versions", of: try Self.artifactsTable(), id: artifactID,
                           stamp: current.text("stamp") ?? "", values: current.values(excluding: Table.standardColumns),
                           reason: "restore")
      let body = version.text("body") ?? ""
      try writer.put("artifacts", id: artifactID, [
        "title": version["title"], "body": .text(body), "preview": .text(Self.preview(body)),
      ])
    }
    return try await artifact(artifactID)
  }

  /// Applies edits to an app's saved state against its current document, all
  /// or none. A key whose version differs from the one expected throws
  /// `ArtifactStateError.conflict`.
  public func editAppState(_ artifactID: String, edits: [ArtifactStateEdit]) async throws -> ArtifactStateWriteResult {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    return try await write { writer in
      let current = try Self.liveArtifact(writer, artifactID)
      var document = try NoteDocument.editableDocument(from: current.text("body") ?? "")
      let changed = try document.applyArtifactStateEdits(edits, at: timestamp)
      var stamp = current.text("stamp") ?? ""
      if changed {
        let body = try document.encoded()
        stamp = try writer.put("artifacts", id: artifactID, ["body": .text(body), "preview": .text(Self.preview(body))])
      }
      let key = edits.last?.key ?? ""
      return ArtifactStateWriteResult(noteID: artifactID, key: key, version: document.artifactState?[key]?.version ?? 0,
                                      changed: changed, revision: stamp, snapshot: document.artifactStateSnapshot)
    }
  }

  /// Changes an artifact's document with `change`, against its current
  /// version, as one write. For the server's own edits, such as recording
  /// the session a page task runs in.
  public func changeArtifact(_ id: String, _ change: @escaping @Sendable (inout NoteDocument) throws -> Void) async throws {
    try await write { writer in
      let current = try Self.liveArtifact(writer, id)
      var document = try NoteDocument.editableDocument(from: current.text("body") ?? "")
      let before = document
      try change(&document)
      guard document != before else { return }
      let body = try document.encoded()
      try writer.put("artifacts", id: id, ["body": .text(body), "preview": .text(Self.preview(body))])
    }
  }

  // MARK: Helpers

  private static func liveArtifact(_ writer: Writer, _ id: String) throws -> Row {
    guard let row = try writer.row("artifacts", id), !row.bool("deleted") else {
      throw LibraryError(.notFound, "No artifact \(id).")
    }
    return row
  }

  private static func artifactsTable() throws -> Table {
    guard let table = Schema.byName["artifacts"] else { throw LibraryError(.invalid, "No artifacts table.") }
    return table
  }

  /// No version of this artifact was saved within the checkpoint interval
  /// before the version being replaced.
  private static func checkpointDue(_ writer: Writer, _ id: String, stamp: String) throws -> Bool {
    let last = try writer.db.query("SELECT MAX(saved_at) AS last FROM artifact_versions WHERE artifact_id = ?",
                                   [.text(id)]).first?.integer("last")
    guard let last else { return true }
    return (Stamp(text: stamp)?.time ?? 0) - last >= checkpointInterval
  }

  /// An artifact with nothing in it yet, as one is just after it is created.
  private static func isBlank(_ row: Row) -> Bool {
    let document = NoteDocument.decode(row.text("body") ?? "")
    return document.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && document.html.isEmpty
      && (document.kind != .canvas || document.blocks.isEmpty)
  }

  /// One line under the title.
  static func preview(_ body: String) -> String {
    let document = NoteDocument.decode(body)
    switch document.kind {
    case .note:
      let line = document.plainText.split(whereSeparator: \.isNewline)
        .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      return String((line ?? "").trimmingCharacters(in: .whitespaces).prefix(160))
    case .spreadsheet:
      guard case .table(let table)? = document.blocks.first else { return "" }
      return "\(table.rows.count) × \(table.columns.count)"
    case .canvas:
      let count = document.blocks.count
      return count == 1 ? "1 component" : "\(count) components"
    case .html:
      return ""
    }
  }

  private static func artifact(_ row: Row) -> Artifact {
    let stamp = row.text("stamp") ?? ""
    let updated = Stamp(text: stamp)?.time ?? row.integer("created_at") ?? 0
    return Artifact(id: row.text("id") ?? "", kind: NoteArtifactKind(rawValue: row.text("kind") ?? "") ?? .note,
                    title: row.text("title") ?? "", folderID: row.text("folder_id"), pinned: row.bool("pinned"),
                    trashed: row.bool("trashed"), createdAt: row.date("created_at"),
                    updatedAt: Date(timeIntervalSince1970: Double(updated) / 1000), stamp: stamp,
                    preview: row.text("preview") ?? "")
  }

  private static func version(_ row: Row) -> ArtifactVersion {
    let stamp = row.text("version_stamp") ?? ""
    return ArtifactVersion(id: row.text("id") ?? "", artifactID: row.text("artifact_id") ?? "",
                           kind: NoteArtifactKind(rawValue: row.text("kind") ?? "") ?? .note, title: row.text("title") ?? "",
                           savedAt: row.date("saved_at"),
                           reason: ArtifactVersion.Reason(rawValue: row.text("reason") ?? "") ?? .conflict,
                           machineID: Stamp.machine(of: stamp) ?? "")
  }
}
