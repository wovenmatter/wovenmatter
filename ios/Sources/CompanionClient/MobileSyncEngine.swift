import Foundation
import WovenMatterCompanion

public actor MobileSyncEngine {
  public let store: MobileStore
  private let transport: any CompanionTransport
  private var syncTask: Task<Void, Error>?
  private var syncGeneration: UInt64 = 0
  var launchTasks: [String: Task<MobileLaunchRecord, Error>] = [:]
  private var dirtyTranscripts: Set<String> = []
  public init(store: MobileStore, transport: any CompanionTransport) { self.store = store; self.transport = transport }
  /// Only one flush owns the outbox at a time. Acknowledgements and newer edits
  /// meet inside the store actor, so editing while a request is in flight is safe.
  public func synchronize() async throws {
    let task: Task<Void, Error>
    let generation: UInt64
    if let existing = syncTask {
      task = existing; generation = syncGeneration
    } else {
      syncGeneration &+= 1; generation = syncGeneration
      task = Task { try await self.performSynchronization() }
      syncTask = task
    }
    // Every waiter releases the completed generation. A waiter may resume before
    // its creator; it must not accidentally rejoin an already-finished flush or
    // clear a newer flush started by another caller.
    defer { if syncGeneration == generation { syncTask = nil } }
    try await task.value
  }
  private func performSynchronization() async throws {
    try await store.verifyWorkspace(transport.workspaceIdentity())
    if let analyticsTransport = transport as? any ProductAnalyticsTransport {
      // Optional capability: telemetry errors must never break library synchronization.
      try? await store.analytics.synchronize(using: analyticsTransport)
    }
    try await store.restoreExecutionProjection()
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
      if result.status != .accepted && (mutation.kind == .createFolder || mutation.kind == .renameFolder || (mutation.kind == .deleteFolder && result.status != .notFound)) {
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
    for conversation in missing.prefix(2) where current.executionConversationIDs?.contains(conversation.id) != true { try await refreshTranscript(conversation.id) }
    if let calendar = transport as? any CompanionCalendarTransport {
      do {
        // A full series snapshot includes tombstones. Old hosts without this
        // endpoint leave the calendar safely local until both apps are updated.
        let snapshot = try await calendar.calendarSnapshot()
        guard snapshot.workspaceID == (await store.snapshot()).workspaceID else { throw CompanionCalendarError.wrongWorkspace }
        try await store.calendar.apply(snapshot)
        var count = 0
        while let mutation = try await store.calendar.nextMutation(), count < 200 {
          try await store.calendar.acknowledge(calendar.calendarMutate(mutation)); count += 1
        }
        let runs = Array(await store.calendar.pendingRuns().prefix(200))
        if !runs.isEmpty {
          let accepted = try await calendar.calendarPublishRuns(runs)
          guard Set(accepted) == Set(runs.map(\.id)) else { throw CompanionCalendarError.invalidReceipt }
          try await store.calendar.acknowledgeRuns(runs)
        }
        let updated = try await calendar.calendarSnapshot()
        guard updated.workspaceID == snapshot.workspaceID else { throw CompanionCalendarError.wrongWorkspace }
        try await store.calendar.apply(updated)
      } catch MobileConnectionError.http(404, _) { }
    }
    if let federation = transport as? any FederationTransport { try await synchronizeFederation(using: federation) }

  }
  public func submit(_ command: CompanionCommand) async throws -> CompanionCommandReceipt {
    guard command.workspaceID == nil else { throw MobileStore.Failure.wrongWorkspace }
    try await store.verifyWorkspace(transport.workspaceIdentity())
    let stored = await store.snapshot().commands.first { $0.id == command.commandID }
    var command = stored?.command ?? command
    if stored == nil, let id = command.noteID {
      try await synchronize()
      let note = try await store.canonicalNote(id: id)
      command.noteRevision = note.revision
    }
    try await store.rememberCommand(command)
    if stored == nil { try? await store.analytics.recordCommand(command) }
    let receipt = try await transport.command(command)
    try await store.rememberReceipt(receipt)
    return receipt
  }
  func verifyRemoteWorkspace() async throws { try await store.verifyWorkspace(transport.workspaceIdentity()) }
  func readReceipt(_ id: String) async throws -> CompanionCommandReceipt? { try await transport.receipt(id) }
  func sendCommand(_ command: CompanionCommand) async throws -> CompanionCommandReceipt { try await transport.command(command) }
  public func recoverCommandReceipts() async throws {
    try await verifyRemoteWorkspace()
    for launch in await store.snapshot().launches where !launch.accepted && launch.create.workspaceID == nil {
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
  public func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult {
    try await verifyRemoteWorkspace()
    return try await transport.readWorkspace(request)
  }
  public func providers() async throws -> [CompanionProvider] { try await transport.providers() }
  public func pending() async throws -> [CompanionPendingInteraction] { try await transport.pending() }
  public func earlierTranscript(_ id: String, before: String) async throws -> CompanionTranscript { try await transport.transcript(id, before: before) }
  public func transcriptActivityDetail(_ id: String, activityID: String) async throws -> CompanionActivity? {
    try await transport.transcript(id).activities.first { $0.id == activityID }
  }
  public func refreshTranscriptIfNeeded(_ id: String) async throws {
    let cached = await store.snapshot().transcripts[id]
    if dirtyTranscripts.contains(id) || cached == nil { try await refreshTranscript(id) }
  }
  public func refreshTranscript(_ id: String) async throws {
    try await store.cache(transport.transcript(id))
    dirtyTranscripts.remove(id)
  }
}
