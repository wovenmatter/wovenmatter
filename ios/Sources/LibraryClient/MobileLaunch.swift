import Foundation
import WovenMatterShared

public struct MobileChatDraft: Codable, Equatable, Sendable {
  public var text: String
  public var noteID: String?
  public var providerID: String?
  public init(text: String, noteID: String? = nil, providerID: String? = nil) { self.text = text; self.noteID = noteID; self.providerID = providerID }
}
public struct MobileLaunchRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: String { create.commandID }
  public var create: LibraryCommand
  public var initialSend: LibraryCommand
  public var createReceipt: LibraryCommandReceipt?
  public var sendReceipt: LibraryCommandReceipt?
  public var sendPrepared = false
  public init(create: LibraryCommand, initialSend: LibraryCommand) { self.create = create; self.initialSend = initialSend }
  public var terminalFailure: Bool { createReceipt?.status == .rejected || sendReceipt?.status == .rejected }
  public var accepted: Bool { sendReceipt?.status == .completed || sendReceipt?.status == .accepted }
  /// An unconfirmed launch is retried, with its original IDs, only for the same
  /// request. Different input starts a separate launch: the earlier one stays saved
  /// and reconciles from its receipts, so it is neither discarded nor blocking.
  public static func reusable(_ launches: [MobileLaunchRecord], workspaceID: String?, providerID: String?,
                              text: String?, noteID: String?) -> MobileLaunchRecord? {
    launches.first { launch in
      launch.create.workspaceID == workspaceID && !launch.accepted && !launch.terminalFailure
        && launch.create.providerID == providerID && launch.initialSend.text == text && launch.initialSend.noteID == noteID
    }
  }
}

extension MobileSyncEngine {
  /// Two explicit durable commands: create the canonical session, then send the
  /// first prompt. Both stable IDs and the complete prompt exist on disk before
  /// any request. Recovery only reads receipts; executing an unsent continuation
  /// requires the user to press Continue while online.
  public func startConversation(_ requested: MobileLaunchRecord) async throws -> MobileLaunchRecord {
    guard requested.create.workspaceID == nil, requested.initialSend.workspaceID == nil else { throw MobileStore.Failure.wrongWorkspace }
    if let task = launchTasks[requested.id] { return try await task.value }
    let task = Task { try await self.performLaunch(requested) }
    launchTasks[requested.id] = task
    defer { launchTasks.removeValue(forKey: requested.id) }
    return try await task.value
  }
  private func performLaunch(_ requested: MobileLaunchRecord) async throws -> MobileLaunchRecord {
    let alreadySaved = await store.snapshot().launches.contains { $0.id == requested.id }
    try await store.rememberLaunchIfMissing(requested)
    if !alreadySaved { try? await store.analytics.recordCommand(requested.create); try? await store.analytics.recordCommand(requested.initialSend) }
    var launch = await store.snapshot().launches.first { $0.id == requested.id } ?? requested
    try await verifyRemoteWorkspace()
    try await synchronize()
    if launch.createReceipt?.status != .completed {
      let existing = try await readReceipt(launch.create.commandID)
      let receipt: LibraryCommandReceipt
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
    let receipt: LibraryCommandReceipt
    if let existing { receipt = existing } else { receipt = try await sendCommand(launch.initialSend) }
    launch = try await store.rememberLaunchReceipt(receipt, launchID: launch.id) ?? launch
    return launch
  }
}
