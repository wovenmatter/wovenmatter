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
  public func applyLibraryMutation(_ request: LibraryMutation) throws -> LibraryMutationResult {
    try transaction {
      let fingerprint = try libraryFingerprint(request)
      let lookup = try prepareUnlocked("SELECT request, response FROM device_mutation_receipts WHERE device_id = ? AND operation_id = ?")
      defer { sqlite3_finalize(lookup) }
      try bind(request.deviceID, at: 1, to: lookup); try bind(request.operationID, at: 2, to: lookup)
      let code = sqlite3_step(lookup)
      if code == SQLITE_ROW {
        guard try blob(lookup, column: 0) == fingerprint else {
          return LibraryMutationResult(operationID: request.operationID, status: .invalid, message: "This operation ID was already used for different content.")
        }
        return try JSONDecoder().decode(LibraryMutationResult.self, from: blob(lookup, column: 1))
      }
      guard code == SQLITE_DONE else { throw stepError() }
      var result = try performLibraryMutationUnlocked(request)
      // A permanent receipt records the original acceptance/revision without
      // retaining a new multi-megabyte document for every acknowledged edit.
      // The caller already owns an accepted local body; conflict bodies are
      // fetched explicitly from the canonical note endpoint.
      if var note = result.note {
        note.content = ""; note.contentIncluded = false; result.note = note
      }
      let receipt = try prepareUnlocked("INSERT INTO device_mutation_receipts(device_id, operation_id, request, response) VALUES (?, ?, ?, ?)")
      defer { sqlite3_finalize(receipt) }
      try bind(request.deviceID, at: 1, to: receipt); try bind(request.operationID, at: 2, to: receipt)
      try bind(fingerprint, at: 3, to: receipt); try bind(JSONEncoder().encode(result), at: 4, to: receipt)
      try stepDone(receipt)
      return result
    }
  }

  private func performLibraryMutationUnlocked(_ request: LibraryMutation) throws -> LibraryMutationResult {
    func result(_ status: LibraryMutationResult.Status, _ message: String? = nil,
                note: LibraryNote? = nil, folder: LibraryFolder? = nil) -> LibraryMutationResult {
      LibraryMutationResult(operationID: request.operationID, status: status, folder: folder, note: note, message: message)
    }
    guard UUID(uuidString: request.operationID) != nil, UUID(uuidString: request.deviceID) != nil,
          let resourceID = UUID(uuidString: request.resourceID), resourceID.uuidString.lowercased() == request.resourceID,
          request.folderID.map({ UUID(uuidString: $0) != nil }) ?? true,
          (request.title?.utf8.count ?? 0) <= 4_096 else {
      return result(.invalid, "Use stable UUID identities and a title shorter than 4 KiB.")
    }
    let now = Self.timestamp(Date())
    switch request.kind {
    case .createFolder:
      guard let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return result(.invalid, "Enter a folder name.") }
      if try libraryVersionUnlocked(kind: "folder", id: request.resourceID) != nil {
        return try result(.conflict, "This folder ID already exists or was deleted.", folder: libraryFolderUnlocked(id: request.resourceID))
      }
      guard let binding = request.folderExecution else {
        return result(.invalid, "Create the folder in an execution workspace with a bound directory.")
      }
      let location = WorkspaceFolderLocation(workspaceID: binding.workspaceID, rootPath: binding.rootPath, managed: false)
      guard (try? validateExecutionLocation(location)) != nil else {
        return result(.invalid, "A folder needs a valid execution workspace and absolute directory.")
      }
      try toolsExecuteUnlocked("INSERT INTO folders(id, name, position, created_at, updated_at) VALUES (?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM folders), ?, ?)", [request.resourceID, title, now, now])
      try toolsExecuteUnlocked("INSERT INTO folder_execution_roots(folder_id,workspace_id,root_path,managed) VALUES(?,?,?,0)",
        [request.resourceID, binding.workspaceID, binding.rootPath])
      return try result(.accepted, folder: libraryFolderUnlocked(id: request.resourceID))
    case .renameFolder, .deleteFolder:
      guard let folder = try libraryFolderUnlocked(id: request.resourceID) else { return result(.notFound, "The folder was deleted. Your writing is retained on this device.") }
      guard request.expectedRevision == folder.revision else { return result(.conflict, "The folder changed since it was read.", folder: folder) }
      if request.kind == .deleteFolder {
        try toolsExecuteUnlocked("DELETE FROM folders WHERE id = ?", [request.resourceID])
        return result(.accepted)
      }
      guard let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return result(.invalid, "Enter a folder name.") }
      try toolsExecuteUnlocked("UPDATE folders SET name = ?, updated_at = ? WHERE id = ?", [title, now, request.resourceID])
      return try result(.accepted, folder: libraryFolderUnlocked(id: request.resourceID))
    case .createNote:
      if try libraryVersionUnlocked(kind: "note", id: request.resourceID) != nil {
        // Deleted here: a phone re-creating its unchanged copy after moving
        // to this host applies the deletion instead of showing a conflict.
        guard let existing = try libraryNoteUnlocked(id: request.resourceID) else {
          var deleted = result(.notFound, "This note was deleted on another device."); deleted.deleted = true
          return deleted
        }
        return result(.conflict, "This note ID already exists.", note: existing)
      }
      guard let title = request.title, let content = request.content else { return result(.invalid, "The note needs a title and a document.") }
      do {
        let document = try NoteDocument.editableDocument(from: content)
        guard libraryEditableArtifact(document) else { return result(.invalid, "Linked database content is read-only on clients.") }
      } catch { return result(.invalid, error.localizedDescription) }
      if let folderID = request.folderID, try libraryFolderUnlocked(id: folderID) == nil {
        return result(.notFound, "The destination folder does not exist. Sync its creation first or choose another folder.")
      }
      try toolsExecuteUnlocked("INSERT INTO notes(id, folder_id, title, content, snippet, position, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 0, ?, ?)",
        [request.resourceID, request.folderID, title, content, Self.noteSnippet(content), now, now])
      try checkpointNoteUnlocked(id: request.resourceID, source: "device", force: true)
      return try result(.accepted, note: libraryNoteUnlocked(id: request.resourceID))
    case .updateNote, .deleteNote:
      guard let note = try libraryNoteUnlocked(id: request.resourceID) else {
        return result(.notFound, "The note was deleted. Your local writing is retained; saving a recovery copy requires a new ID.")
      }
      guard request.expectedRevision == note.revision else { return result(.conflict, "The note changed on another device or agent. Both versions are retained.", note: note) }
      if request.kind == .deleteNote {
        try checkpointNoteUnlocked(id: request.resourceID, source: "before-device-delete", force: true)
        try toolsExecuteUnlocked("UPDATE notes SET deleted_at = ?, updated_at = ? WHERE id = ?", [now, now, request.resourceID])
        return result(.accepted)
      }
      guard let title = request.title, let content = request.content else { return result(.invalid, "The note needs a title and a document.") }
      if content != note.content {
        do {
          let previous = try NoteDocument.editableDocument(from: note.content)
          let replacement = try NoteDocument.editableDocument(from: content)
          guard previous.kind == replacement.kind, libraryEditableArtifact(previous), libraryEditableArtifact(replacement) else {
            return result(.invalid, "Preserve the document kind; linked database content is read-only on clients.")
          }
        } catch { return result(.invalid, error.localizedDescription, note: note) }
      }
      if let folderID = request.folderID, try libraryFolderUnlocked(id: folderID) == nil {
        return result(.notFound, "The destination folder was deleted. Your writing is retained.", note: note)
      }
      try checkpointNoteUnlocked(id: request.resourceID, source: "before-device-edit", force: true)
      let updatedAt = try nextNoteUpdatedAtUnlocked(id: request.resourceID)
      try toolsExecuteUnlocked("UPDATE notes SET title = ?, content = ?, snippet = ?, folder_id = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL", [title, content, Self.noteSnippet(content), request.folderID, updatedAt, request.resourceID])
      try checkpointNoteUnlocked(id: request.resourceID, source: "device", force: true)
      return try result(.accepted, note: libraryNoteUnlocked(id: request.resourceID))
    }
  }

  private func libraryEditableArtifact(_ document: NoteDocument) -> Bool {
    document.databaseLink == nil && document.blocks.allSatisfy { block in
      if case .table(let table) = block { return table.databaseLink == nil }
      return true
    }
  }

  func libraryFingerprint<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return Data(SHA256.hash(data: try encoder.encode(value)))
  }

  public func reserveLibraryCommand(_ request: LibraryCommand) throws -> LibraryCommandReservation {
    try transaction {
      let fingerprint = try libraryFingerprint(request)
      let lookup = try prepareUnlocked("SELECT request, response FROM device_command_receipts WHERE device_id = ? AND command_id = ?")
      defer { sqlite3_finalize(lookup) }
      try bind(request.deviceID, at: 1, to: lookup); try bind(request.commandID, at: 2, to: lookup)
      let code = sqlite3_step(lookup)
      if code == SQLITE_ROW {
        guard try blob(lookup, column: 0) == fingerprint else {
          return LibraryCommandReservation(receipt: LibraryCommandReceipt(commandID: request.commandID, deviceID: request.deviceID, status: .rejected, message: "This command ID was already used for another request."), isNew: false)
        }
        var receipt = try JSONDecoder().decode(LibraryCommandReceipt.self, from: blob(lookup, column: 1))
        if receipt.status == .accepted {
          receipt.status = .outcomeUnknown
          receipt.message = "The Mac durably accepted this command. Check its conversation before sending anything new; retrying this ID never starts a second run."
        }
        return LibraryCommandReservation(receipt: receipt, isNew: false)
      }
      guard code == SQLITE_DONE else { throw stepError() }
      guard UUID(uuidString: request.commandID) != nil, UUID(uuidString: request.deviceID) != nil else {
        return LibraryCommandReservation(receipt: LibraryCommandReceipt(commandID: request.commandID, deviceID: request.deviceID, status: .rejected, message: "Commands require UUID identities."), isNew: false)
      }
      let receipt = LibraryCommandReceipt(commandID: request.commandID, deviceID: request.deviceID, status: .accepted, conversationID: request.conversationID, runID: request.runID)
      let insert = try prepareUnlocked("INSERT INTO device_command_receipts(device_id, command_id, request, response) VALUES (?, ?, ?, ?)")
      defer { sqlite3_finalize(insert) }
      try bind(request.deviceID, at: 1, to: insert); try bind(request.commandID, at: 2, to: insert)
      try bind(fingerprint, at: 3, to: insert); try bind(JSONEncoder().encode(receipt), at: 4, to: insert)
      try stepDone(insert)
      return LibraryCommandReservation(receipt: receipt, isNew: true)
    }
  }

  public func finishLibraryCommand(_ receipt: LibraryCommandReceipt) throws {
    try transaction {
      let update = try prepareUnlocked("UPDATE device_command_receipts SET response = ? WHERE device_id = ? AND command_id = ?")
      defer { sqlite3_finalize(update) }
      try bind(JSONEncoder().encode(receipt), at: 1, to: update)
      try bind(receipt.deviceID, at: 2, to: update); try bind(receipt.commandID, at: 3, to: update)
      try stepDone(update)
      guard changedRowCountUnlocked == 1 else { throw WorkspaceDatabaseError.execute("No reserved command exists.") }
    }
  }

  public func libraryCommandReceipt(deviceID: String, commandID: String) throws -> LibraryCommandReceipt? {
    try withLock {
      let statement = try prepareUnlocked("SELECT response FROM device_command_receipts WHERE device_id = ? AND command_id = ?")
      defer { sqlite3_finalize(statement) }
      try bind(deviceID, at: 1, to: statement); try bind(commandID, at: 2, to: statement)
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return nil }
      guard code == SQLITE_ROW else { throw stepError() }
      return try JSONDecoder().decode(LibraryCommandReceipt.self, from: blob(statement, column: 0))
    }
  }
}

extension WorkspaceDatabase {
  public func applyLibraryMutation(_ request: LibraryMutation) async throws -> LibraryMutationResult {
    try await write { try $0.applyLibraryMutation(request) }
  }
  public func reserveLibraryCommand(_ request: LibraryCommand) async throws -> LibraryCommandReservation {
    try await write { try $0.reserveLibraryCommand(request) }
  }
  public func finishLibraryCommand(_ receipt: LibraryCommandReceipt) async throws {
    try await finishWrite { try $0.finishLibraryCommand(receipt) }
  }
  public func libraryCommandReceipt(deviceID: String, commandID: String) async throws -> LibraryCommandReceipt? {
    try await read { try $0.libraryCommandReceipt(deviceID: deviceID, commandID: commandID) }
  }
}
