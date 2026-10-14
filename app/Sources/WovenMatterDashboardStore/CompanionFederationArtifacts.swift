import CryptoKit
import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  public func companionSavedArtifacts() throws -> [CompanionArtifactManifest] {
    try withLock { try federationValuesUnlocked("SELECT manifest FROM companion_saved_artifacts ORDER BY id", as: CompanionArtifactManifest.self) }
  }
  public func companionArtifactTransfer(id: String) throws -> CompanionArtifactTransfer? {
    try withLock { try artifactTransferUnlocked(id: id) }
  }
  private func artifactTransferUnlocked(id: String) throws -> CompanionArtifactTransfer? {
    if let manifest = try federationValuesUnlocked("SELECT manifest FROM companion_artifact_uploads WHERE id=?", bindings: [id], as: CompanionArtifactManifest.self).first {
      return try CompanionArtifactTransfer(manifest: manifest, nextOffset: federationScalarUnlocked("SELECT next_offset FROM companion_artifact_uploads WHERE id=?", bindings: [id]), complete: false)
    }
    return try committedArtifactUnlocked(id).map { CompanionArtifactTransfer(manifest: $0, nextOffset: $0.byteCount, complete: true) }
  }
  private func committedArtifactUnlocked(_ id: String) throws -> CompanionArtifactManifest? {
    try federationValuesUnlocked("SELECT manifest FROM companion_saved_artifacts WHERE id=?", bindings: [id], as: CompanionArtifactManifest.self).first
  }
  public func registerCompanionArtifact(_ request: CompanionArtifactRegistration, deviceID: String) throws -> CompanionArtifactTransfer {
    try transaction {
      var manifest = request.manifest
      _ = try federationAuthorizedWorkspaceUnlocked(manifest.workspaceID, deviceID: deviceID)
      guard federationID(manifest.id), manifest.byteCount >= 0, manifest.byteCount <= 512 * 1_024 * 1_024,
            manifest.title.utf8.count <= 4_096, !manifest.title.isEmpty, manifest.mediaType.utf8.count <= 256,
            manifest.sha256.count == 64, manifest.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
        throw federationError("invalid_artifact", "Saved artifacts need a stable identity, SHA-256 digest, and size no larger than 512 MiB.")
      }
      let existing = try committedArtifactUnlocked(manifest.id)
      if let existing {
        guard existing.workspaceID == manifest.workspaceID else { throw federationError("wrong_owner", "This saved artifact belongs to another workspace.") }
        manifest.revision = existing.revision
        if manifest == existing { return CompanionArtifactTransfer(manifest: existing, nextOffset: existing.byteCount, complete: true) }
        guard !existing.deleted, request.expectedRevision == existing.revision else { throw federationError("revision_conflict", "This artifact changed or was deleted. Keep your local copy and refresh its revision.") }
      } else if request.expectedRevision != nil || manifest.deleted {
        throw federationError("revision_conflict", "The saved artifact does not exist.")
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
        try companionExecuteUnlocked("DELETE FROM companion_artifact_chunks WHERE artifact_id=?", values: [manifest.id])
        return CompanionArtifactTransfer(manifest: manifest, nextOffset: manifest.byteCount, complete: true)
      }
      let statement = try prepareUnlocked("INSERT INTO companion_artifact_uploads(id,revision,manifest) VALUES (?,?,?)")
      defer { sqlite3_finalize(statement) }
      try bind(manifest.id, at: 1, to: statement); sqlite3_bind_int64(statement, 2, manifest.revision)
      try bind(JSONEncoder().encode(manifest), at: 3, to: statement); try stepDone(statement)
      return CompanionArtifactTransfer(manifest: manifest, nextOffset: 0, complete: false)
    }
  }
  public func appendCompanionArtifactChunk(_ chunk: CompanionArtifactChunk, deviceID: String) throws -> CompanionArtifactTransfer {
    try transaction {
      guard let transfer = try artifactTransferUnlocked(id: chunk.id), transfer.manifest.revision == chunk.revision else {
        throw federationError("revision_conflict", "Refresh the artifact transfer before continuing.")
      }
      _ = try federationAuthorizedWorkspaceUnlocked(transfer.manifest.workspaceID, deviceID: deviceID)
      guard !chunk.data.isEmpty, chunk.data.count <= CompanionFederationProtocol.maximumArtifactChunkBytes,
            chunk.offset >= 0, chunk.offset <= transfer.manifest.byteCount,
            Int64(chunk.data.count) <= transfer.manifest.byteCount - chunk.offset else {
        throw federationError("invalid_chunk", "The artifact chunk exceeds its declared bounds.")
      }
      let lookup = try prepareUnlocked("SELECT bytes FROM companion_artifact_chunks WHERE artifact_id=? AND revision=? AND offset=?")
      defer { sqlite3_finalize(lookup) }
      try bind(chunk.id, at: 1, to: lookup); sqlite3_bind_int64(lookup, 2, chunk.revision); sqlite3_bind_int64(lookup, 3, chunk.offset)
      let code = sqlite3_step(lookup)
      if code == SQLITE_ROW {
        guard try blob(lookup, column: 0) == chunk.data else { throw federationError("chunk_conflict", "A saved artifact chunk cannot be replaced with different bytes.") }
        return transfer
      }
      guard code == SQLITE_DONE else { throw stepError() }
      guard !transfer.complete, chunk.offset == transfer.nextOffset else { throw federationError("chunk_gap", "Resume from the acknowledged next artifact offset.") }
      let insert = try prepareUnlocked("INSERT INTO companion_artifact_chunks VALUES (?,?,?,?)")
      defer { sqlite3_finalize(insert) }
      try bind(chunk.id, at: 1, to: insert); sqlite3_bind_int64(insert, 2, chunk.revision); sqlite3_bind_int64(insert, 3, chunk.offset)
      try bind(chunk.data, at: 4, to: insert); try stepDone(insert)
      let next = chunk.offset + Int64(chunk.data.count)
      let update = try prepareUnlocked("UPDATE companion_artifact_uploads SET next_offset=? WHERE id=?")
      defer { sqlite3_finalize(update) }
      sqlite3_bind_int64(update, 1, next); try bind(chunk.id, at: 2, to: update); try stepDone(update)
      return CompanionArtifactTransfer(manifest: transfer.manifest, nextOffset: next, complete: false)
    }
  }
  public func commitCompanionArtifact(_ request: CompanionArtifactCommit, deviceID: String) throws -> CompanionArtifactManifest {
    try transaction {
      guard let transfer = try artifactTransferUnlocked(id: request.id), transfer.manifest.revision == request.revision else {
        throw federationError("revision_conflict", "This transfer revision is no longer current.")
      }
      _ = try federationAuthorizedWorkspaceUnlocked(transfer.manifest.workspaceID, deviceID: deviceID)
      if transfer.complete { return transfer.manifest }
      guard transfer.nextOffset == transfer.manifest.byteCount else { throw federationError("incomplete_artifact", "The saved artifact has not finished uploading.") }
      var hash = SHA256(); var offset: Int64 = 0
      let statement = try prepareUnlocked("SELECT offset,bytes FROM companion_artifact_chunks WHERE artifact_id=? AND revision=? ORDER BY offset")
      defer { sqlite3_finalize(statement) }
      try bind(request.id, at: 1, to: statement); sqlite3_bind_int64(statement, 2, request.revision)
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW, sqlite3_column_int64(statement, 0) == offset else { throw federationError("chunk_gap", "The artifact transfer has missing data.") }
        let bytes = try blob(statement, column: 1); hash.update(data: bytes); offset += Int64(bytes.count)
      }
      let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
      guard offset == transfer.manifest.byteCount, digest == transfer.manifest.sha256 else {
        throw federationError("artifact_digest", "The transferred artifact does not match its source digest. Your existing saved revision is preserved.")
      }
      try saveCommittedArtifactUnlocked(transfer.manifest)
      try companionExecuteUnlocked("DELETE FROM companion_artifact_uploads WHERE id=?", values: [request.id])
      let cleanup = try prepareUnlocked("DELETE FROM companion_artifact_chunks WHERE artifact_id=? AND revision<>?")
      defer { sqlite3_finalize(cleanup) }
      try bind(request.id, at: 1, to: cleanup); sqlite3_bind_int64(cleanup, 2, request.revision); try stepDone(cleanup)
      return transfer.manifest
    }
  }
  private func saveCommittedArtifactUnlocked(_ manifest: CompanionArtifactManifest) throws {
    let statement = try prepareUnlocked("INSERT INTO companion_saved_artifacts VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,manifest=excluded.manifest")
    defer { sqlite3_finalize(statement) }
    try bind(manifest.id, at: 1, to: statement); sqlite3_bind_int64(statement, 2, manifest.revision)
    try bind(JSONEncoder().encode(manifest), at: 3, to: statement); try stepDone(statement)
  }
  public func companionArtifactChunk(id: String, revision: Int64?, offset: Int64) throws -> CompanionArtifactChunk {
    try withLock {
      guard let manifest = try committedArtifactUnlocked(id), !manifest.deleted,
            revision == nil || revision == manifest.revision, offset >= 0, offset < manifest.byteCount else {
        throw federationError("not_found", "This saved artifact revision or offset is unavailable.")
      }
      let statement = try prepareUnlocked("SELECT offset,bytes FROM companion_artifact_chunks WHERE artifact_id=? AND revision=? AND offset<=? ORDER BY offset DESC LIMIT 1")
      defer { sqlite3_finalize(statement) }
      try bind(id, at: 1, to: statement); sqlite3_bind_int64(statement, 2, manifest.revision); sqlite3_bind_int64(statement, 3, offset)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw WorkspaceDatabaseError.corruptRow }
      let start = sqlite3_column_int64(statement, 0); let bytes = try blob(statement, column: 1)
      guard offset - start < bytes.count else { throw WorkspaceDatabaseError.corruptRow }
      return CompanionArtifactChunk(id: id, revision: manifest.revision, offset: offset, data: bytes.dropFirst(Int(offset - start)))
    }
  }
}

extension WorkspaceDatabase {
  public func companionSavedArtifacts() async throws -> [CompanionArtifactManifest] { try await read { try $0.companionSavedArtifacts() } }
  public func companionArtifactTransfer(id: String) async throws -> CompanionArtifactTransfer? { try await read { try $0.companionArtifactTransfer(id: id) } }
  public func registerCompanionArtifact(_ request: CompanionArtifactRegistration, deviceID: String) async throws -> CompanionArtifactTransfer {
    try await write { try $0.registerCompanionArtifact(request, deviceID: deviceID) }
  }
  public func appendCompanionArtifactChunk(_ chunk: CompanionArtifactChunk, deviceID: String) async throws -> CompanionArtifactTransfer {
    try await write { try $0.appendCompanionArtifactChunk(chunk, deviceID: deviceID) }
  }
  public func commitCompanionArtifact(_ request: CompanionArtifactCommit, deviceID: String) async throws -> CompanionArtifactManifest {
    try await write { try $0.commitCompanionArtifact(request, deviceID: deviceID) }
  }
  public func companionArtifactChunk(id: String, revision: Int64? = nil, offset: Int64) async throws -> CompanionArtifactChunk {
    try await read { try $0.companionArtifactChunk(id: id, revision: revision, offset: offset) }
  }
}
