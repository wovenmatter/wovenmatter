import Foundation
import SQLite3
import WovenMatterCore

public struct CompanionToolReservation: Sendable {
  public var isNew: Bool
  public var response: WovenMatterToolResponse?
}

extension WorkspaceDatabaseConnection {
  func createCompanionToolSchemaUnlocked() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS companion_tool_receipts (
        device_id TEXT NOT NULL, request_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
        fingerprint BLOB NOT NULL, response BLOB, PRIMARY KEY(device_id,request_id)
      );
      """)
  }

  /// An imported session is a valid tool caller, but a device may never claim a
  /// Mac-local session, another device's session, or a workspace it merely relays.
  public func authorizeCompanionTool(_ value: CompanionToolRequest, deviceID: String) throws {
    try withLock { try authorizeCompanionToolUnlocked(value, deviceID: deviceID) }
  }

  private func authorizeCompanionToolUnlocked(_ value: CompanionToolRequest, deviceID: String) throws {
    let command = try WovenMatterToolCommand(value.request.arguments)
    let maximumBytes = command.group?.isAutomation == true ? 4 * 1_024 * 1_024 : WovenMatterToolResponse.maximumResponseBytes
    guard UUID(uuidString: deviceID) != nil, UUID(uuidString: value.conversationID) != nil,
          value.request.schemaVersion == 1, UUID(uuidString: value.request.requestID) != nil,
          try JSONEncoder().encode(value).count <= maximumBytes,
          command.group?.isAutomation != true || (command.options["json"]?.utf8.count ?? 0) <= 3 * 1_024 * 1_024 else {
      throw CompanionAPIError(code: "invalid_request", message: "Tool calls require bounded requests and stable UUID identities.")
    }
    let owners = try companionIDsUnlocked("""
      SELECT f.workspace_id FROM companion_execution_conversations f
      JOIN dashboard_conversations c ON c.id=f.id
      WHERE f.id=? AND f.deleted=0 AND c.deleted_at IS NULL AND c.is_archived=0
      """, bindings: [value.conversationID])
    guard let workspaceID = owners.first, let workspace = try federationWorkspaceUnlocked(workspaceID),
          !workspace.deleted, workspace.kind == .ios || workspace.kind == .mac,
          workspace.ownerDeviceID == deviceID, (workspace.executionDeviceID ?? workspace.ownerDeviceID) == deviceID else {
      throw CompanionAPIError(code: "wrong_owner", message: "Sync this device's conversation before using the central library tools.")
    }
    if let supplied = command.options["request-id"] {
      guard UUID(uuidString: supplied) == UUID(uuidString: value.request.requestID) else {
        throw CompanionAPIError(code: "invalid_request", message: "--request-id must match the request envelope.")
      }
    }
    if !command.wantsHelp, command.action != "context", let group = command.group {
      // Cleanup retains device/caller ownership, including after revocation.
      if group.isAutomation, command.action == "cancel" { return }
      guard value.enabledGroups.contains(group) else { throw WorkspaceToolError.disabled(group) }
      // History retains the desktop's independent attachment/management checks.
      // All other groups require the persisted central session policy as well.
      if group != .history { try requireToolUnlocked(group, sessionID: value.conversationID) }
    }
  }

  /// Recheck the existing device execution policy between native input steps.
  /// Caller ownership is derived from the journal, never automation arguments.
  public func requireCompanionAutomationAccess(callerID: String) throws {
    try withLock {
      guard let id = try companionIDsUnlocked("SELECT workspace_id FROM companion_execution_conversations WHERE id=?", bindings: [callerID]).first else { return }
      guard let owner = try federationWorkspaceUnlocked(id), !owner.deleted else {
        throw CompanionAPIError(code: "wrong_owner", message: "The automation caller's execution workspace is unavailable.")
      }
      let identity = try companionLibraryIdentityUnlocked()
      let workspaces = try federationValuesUnlocked("SELECT payload FROM companion_execution_workspaces ORDER BY id", as: CompanionExecutionWorkspace.self)
      guard let host = workspaces.first(where: { $0.kind == .mac && !$0.deleted && ($0.executionDeviceID ?? $0.ownerDeviceID) == identity.hostDeviceID }) else { return }
      let denied = try companionIDsUnlocked("SELECT workspace_id FROM companion_workspace_access WHERE device_id=? AND workspace_id=? AND enabled=0", bindings: [owner.executionDeviceID ?? owner.ownerDeviceID, host.id])
      guard denied.isEmpty else {
        throw CompanionAPIError(code: "execution_disabled", message: "Execution access for this Mac is disabled in Device Connections.")
      }
    }
  }

  public func reserveCompanionTool(_ value: CompanionToolRequest, deviceID: String) throws -> CompanionToolReservation {
    try transaction {
      try authorizeCompanionToolUnlocked(value, deviceID: deviceID)
      let id = UUID(uuidString: value.request.requestID)!.uuidString.lowercased()
      var normalized = value
      normalized.request.requestID = id
      normalized.request.arguments = value.request.operationArguments
      normalized.enabledGroups = Array(Set(value.enabledGroups)).sorted { $0.rawValue < $1.rawValue }
      let fingerprint = try companionFingerprint(normalized)
      let lookup = try prepareUnlocked("SELECT fingerprint,response FROM companion_tool_receipts WHERE device_id=? AND request_id=?")
      defer { sqlite3_finalize(lookup) }
      try bind(deviceID, at: 1, to: lookup); try bind(id, at: 2, to: lookup)
      let status = sqlite3_step(lookup)
      if status == SQLITE_ROW {
        guard try blob(lookup, column: 0) == fingerprint else {
          throw CompanionAPIError(code: "receipt_conflict", message: "This tool request ID was already used for different content.")
        }
        let response = sqlite3_column_type(lookup, 1) == SQLITE_NULL ? nil
          : try JSONDecoder().decode(WovenMatterToolResponse.self, from: blob(lookup, column: 1))
        return CompanionToolReservation(isNew: false, response: response)
      }
      guard status == SQLITE_DONE else { throw stepError() }
      let insert = try prepareUnlocked("INSERT INTO companion_tool_receipts(device_id,request_id,conversation_id,fingerprint) VALUES (?,?,?,?)")
      defer { sqlite3_finalize(insert) }
      try bind(deviceID, at: 1, to: insert); try bind(id, at: 2, to: insert)
      try bind(value.conversationID, at: 3, to: insert); try bind(fingerprint, at: 4, to: insert)
      try stepDone(insert)
      return CompanionToolReservation(isNew: true, response: nil)
    }
  }

  public func finishCompanionTool(_ response: WovenMatterToolResponse, requestID: String, deviceID: String) throws {
    try transaction {
      let update = try prepareUnlocked("UPDATE companion_tool_receipts SET response=? WHERE device_id=? AND request_id=? AND response IS NULL")
      defer { sqlite3_finalize(update) }
      try bind(JSONEncoder().encode(response.bounded()), at: 1, to: update)
      try bind(deviceID, at: 2, to: update)
      try bind(UUID(uuidString: requestID)?.uuidString.lowercased() ?? requestID, at: 3, to: update)
      try stepDone(update)
      guard changedRowCountUnlocked == 1 else { throw WorkspaceDatabaseError.execute("No pending tool receipt exists.") }
    }
  }
}

extension WorkspaceDatabase {
  public func requireCompanionAutomationAccess(callerID: String) async throws {
    try await read { try $0.requireCompanionAutomationAccess(callerID: callerID) }
  }
  public func authorizeCompanionTool(_ value: CompanionToolRequest, deviceID: String) async throws {
    try await read { try $0.authorizeCompanionTool(value, deviceID: deviceID) }
  }
  public func reserveCompanionTool(_ value: CompanionToolRequest, deviceID: String) async throws -> CompanionToolReservation {
    try await write { try $0.reserveCompanionTool(value, deviceID: deviceID) }
  }
  public func finishCompanionTool(_ response: WovenMatterToolResponse, requestID: String, deviceID: String) async throws {
    try await finishWrite { try $0.finishCompanionTool(response, requestID: requestID, deviceID: deviceID) }
  }
}
