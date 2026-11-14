#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  public func librarySavedArtifacts() throws -> [LibraryArtifactManifest] {
    try withLock { try federationValuesUnlocked("SELECT manifest FROM saved_artifacts ORDER BY id", as: LibraryArtifactManifest.self, skippingUnreadable: true) }
  }
  public func libraryArtifactTransfer(id: String) throws -> LibraryArtifactTransfer? {
    try withLock { try artifactTransferUnlocked(id: id) }
  }
  private func artifactTransferUnlocked(id: String) throws -> LibraryArtifactTransfer? {
    if let manifest = try federationValuesUnlocked("SELECT manifest FROM artifact_uploads WHERE id=?", bindings: [id], as: LibraryArtifactManifest.self).first {
      return try LibraryArtifactTransfer(manifest: manifest, nextOffset: federationScalarUnlocked("SELECT next_offset FROM artifact_uploads WHERE id=?", bindings: [id]), complete: false)
    }
    return try committedArtifactUnlocked(id).map { LibraryArtifactTransfer(manifest: $0, nextOffset: $0.byteCount, complete: true) }
  }
  private func committedArtifactUnlocked(_ id: String) throws -> LibraryArtifactManifest? {
    try federationValuesUnlocked("SELECT manifest FROM saved_artifacts WHERE id=?", bindings: [id], as: LibraryArtifactManifest.self).first
  }
  public func registerLibraryArtifact(_ request: LibraryArtifactRegistration, deviceID: String) throws -> LibraryArtifactTransfer {
    try transaction {
      var manifest = request.manifest
      _ = try federationAuthorizedWorkspaceUnlocked(manifest.workspaceID, deviceID: deviceID)
      guard federationID(manifest.id), manifest.byteCount >= 0, manifest.byteCount <= 512 * 1_024 * 1_024,
            manifest.title.utf8.count <= 4_096, !manifest.title.isEmpty, manifest.mediaType.utf8.count <= 256,
            manifest.sha256.count == 64, manifest.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw federationError("invalid_artifact", "Saved assets need a stable identity, SHA-256 digest, and size no larger than 512 MiB.")
      }
      let existing = try committedArtifactUnlocked(manifest.id)
      if let existing {
        guard existing.workspaceID == manifest.workspaceID else { throw federationError("wrong_owner", "This saved asset belongs to another workspace.") }
        manifest.revision = existing.revision
        if manifest == existing { return LibraryArtifactTransfer(manifest: existing, nextOffset: existing.byteCount, complete: true) }
        guard !existing.deleted, request.expectedRevision == existing.revision else { throw federationError("revision_conflict", "This artifact changed or was deleted. Keep your local copy and refresh its revision.") }
      } else if request.expectedRevision != nil || manifest.deleted {
        throw federationError("revision_conflict", "The saved asset does not exist.")
      }
      if let pending = try artifactTransferUnlocked(id: manifest.id), !pending.complete {
        manifest.revision = pending.manifest.revision
        guard manifest == pending.manifest else { throw federationError("upload_in_progress", "Finish this artifact transfer before replacing its contents, or save the new output with a new identity.") }
        return pending
      }
      manifest.revision = (existing?.revision ?? 0) + 1
      if manifest.deleted {
        // A tombstone references the previous bytes; deleting an artifact never uploads content.
        guard let existing, manifest.sha256 == existing.sha256, manifest.byteCount == existing.byteCount else {
          throw federationError("invalid_artifact", "A deletion must reference the committed artifact.")
        }
        try saveCommittedArtifactUnlocked(manifest)
        try toolsExecuteUnlocked("DELETE FROM artifact_chunks WHERE artifact_id=?", [manifest.id])
        return LibraryArtifactTransfer(manifest: manifest, nextOffset: manifest.byteCount, complete: true)
      }
      let statement = try prepareUnlocked("INSERT INTO artifact_uploads(id,revision,manifest) VALUES (?,?,?)")
      defer { sqlite3_finalize(statement) }
      try bind(manifest.id, at: 1, to: statement); sqlite3_bind_int64(statement, 2, manifest.revision)
      try bindJSON(manifest, at: 3, to: statement); try stepDone(statement)
      return LibraryArtifactTransfer(manifest: manifest, nextOffset: 0, complete: false)
    }
  }
  public func appendLibraryArtifactChunk(_ chunk: LibraryArtifactChunk, deviceID: String) throws -> LibraryArtifactTransfer {
    try transaction {
      guard let transfer = try artifactTransferUnlocked(id: chunk.id), transfer.manifest.revision == chunk.revision else {
        throw federationError("revision_conflict", "Refresh the artifact transfer before continuing.")
      }
      _ = try federationAuthorizedWorkspaceUnlocked(transfer.manifest.workspaceID, deviceID: deviceID)
      guard !chunk.data.isEmpty, chunk.data.count <= FederationProtocol.maximumArtifactChunkBytes,
            chunk.offset >= 0, chunk.offset <= transfer.manifest.byteCount,
            Int64(chunk.data.count) <= transfer.manifest.byteCount - chunk.offset else {
        throw federationError("invalid_chunk", "The artifact chunk exceeds its declared bounds.")
      }
      let lookup = try prepareUnlocked("SELECT sha256,byte_count FROM artifact_chunks WHERE artifact_id=? AND revision=? AND offset=?")
      defer { sqlite3_finalize(lookup) }
      try bind(chunk.id, at: 1, to: lookup); sqlite3_bind_int64(lookup, 2, chunk.revision); sqlite3_bind_int64(lookup, 3, chunk.offset)
      let code = sqlite3_step(lookup)
      if code == SQLITE_ROW {
        guard try text(lookup, column: 0) == SHA256.hash(data: chunk.data).hexString, sqlite3_column_int64(lookup, 1) == Int64(chunk.data.count) else {
          throw federationError("chunk_conflict", "A saved asset chunk cannot be replaced with different bytes.")
        }
        return transfer
      }
      guard code == SQLITE_DONE else { throw stepError() }
      guard !transfer.complete, chunk.offset == transfer.nextOffset else { throw federationError("chunk_gap", "Resume from the acknowledged next artifact offset.") }
      // The bytes are a file before their row names them.
      let hash = try libraryFiles.retainChunk(chunk.data)
      let insert = try prepareUnlocked("INSERT INTO artifact_chunks(artifact_id,revision,offset,sha256,byte_count) VALUES (?,?,?,?,?)")
      defer { sqlite3_finalize(insert) }
      try bind(chunk.id, at: 1, to: insert); sqlite3_bind_int64(insert, 2, chunk.revision); sqlite3_bind_int64(insert, 3, chunk.offset)
      try bind(hash, at: 4, to: insert); sqlite3_bind_int64(insert, 5, Int64(chunk.data.count)); try stepDone(insert)
      let next = chunk.offset + Int64(chunk.data.count)
      let update = try prepareUnlocked("UPDATE artifact_uploads SET next_offset=? WHERE id=?")
      defer { sqlite3_finalize(update) }
      sqlite3_bind_int64(update, 1, next); try bind(chunk.id, at: 2, to: update); try stepDone(update)
      return LibraryArtifactTransfer(manifest: transfer.manifest, nextOffset: next, complete: false)
    }
  }
  public func commitLibraryArtifact(_ request: LibraryArtifactCommit, deviceID: String) throws -> LibraryArtifactManifest {
    try transaction {
      guard let transfer = try artifactTransferUnlocked(id: request.id), transfer.manifest.revision == request.revision else {
        throw federationError("revision_conflict", "This transfer revision is no longer current.")
      }
      _ = try federationAuthorizedWorkspaceUnlocked(transfer.manifest.workspaceID, deviceID: deviceID)
      if transfer.complete { return transfer.manifest }
      guard transfer.nextOffset == transfer.manifest.byteCount else { throw federationError("incomplete_artifact", "The saved asset has not finished uploading.") }
      var hash = SHA256(); var offset: Int64 = 0
      let statement = try prepareUnlocked("SELECT offset,sha256,byte_count FROM artifact_chunks WHERE artifact_id=? AND revision=? ORDER BY offset")
      defer { sqlite3_finalize(statement) }
      try bind(request.id, at: 1, to: statement); sqlite3_bind_int64(statement, 2, request.revision)
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW, sqlite3_column_int64(statement, 0) == offset else { throw federationError("chunk_gap", "The artifact transfer has missing data.") }
        let bytes = try libraryFiles.chunk(text(statement, column: 1), byteCount: sqlite3_column_int64(statement, 2))
        hash.update(data: bytes); offset += Int64(bytes.count)
      }
      let digest = hash.finalize().hexString
      guard offset == transfer.manifest.byteCount, digest == transfer.manifest.sha256 else {
        throw federationError("artifact_digest", "The transferred artifact does not match its source digest. Your existing saved revision is preserved.")
      }
      try saveCommittedArtifactUnlocked(transfer.manifest)
      try toolsExecuteUnlocked("DELETE FROM artifact_uploads WHERE id=?", [request.id])
      let cleanup = try prepareUnlocked("DELETE FROM artifact_chunks WHERE artifact_id=? AND revision<>?")
      defer { sqlite3_finalize(cleanup) }
      try bind(request.id, at: 1, to: cleanup); sqlite3_bind_int64(cleanup, 2, request.revision); try stepDone(cleanup)
      return transfer.manifest
    }
  }
  private func saveCommittedArtifactUnlocked(_ manifest: LibraryArtifactManifest) throws {
    let statement = try prepareUnlocked("INSERT INTO saved_artifacts VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,manifest=excluded.manifest")
    defer { sqlite3_finalize(statement) }
    try bind(manifest.id, at: 1, to: statement); sqlite3_bind_int64(statement, 2, manifest.revision)
    try bindJSON(manifest, at: 3, to: statement); try stepDone(statement)
  }
  public func libraryArtifactChunk(id: String, revision: Int64?, offset: Int64) throws -> LibraryArtifactChunk {
    try withLock {
      guard let manifest = try committedArtifactUnlocked(id), !manifest.deleted,
            revision == nil || revision == manifest.revision, offset >= 0, offset < manifest.byteCount else {
        throw federationError("not_found", "This saved asset revision or offset is unavailable.")
      }
      let statement = try prepareUnlocked("SELECT offset,sha256,byte_count FROM artifact_chunks WHERE artifact_id=? AND revision=? AND offset<=? ORDER BY offset DESC LIMIT 1")
      defer { sqlite3_finalize(statement) }
      try bind(id, at: 1, to: statement); sqlite3_bind_int64(statement, 2, manifest.revision); sqlite3_bind_int64(statement, 3, offset)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw WorkspaceDatabaseError.corruptRow }
      let start = sqlite3_column_int64(statement, 0)
      guard offset - start < sqlite3_column_int64(statement, 2) else { throw WorkspaceDatabaseError.corruptRow }
      let bytes = try libraryFiles.chunk(text(statement, column: 1), byteCount: sqlite3_column_int64(statement, 2))
      guard offset - start < bytes.count else { throw WorkspaceDatabaseError.corruptRow }
      return LibraryArtifactChunk(id: id, revision: manifest.revision, offset: offset, data: bytes.dropFirst(Int(offset - start)))
    }
  }
}

extension WorkspaceDatabase {
  public func librarySavedArtifacts() async throws -> [LibraryArtifactManifest] { try await read { try $0.librarySavedArtifacts() } }
  public func libraryArtifactTransfer(id: String) async throws -> LibraryArtifactTransfer? { try await read { try $0.libraryArtifactTransfer(id: id) } }
  public func registerLibraryArtifact(_ request: LibraryArtifactRegistration, deviceID: String) async throws -> LibraryArtifactTransfer {
    try await write { try $0.registerLibraryArtifact(request, deviceID: deviceID) }
  }
  public func appendLibraryArtifactChunk(_ chunk: LibraryArtifactChunk, deviceID: String) async throws -> LibraryArtifactTransfer {
    try await write { try $0.appendLibraryArtifactChunk(chunk, deviceID: deviceID) }
  }
  public func commitLibraryArtifact(_ request: LibraryArtifactCommit, deviceID: String) async throws -> LibraryArtifactManifest {
    try await write { try $0.commitLibraryArtifact(request, deviceID: deviceID) }
  }
  public func libraryArtifactChunk(id: String, revision: Int64? = nil, offset: Int64) async throws -> LibraryArtifactChunk {
    try await read { try $0.libraryArtifactChunk(id: id, revision: revision, offset: offset) }
  }
}
