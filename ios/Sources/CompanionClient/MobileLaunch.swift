import Foundation
import WovenMatterCompanion

public struct MobileChatDraft: Codable, Equatable, Sendable {
  public var text: String
  public var noteID: String?
  public var providerID: String?
  public init(text: String, noteID: String? = nil, providerID: String? = nil) { self.text = text; self.noteID = noteID; self.providerID = providerID }
}
public struct MobileLaunchRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: String { create.commandID }
  public var create: CompanionCommand
  public var initialSend: CompanionCommand
  public var createReceipt: CompanionCommandReceipt?
  public var sendReceipt: CompanionCommandReceipt?
  public var sendPrepared = false
  public init(create: CompanionCommand, initialSend: CompanionCommand) { self.create = create; self.initialSend = initialSend }
  public var terminalFailure: Bool { createReceipt?.status == .rejected || sendReceipt?.status == .rejected }
  public var accepted: Bool { sendReceipt?.status == .completed || sendReceipt?.status == .accepted }
}

extension MobileSyncEngine {
  /// Two explicit durable commands: create the canonical session, then send the
  /// first prompt. Both stable IDs and the complete prompt exist on disk before
  /// any request. Recovery only reads receipts; executing an unsent continuation
  /// requires the user to press Continue while online.
  public func startConversation(_ requested: MobileLaunchRecord) async throws -> MobileLaunchRecord {
    if let task = launchTasks[requested.id] { return try await task.value }
    let task = Task { try await self.performLaunch(requested) }
    launchTasks[requested.id] = task
    defer { launchTasks.removeValue(forKey: requested.id) }
    return try await task.value
  }
  private func performLaunch(_ requested: MobileLaunchRecord) async throws -> MobileLaunchRecord {
    try await store.rememberLaunchIfMissing(requested)
    var launch = await store.snapshot().launches.first { $0.id == requested.id } ?? requested
    try await verifyRemoteWorkspace()
    try await synchronize()
    if launch.createReceipt?.status != .completed {
      let existing = try await readReceipt(launch.create.commandID)
      let receipt: CompanionCommandReceipt
      if let existing { receipt = existing } else { receipt = try await sendCommand(launch.create) }
      launch = try await store.rememberLaunchReceipt(receipt, launchID: launch.id) ?? launch
      guard receipt.status == .completed else { return launch }
    }
    if launch.accepted { return launch }
    if !launch.sendPrepared {
      let revision: Int64?
      if let id = launch.initialSend.noteID {
        try await synchronize()
        revision = try await store.canonicalNote(id: id).revision
      } else { revision = nil }
      launch = try await store.prepareLaunchSend(id: launch.id, noteRevision: revision) ?? launch
    }
    let existing = try await readReceipt(launch.initialSend.commandID)
    let receipt: CompanionCommandReceipt
    if let existing { receipt = existing } else { receipt = try await sendCommand(launch.initialSend) }
    launch = try await store.rememberLaunchReceipt(receipt, launchID: launch.id) ?? launch
    return launch
  }
}
