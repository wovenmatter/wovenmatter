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

public struct ExecutionWorkspaceMCPPrincipal: Sendable {
  public let grantID: String
  public let libraryID: String
  public let workspaceID: String
  /// The Linux member that executes the workspace (its signed requests).
  public let executionDeviceID: String
}

public struct ScheduledMCPPreparation: Codable, Sendable {
  public let run: WorkspaceCalendarRun
  public let eventRevision: Int
  public let nativeSessionID: String?
}

extension WorkspaceDatabaseConnection {
  /// The execution owner registers a claimed scheduled caller before prompting
  /// its native harness. This projects identity and policy; it starts no work
  /// and does not manufacture a terminal result or a second federation owner.
  public func prepareLibraryScheduledMCP(_ preparation: ScheduledMCPPreparation,
      principal: ExecutionWorkspaceMCPPrincipal) throws -> [WorkspaceToolGroup] {
    try transaction {
      let incoming = preparation.run
      guard federationID(incoming.id), federationID(incoming.sessionID),
            let workspaceUUID = UUID(uuidString: principal.workspaceID),
            let deviceUUID = UUID(uuidString: principal.executionDeviceID),
            incoming.occurrenceIndex >= 0,
            incoming.scheduledAt <= Date().addingTimeInterval(60),
            (preparation.nativeSessionID?.utf8.count ?? 0) <= 4_096,
            preparation.nativeSessionID?.isEmpty != true,
            let workspace = try federationWorkspaceUnlocked(principal.workspaceID), !workspace.deleted,
            workspace.executionDeviceID == principal.executionDeviceID,
            try workspaceMCPPrincipalCurrentUnlocked(principal),
            try libraryIDsUnlocked("SELECT workspace_id FROM workspace_calendar_remote_ownership WHERE workspace_id=? AND state='remote'",
              bindings: [principal.workspaceID]).isEmpty == false,
            let event = try calendarItemsUnlocked().first(where: { $0.id == incoming.eventID }),
            event.calendar.revision == preparation.eventRevision,
            var task = event.calendar.task, task.configuration.workspaceID == workspaceUUID,
            let occurrence = WorkspaceCalendarSchedule.occurrence(event, index: incoming.occurrenceIndex),
            abs(occurrence.startsAt.timeIntervalSince(incoming.scheduledAt)) < 0.001 else {
        throw federationError("wrong_owner", "This run does not match a current schedule assigned to the execution workspace.")
      }
      let scheduledAt = Self.timestamp(incoming.scheduledAt)
      let federationOwners = try libraryIDsUnlocked("SELECT workspace_id FROM execution_conversations WHERE id=?", bindings: [incoming.sessionID])
      guard federationOwners.isEmpty || federationOwners == [principal.workspaceID] else {
        throw federationError("wrong_owner", "The scheduled caller UUID is already owned by another execution workspace.")
      }
      let existing = try historyRowsUnlocked("SELECT run_id,conversation_id,workspace_id,native_session_id FROM device_scheduled_mcp_callers WHERE run_id=? OR (event_id=? AND scheduled_at=?)",
        values: [incoming.id, incoming.eventID, scheduledAt]).first?.objectValue
      if let existing {
        guard existing["run_id"]?.stringValue == incoming.id,
              existing["conversation_id"]?.stringValue == incoming.sessionID,
              existing["workspace_id"]?.stringValue == principal.workspaceID,
              existing["native_session_id"]?.stringValue.map({ preparation.nativeSessionID == nil || preparation.nativeSessionID == $0 }) ?? true else {
          throw federationError("receipt_conflict", "This scheduled occurrence already belongs to a different run or native session.")
        }
      }
      // The remote scheduler may choose one child directory for a scratch run;
      // it may not change folder, harness, permissions, tools or project root.
      if incoming.task.configuration.nativeWorkingDirectory != task.configuration.nativeWorkingDirectory {
        guard task.configuration.folderID == nil, let root = task.configuration.nativeWorkingDirectory,
              let path = incoming.task.configuration.nativeWorkingDirectory,
              path == URL(fileURLWithPath: path).standardizedFileURL.path,
              URL(fileURLWithPath: path).deletingLastPathComponent().path == URL(fileURLWithPath: root).appending(path: "scratch").path else {
          throw federationError("wrong_owner", "The scheduled execution directory differs from the saved workspace root.")
        }
        task.configuration.nativeWorkingDirectory = incoming.task.configuration.nativeWorkingDirectory
      }
      guard task == incoming.task else {
        throw federationError("wrong_owner", "The scheduled run cannot change its saved harness, permissions or tools.")
      }
      var run = incoming; run.task = task; run.title = event.title; run.status = "sending"; run.error = nil
      try importRemoteCalendarRunUnlocked(run, workspaceID: workspaceUUID, eventRevision: preparation.eventRevision)
      try importRemoteCalendarTranscriptUnlocked(receiptID: incoming.id, run: run, workspaceID: workspaceUUID,
        workspaceName: workspace.name, ownerDeviceID: deviceUUID, nativeSessionID: preparation.nativeSessionID,
        updates: [], error: nil, completedAt: incoming.scheduledAt, complete: false)
      let insert = try prepareUnlocked("INSERT INTO device_scheduled_mcp_callers(run_id,conversation_id,workspace_id,event_id,scheduled_at,native_session_id) VALUES (?,?,?,?,?,?) ON CONFLICT(run_id) DO UPDATE SET native_session_id=coalesce(device_scheduled_mcp_callers.native_session_id,excluded.native_session_id)")
      defer { sqlite3_finalize(insert) }
      try bind(run.id, at: 1, to: insert); try bind(run.sessionID, at: 2, to: insert)
      try bind(principal.workspaceID, at: 3, to: insert); try bind(run.eventID, at: 4, to: insert)
      try bind(scheduledAt, at: 5, to: insert); try bindNullable(preparation.nativeSessionID, at: 6, to: insert); try stepDone(insert)
      return Array(try sessionTools(run.sessionID).enabled.intersection(task.configuration.tools.enabled)).sorted { $0.rawValue < $1.rawValue }
    }
  }

  /// A member principal was just verified by signature against the current member list.
  func workspaceMCPPrincipalCurrentUnlocked(_ principal: ExecutionWorkspaceMCPPrincipal) throws -> Bool {
    principal.grantID == "member:" + principal.executionDeviceID
  }

  /// The principal for a signed request from a Linux member: allowed only for
  /// the non-deleted Linux execution workspace that member executes. `serving`
  /// is the member that serves the workspace's endpoint (`MemberAudience`),
  /// since a workspace a host registered with a random ID before v0.4.0 names its
  /// Node server's own execution device ID.
  public func executionWorkspaceMCPMember(workspaceID: String, deviceID: String, serving: String? = nil) throws -> ExecutionWorkspaceMCPPrincipal {
    try withLock {
      guard let workspace = try federationWorkspaceUnlocked(workspaceID), !workspace.deleted, workspace.kind == .linux,
            let executor = workspace.executionDeviceID,
            executor == deviceID.lowercased() || serving?.lowercased() == deviceID.lowercased() else {
        throw federationError("wrong_owner", "This member does not execute that Linux workspace.")
      }
      return .init(grantID: "member:" + executor, libraryID: workspace.libraryID, workspaceID: workspace.id,
                   executionDeviceID: executor)
    }
  }

  public func authorizeExecutionWorkspaceMCPCaller(conversationID: String, principal: ExecutionWorkspaceMCPPrincipal) throws {
    try withLock {
      let owners = try libraryIDsUnlocked("SELECT workspace_id FROM execution_conversations WHERE id=? AND deleted=0 UNION SELECT workspace_id FROM device_scheduled_mcp_callers WHERE conversation_id=?", bindings: [conversationID, conversationID])
      guard federationID(conversationID), owners.count == 1, let owner = owners.first,
            owner == principal.workspaceID,
            let workspace = try federationWorkspaceUnlocked(owner), !workspace.deleted,
            workspace.libraryID == principal.libraryID, workspace.kind == .linux,
            workspace.executionDeviceID == principal.executionDeviceID,
            try workspaceMCPPrincipalCurrentUnlocked(principal) else {
        throw federationError("wrong_owner", "A Linux member may act only for its execution workspace's conversations.")
      }
    }
  }
}

extension WorkspaceDatabase {
  public func prepareLibraryScheduledMCP(_ preparation: ScheduledMCPPreparation,
      principal: ExecutionWorkspaceMCPPrincipal) async throws -> [WorkspaceToolGroup] {
    try await write { try $0.prepareLibraryScheduledMCP(preparation, principal: principal) }
  }
  public func executionWorkspaceMCPMember(workspaceID: String, deviceID: String, serving: String? = nil) async throws -> ExecutionWorkspaceMCPPrincipal {
    try await read { try $0.executionWorkspaceMCPMember(workspaceID: workspaceID, deviceID: deviceID, serving: serving) }
  }
  public func authorizeExecutionWorkspaceMCPCaller(conversationID: String, principal: ExecutionWorkspaceMCPPrincipal) async throws {
    try await read { try $0.authorizeExecutionWorkspaceMCPCaller(conversationID: conversationID, principal: principal) }
  }
}
