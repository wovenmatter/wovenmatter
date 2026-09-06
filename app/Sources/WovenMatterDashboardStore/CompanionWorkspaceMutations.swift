import CryptoKit
import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabase {
  public func applyCompanionMutation(_ request: CompanionMutation) throws -> CompanionMutationResult {
    try transaction {
      let fingerprint = try companionFingerprint(request)
      let lookup = try prepareUnlocked("SELECT request, response FROM companion_mutation_receipts WHERE device_id = ? AND operation_id = ?")
      defer { sqlite3_finalize(lookup) }
      try bind(request.deviceID, at: 1, to: lookup); try bind(request.operationID, at: 2, to: lookup)
      let code = sqlite3_step(lookup)
      if code == SQLITE_ROW {
        guard try blob(lookup, column: 0) == fingerprint else {
          return CompanionMutationResult(operationID: request.operationID, status: .invalid, message: "This operation ID was already used for different content.")
        }
        return try JSONDecoder().decode(CompanionMutationResult.self, from: blob(lookup, column: 1))
      }
      guard code == SQLITE_DONE else { throw stepError() }
      var result = try performCompanionMutationUnlocked(request)
      // A permanent receipt records the original acceptance/revision without
      // retaining a new multi-megabyte document for every acknowledged edit.
      // The caller already owns an accepted local body; conflict bodies are
      // fetched explicitly from the canonical note endpoint.
      if var note = result.note {
        note.content = ""; note.contentIncluded = false; result.note = note
      }
      let receipt = try prepareUnlocked("INSERT INTO companion_mutation_receipts(device_id, operation_id, request, response) VALUES (?, ?, ?, ?)")
      defer { sqlite3_finalize(receipt) }
      try bind(request.deviceID, at: 1, to: receipt); try bind(request.operationID, at: 2, to: receipt)
      try bind(fingerprint, at: 3, to: receipt); try bind(JSONEncoder().encode(result), at: 4, to: receipt)
      try stepDone(receipt)
      return result
    }
  }

  private func performCompanionMutationUnlocked(_ request: CompanionMutation) throws -> CompanionMutationResult {
    func result(_ status: CompanionMutationResult.Status, _ message: String? = nil,
                note: CompanionNote? = nil, folder: CompanionFolder? = nil) -> CompanionMutationResult {
      CompanionMutationResult(operationID: request.operationID, status: status, folder: folder, note: note, message: message)
    }
    guard UUID(uuidString: request.operationID) != nil, UUID(uuidString: request.deviceID) != nil,
          let resourceID = UUID(uuidString: request.resourceID), resourceID.uuidString.lowercased() == request.resourceID,
          request.folderID.map({ UUID(uuidString: $0) != nil }) ?? true,
          (request.title?.utf8.count ?? 0) <= 4_096 else {
      return result(.invalid, "Use stable UUID identities and a title shorter than 4 KiB.")
    }
    let operatorID = try localMutationOperatorIDUnlocked()
    let now = Self.timestamp(Date())
    switch request.kind {
    case .createFolder:
      guard let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return result(.invalid, "Enter a folder name.") }
      if try companionVersionUnlocked(kind: "folder", id: request.resourceID) != nil {
        return try result(.conflict, "This folder ID already exists or was deleted.", folder: companionFolderUnlocked(id: request.resourceID))
      }
      try companionExecuteUnlocked("INSERT INTO folders(id, user_id, name, position, created_at, updated_at) VALUES (?, ?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM folders), ?, ?)", values: [request.resourceID, operatorID, title, now, now])
      return try result(.accepted, folder: companionFolderUnlocked(id: request.resourceID))
    case .renameFolder, .deleteFolder:
      guard let folder = try companionFolderUnlocked(id: request.resourceID) else { return result(.notFound, "The folder was deleted. Your writing is retained on this device.") }
      guard request.expectedRevision == folder.revision else { return result(.conflict, "The folder changed since it was read.", folder: folder) }
      if request.kind == .deleteFolder {
        try companionExecuteUnlocked("DELETE FROM folders WHERE id = ? AND user_id = ?", values: [request.resourceID, operatorID])
        return result(.accepted)
      }
      guard let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return result(.invalid, "Enter a folder name.") }
      try companionExecuteUnlocked("UPDATE folders SET name = ?, updated_at = ? WHERE id = ? AND user_id = ?", values: [title, now, request.resourceID, operatorID])
      return try result(.accepted, folder: companionFolderUnlocked(id: request.resourceID))
    case .createNote:
      if try companionVersionUnlocked(kind: "note", id: request.resourceID) != nil {
        return try result(.conflict, "This note ID already exists or was deleted.", note: companionNoteUnlocked(id: request.resourceID))
      }
      guard let title = request.title, let content = request.content else { return result(.invalid, "The note needs a title and a document.") }
      do {
        let document = try NoteDocument.editableDocument(from: content)
        guard document.kind == .note else { return result(.invalid, "Only ordinary notes support companion edits.") }
      } catch { return result(.invalid, error.localizedDescription) }
      if let folderID = request.folderID, try companionFolderUnlocked(id: folderID) == nil {
        return result(.notFound, "The destination folder does not exist. Sync its creation first or choose another folder.")
      }
      try companionExecuteUnlocked("INSERT INTO notes(id, user_id, folder_id, title, content, snippet, position, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)",
        values: [request.resourceID, operatorID, request.folderID, title, content, Self.noteSnippet(content), now, now])
      return try result(.accepted, note: companionNoteUnlocked(id: request.resourceID))
    case .updateNote, .deleteNote:
      guard let note = try companionNoteUnlocked(id: request.resourceID) else {
        return result(.notFound, "The note was deleted. Your local writing is retained; saving a recovery copy requires a new ID.")
      }
      guard request.expectedRevision == note.revision else { return result(.conflict, "The note changed on another device or agent. Both versions are retained.", note: note) }
      if request.kind == .deleteNote {
        try companionExecuteUnlocked("UPDATE notes SET deleted_at = ?, updated_at = ? WHERE id = ? AND user_id = ?", values: [now, now, request.resourceID, operatorID])
        return result(.accepted)
      }
      guard let title = request.title, let content = request.content else { return result(.invalid, "The note needs a title and a document.") }
      if content != note.content {
        do {
          guard try NoteDocument.editableDocument(from: note.content).kind == .note,
                try NoteDocument.editableDocument(from: content).kind == .note else {
            return result(.invalid, "Only ordinary notes support companion edits.")
          }
        } catch { return result(.invalid, error.localizedDescription, note: note) }
      }
      if let folderID = request.folderID, try companionFolderUnlocked(id: folderID) == nil {
        return result(.notFound, "The destination folder was deleted. Your writing is retained.", note: note)
      }
      try companionExecuteUnlocked("UPDATE notes SET title = ?, content = ?, snippet = ?, folder_id = ?, updated_at = ? WHERE id = ? AND user_id = ? AND deleted_at IS NULL", values: [title, content, Self.noteSnippet(content), request.folderID, now, request.resourceID, operatorID])
      return try result(.accepted, note: companionNoteUnlocked(id: request.resourceID))
    }
  }

  func companionExecuteUnlocked(_ sql: String, values: [String?]) throws {
    let statement = try prepareUnlocked(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() { try bindNullable(value, at: Int32(offset + 1), to: statement) }
    try stepDone(statement)
  }

  func companionFingerprint<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return Data(SHA256.hash(data: try encoder.encode(value)))
  }

  public func reserveCompanionCommand(_ request: CompanionCommand) throws -> CompanionCommandReservation {
    try transaction {
      let fingerprint = try companionFingerprint(request)
      let lookup = try prepareUnlocked("SELECT request, response FROM companion_command_receipts WHERE device_id = ? AND command_id = ?")
      defer { sqlite3_finalize(lookup) }
      try bind(request.deviceID, at: 1, to: lookup); try bind(request.commandID, at: 2, to: lookup)
      let code = sqlite3_step(lookup)
      if code == SQLITE_ROW {
        guard try blob(lookup, column: 0) == fingerprint else {
          return CompanionCommandReservation(receipt: CompanionCommandReceipt(commandID: request.commandID, deviceID: request.deviceID, status: .rejected, message: "This command ID was already used for another request."), isNew: false)
        }
        var receipt = try JSONDecoder().decode(CompanionCommandReceipt.self, from: blob(lookup, column: 1))
        if receipt.status == .accepted {
          receipt.status = .outcomeUnknown
          receipt.message = "The Mac durably accepted this command. Check its conversation before sending anything new; retrying this ID never starts a second run."
        }
        return CompanionCommandReservation(receipt: receipt, isNew: false)
      }
      guard code == SQLITE_DONE else { throw stepError() }
      guard UUID(uuidString: request.commandID) != nil, UUID(uuidString: request.deviceID) != nil else {
        return CompanionCommandReservation(receipt: CompanionCommandReceipt(commandID: request.commandID, deviceID: request.deviceID, status: .rejected, message: "Commands require UUID identities."), isNew: false)
      }
      let receipt = CompanionCommandReceipt(commandID: request.commandID, deviceID: request.deviceID, status: .accepted, conversationID: request.conversationID, runID: request.runID)
      let insert = try prepareUnlocked("INSERT INTO companion_command_receipts(device_id, command_id, request, response) VALUES (?, ?, ?, ?)")
      defer { sqlite3_finalize(insert) }
      try bind(request.deviceID, at: 1, to: insert); try bind(request.commandID, at: 2, to: insert)
      try bind(fingerprint, at: 3, to: insert); try bind(JSONEncoder().encode(receipt), at: 4, to: insert)
      try stepDone(insert)
      return CompanionCommandReservation(receipt: receipt, isNew: true)
    }
  }

  public func finishCompanionCommand(_ receipt: CompanionCommandReceipt) throws {
    try transaction {
      let update = try prepareUnlocked("UPDATE companion_command_receipts SET response = ? WHERE device_id = ? AND command_id = ?")
      defer { sqlite3_finalize(update) }
      try bind(JSONEncoder().encode(receipt), at: 1, to: update)
      try bind(receipt.deviceID, at: 2, to: update); try bind(receipt.commandID, at: 3, to: update)
      try stepDone(update)
      guard sqlite3_changes(connection) == 1 else { throw WorkspaceDatabaseError.execute("No reserved command exists.") }
    }
  }

  public func companionCommandReceipt(deviceID: String, commandID: String) throws -> CompanionCommandReceipt? {
    try lock.withLock {
      let statement = try prepareUnlocked("SELECT response FROM companion_command_receipts WHERE device_id = ? AND command_id = ?")
      defer { sqlite3_finalize(statement) }
      try bind(deviceID, at: 1, to: statement); try bind(commandID, at: 2, to: statement)
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return nil }
      guard code == SQLITE_ROW else { throw stepError() }
      return try JSONDecoder().decode(CompanionCommandReceipt.self, from: blob(statement, column: 0))
    }
  }
}
