import Foundation
import WovenMatterCompanion

public actor MobileSyncEngine {
  public let store: MobileStore
  private let transport: any CompanionTransport
  private var syncTask: Task<Void, Error>?
  var launchTasks: [String: Task<MobileLaunchRecord, Error>] = [:]
  private var dirtyTranscripts: Set<String> = []
  public init(store: MobileStore, transport: any CompanionTransport) { self.store = store; self.transport = transport }
  /// Only one flush owns the outbox at a time. Acknowledgements and newer edits
  /// meet inside the store actor, so editing while a request is in flight is safe.
  public func synchronize() async throws {
    if let syncTask { return try await syncTask.value }
    let task = Task { try await self.performSynchronization() }
    syncTask = task
    defer { syncTask = nil }
    try await task.value
  }
  private func performSynchronization() async throws {
    try await store.verifyWorkspace(transport.workspaceIdentity())
    let local = await store.snapshot()
    if local.workspaceID == nil {
      let snapshot = try await transport.snapshot()
      try await store.apply(snapshot)
      dirtyTranscripts.formUnion(snapshot.conversations.map(\.id))
    }
    var processed = 0
    while let mutation = try await store.nextMutation(), processed < 200 {
      var result = try await transport.mutate(mutation)
      if result.status == .conflict, let metadata = result.note, !metadata.contentIncluded {
        result.note = try await transport.note(metadata.id)
      }
      try await store.acknowledge(result)
      processed += 1
      if result.status != .accepted && (mutation.kind == .createFolder || mutation.kind == .renameFolder) {
        throw MobileConnectionError.http(409, result.message ?? "The folder could not sync. Dependent notes remain saved on this iPhone.")
      }
    }
    var pages = 0
    repeat {
      let page = try await transport.changes(after: store.snapshot().cursor)
      if page.resetRequired {
        let snapshot = try await transport.snapshot()
        try await store.apply(snapshot)
        dirtyTranscripts.formUnion(snapshot.conversations.map(\.id))
        break
      }
      dirtyTranscripts.formUnion(page.changes.filter { $0.resourceKind == .transcript || $0.resourceKind == .conversation }.map(\.resourceID))
      try await store.apply(page)
      pages += 1
      if !page.hasMore { break }
    } while pages < 100
    for id in await store.notesToCache().prefix(10) { try await store.cacheNote(transport.note(id)) }
    let current = await store.snapshot()
    let recent = current.conversations.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(20)
    let missing = recent.filter { current.transcripts[$0.id] == nil }
    for conversation in missing.prefix(2) { try await refreshTranscript(conversation.id) }
  }
  public func submit(_ command: CompanionCommand) async throws -> CompanionCommandReceipt {
    try await store.verifyWorkspace(transport.workspaceIdentity())
    let stored = await store.snapshot().commands.first { $0.id == command.commandID }
    var command = stored?.command ?? command
    if stored == nil, let id = command.noteID {
      try await synchronize()
      let note = try await store.canonicalNote(id: id)
      command.noteRevision = note.revision
    }
    try await store.rememberCommand(command)
    let receipt = try await transport.command(command)
    try await store.rememberReceipt(receipt)
    return receipt
  }
  func verifyRemoteWorkspace() async throws { try await store.verifyWorkspace(transport.workspaceIdentity()) }
  func readReceipt(_ id: String) async throws -> CompanionCommandReceipt? { try await transport.receipt(id) }
  func sendCommand(_ command: CompanionCommand) async throws -> CompanionCommandReceipt { try await transport.command(command) }
  public func recoverCommandReceipts() async throws {
    try await verifyRemoteWorkspace()
    for launch in await store.snapshot().launches where !launch.accepted {
      if let receipt = try await transport.receipt(launch.create.commandID) { try await store.rememberLaunchReceipt(receipt, launchID: launch.id) }
      let latest = await store.snapshot().launches.first { $0.id == launch.id }
      if latest?.sendPrepared == true, let receipt = try await transport.receipt(launch.initialSend.commandID) { try await store.rememberLaunchReceipt(receipt, launchID: launch.id) }
    }
    let records = await store.snapshot().commands
    for record in records where record.receipt == nil || record.receipt?.status == .accepted || record.receipt?.status == .outcomeUnknown {
      if let receipt = try await transport.receipt(record.id) { try await store.rememberReceipt(receipt) }
    }
  }
  public func linkedData(note: CompanionNote, tableID: String? = nil) async throws -> CompanionLinkedData {
    try await verifyRemoteWorkspace()
    let value = try await transport.linkedData(note.id, tableID: tableID)
    guard value.noteID == note.id, value.noteRevision == note.revision, value.tableID == tableID else {
      throw MobileConnectionError.http(409, "This document changed on your Mac. Refresh it to preview the current linked data.")
    }
    return value
  }
  public func providers() async throws -> [CompanionProvider] { try await transport.providers() }
  public func pending() async throws -> [CompanionPendingInteraction] { try await transport.pending() }
  public func earlierTranscript(_ id: String, before: String) async throws -> CompanionTranscript { try await transport.transcript(id, before: before) }
  public func refreshTranscriptIfNeeded(_ id: String) async throws {
    let cached = await store.snapshot().transcripts[id]
    if dirtyTranscripts.contains(id) || cached == nil { try await refreshTranscript(id) }
  }
  public func refreshTranscript(_ id: String) async throws {
    try await store.cache(transport.transcript(id))
    dirtyTranscripts.remove(id)
  }
}
