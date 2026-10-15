import Foundation
import WovenMatterCompanion

public actor MobileSyncEngine {
  public let store: MobileStore
  private let transport: any CompanionTransport
  private var syncTask: Task<Void, Error>?
  private var analyticsTask: Task<Void, Never>?
  private var syncGeneration: UInt64 = 0
  var launchTasks: [String: Task<MobileLaunchRecord, Error>] = [:]
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
  private var status = MobileSynchronizationStatus()
  private var verifiedThisPass = false
  private var successfulLanes = Set<MobileSyncLane>()
  /// Await a normal shared flush but fail only when its verified, current pass
  /// did not complete a required lane. Never reuse an older success as proof.
  public func synchronizeRequiredLanes(_ required: Set<MobileSyncLane>) async throws {
    var failure: (any Error)?
    do { try await synchronize() }
    catch {
      if error is CancellationError { throw error }
      failure = error
    }
    try Task.checkCancellation()
    guard verifiedThisPass, required.isSubset(of: successfulLanes) else {
      throw failure ?? MobileConnectionError.http(409, "The required synchronization stage has not completed on this Mac.")
    }
  }
  private var scheduledTask: Task<Void, Never>?
  private var schedulingGeneration: UInt64 = 0
  private var syncRequested = false
  /// Writes request a short coalesced flush; connection lifecycle owns retry cadence.
  public func scheduleSynchronization() {
    syncRequested = true
    guard scheduledTask == nil else { return }
    schedulingGeneration &+= 1
    let generation = schedulingGeneration
    scheduledTask = Task {
      defer { if generation == schedulingGeneration { scheduledTask = nil } }
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      while syncRequested, !Task.isCancelled, generation == schedulingGeneration {
        syncRequested = false
        do { try await synchronize() } catch { }
      }
    }
  }
  public func cancelSynchronization() async {
    schedulingGeneration &+= 1; syncGeneration &+= 1; syncRequested = false
    let running = syncTask
    scheduledTask?.cancel(); scheduledTask = nil
    running?.cancel()
    let analytics = analyticsTask
    analytics?.cancel()
    await store.artifacts.cancelSynchronization()
    _ = try? await running?.value
    await analytics?.value
    analyticsTask = nil
    syncTask = nil
    status.centralReachable = nil
  }
  public func synchronizationStatus() async -> MobileSynchronizationStatus {
    await Self.makeStatus(store: store, previous: status)
  }
  public static func localSynchronizationStatus(store: MobileStore) async -> MobileSynchronizationStatus {
    await makeStatus(store: store, previous: .init())
  }
  private static func makeStatus(store: MobileStore, previous: MobileSynchronizationStatus) async -> MobileSynchronizationStatus {
    let local = await store.snapshot(), history = await store.journal.snapshot()
    let journal = await store.journal.pendingOwnerEntries(deviceID: local.deviceID)
    let registrations = history.pendingRegistrations.filter { id in
      history.workspaces[id].map { WorkspaceJournal.isLocalExecutionOwner($0, deviceID: local.deviceID) } == true
    }.count
    let transcriptPending = automaticTranscriptIDs(local).filter { id in
      local.transcripts[id] == nil || local.dirtyTranscriptIDs?.contains(id) == true ||
        (local.pinnedTranscriptIDs?.contains(id) == true && local.transcripts[id]?.olderCursor != nil)
    }.count
    let counts: [MobileSyncLane: Int] = [.library: local.outbox.count,
      .calendar: await store.calendar.pendingCount() + store.calendar.pendingRuns().count,
      .journal: journal.count + registrations, .artifacts: await store.artifacts.pendingUploadCount(),
      .offlineCache: local.uncachedNoteIDs.count + transcriptPending + (await store.artifacts.pendingDownloadCount())]
    var result = previous
    for lane in MobileSyncLane.allCases {
      var value = result.lanes[lane] ?? .init()
      value.pendingCount = counts[lane] ?? 0
      value.conflictCount = lane == .library ? local.conflicts.count : lane == .calendar ? await store.calendar.conflicts().count : 0
      if value.phase != .syncing && value.phase != .unsupported {
        if value.lastError != nil || value.conflictCount > 0 { value.phase = .blocked }
        else if value.pendingCount > 0 || value.hasMoreRemoteChanges { value.phase = .pending }
        else if value.lastSuccessfulSync != nil { value.phase = .current }
      }
      result.lanes[lane] = value
    }
    return result
  }
  func setLaneHasMore(_ lane: MobileSyncLane, _ value: Bool) { status.lanes[lane, default: .init()].hasMoreRemoteChanges = value }
  func synchronizeLane(_ lane: MobileSyncLane, _ operation: () async throws -> Void) async -> (any Error)? {
    status.lanes[lane, default: .init()].phase = .syncing
    do {
      try Task.checkCancellation()
      try await operation()
      try Task.checkCancellation()
      status.lanes[lane, default: .init()].lastError = nil
      status.lanes[lane, default: .init()].lastSuccessfulSync = Date()
      status.lanes[lane, default: .init()].phase = .current
      successfulLanes.insert(lane)
      return nil
    } catch {
      status.lanes[lane, default: .init()].lastError = error.localizedDescription
      status.lanes[lane, default: .init()].phase = .blocked
      return error
    }
  }
  private func performSynchronization() async throws {
    verifiedThisPass = false; successfulLanes = []
    let deviceID = await store.snapshot().deviceID
    try await store.journal.prepareOwnerPublication(deviceID: deviceID)
    try await store.restoreExecutionProjection()
    let identity: String
    do {
      identity = try await transport.workspaceIdentity()
      status.centralReachable = true; status.lastContactAt = Date()
      try await store.bindWorkspace(identity)
      verifiedThisPass = true
    } catch {
      if case MobileConnectionError.http = error { status.centralReachable = true; status.lastContactAt = Date() }
      else if !(error is MobileStore.Failure) { status.centralReachable = false }
      throw error
    }
    try Task.checkCancellation()
    if analyticsTask == nil, let analyticsTransport = transport as? any ProductAnalyticsTransport {
      // A single optional telemetry task must not delay any content lane.
      analyticsTask = Task {
        defer { analyticsTask = nil }
        try? await store.analytics.synchronize(using: analyticsTransport)
      }
    }
    var errors: [any Error] = []
    if let error = await synchronizeLane(.library, { try await self.synchronizeLibrary() }) { errors.append(error) }
    if let calendar = transport as? any CompanionCalendarTransport {
      if let error = await synchronizeLane(.calendar, { try await self.synchronizeCalendar(using: calendar, identity: identity) }) { errors.append(error) }
    } else { status.lanes[.calendar, default: .init()].phase = .unsupported }
    if let federation = transport as? any FederationTransport {
      if let error = await synchronizeLane(.journal, { try await self.synchronizeFederation(using: federation) }) { errors.append(error) }
      if let error = await synchronizeLane(.artifacts, { try await self.store.artifacts.synchronize(using: federation) }) { errors.append(error) }
    } else {
      status.lanes[.journal, default: .init()].phase = .unsupported
      status.lanes[.artifacts, default: .init()].phase = .unsupported
    }
    if let error = await synchronizeLane(.offlineCache, { try await self.synchronizeOfflineCache() }) { errors.append(error) }
    try Task.checkCancellation()
    if let error = errors.first { throw error }
  }
  private func synchronizeLibrary() async throws {
    var errors: [any Error] = []
    let local = await store.snapshot()
    if local.hasLibrarySnapshot != true && local.cursor == 0 {
      do {
        let snapshot = try await transport.snapshot()
        try await store.apply(snapshot)
      } catch { errors.append(error) }
    }
    var processed = 0, attempted = Set<String>()
    while let mutation = try await store.nextMutation(excludingOperationIDs: attempted), processed < 200 {
      try Task.checkCancellation()
      attempted.insert(mutation.operationID); processed += 1
      do {
        var result = try await transport.mutate(mutation)
        guard result.operationID == mutation.operationID else { throw MobileStore.Failure.malformedAcknowledgement }
        if result.status == .conflict, let metadata = result.note, !metadata.contentIncluded { result.note = try await transport.note(metadata.id) }
        try await store.acknowledge(result)
        if result.status != .accepted && (mutation.kind == .createFolder || mutation.kind == .renameFolder ||
          (mutation.kind == .deleteFolder && result.status != .notFound)) {
          errors.append(MobileConnectionError.http(409, result.message ?? "A local edit needs attention. Its saved data has been retained."))
        }
      } catch { errors.append(error) }
    }
    do {
      for _ in 0..<100 {
        try Task.checkCancellation()
        let page = try await transport.changes(after: store.snapshot().cursor)
        setLaneHasMore(.library, page.hasMore)
        if page.resetRequired {
          let snapshot = try await transport.snapshot(); try await store.apply(snapshot)
          setLaneHasMore(.library, false)
          break
        }
        try await store.apply(page)
        if !page.hasMore { break }
      }
    } catch { errors.append(error) }
    if let error = errors.first { throw error }
  }
  private func synchronizeCalendar(using calendar: any CompanionCalendarTransport, identity: String) async throws {
    let snapshot = try await calendar.calendarSnapshot()
    guard snapshot.workspaceID == identity else { throw CompanionCalendarError.wrongWorkspace }
    try await store.calendar.apply(snapshot)
    var count = 0
    while let mutation = try await store.calendar.nextMutation(), count < 200 {
      try Task.checkCancellation()
      try await store.calendar.acknowledge(calendar.calendarMutate(mutation)); count += 1
    }
    let runs = Array(await store.calendar.pendingRuns().prefix(200))
    if !runs.isEmpty {
      let accepted = try await calendar.calendarPublishRuns(runs)
      guard accepted.count == runs.count, Set(accepted) == Set(runs.map(\.id)) else { throw CompanionCalendarError.invalidReceipt }
      try await store.calendar.acknowledgeRuns(runs)
    }
    let updated = try await calendar.calendarSnapshot()
    guard updated.workspaceID == identity else { throw CompanionCalendarError.wrongWorkspace }
    try await store.calendar.apply(updated)
  }
  private func synchronizeOfflineCache() async throws {
    var errors: [any Error] = []
    // Notes are an offline library, not an opportunistic ten-document cache.
    for id in await store.notesToCache() {
      try Task.checkCancellation()
      do { try await store.cacheNote(transport.note(id)) } catch { errors.append(error) }
    }
    let current = await store.snapshot()
    let selected = Self.automaticTranscriptIDs(current)
    for conversation in current.conversations.values.sorted(by: { $0.updatedAt > $1.updatedAt }) where selected.contains(conversation.id) {
      let pinned = current.pinnedTranscriptIDs?.contains(conversation.id) == true
      try Task.checkCancellation()
      do {
        if pinned { try await keepTranscriptOffline(conversation.id) }
        else { try await refreshTranscriptIfNeeded(conversation.id) }
      } catch { errors.append(error) }
    }
    if let error = errors.first { throw error }
  }
  private static func automaticTranscriptIDs(_ current: MobileStoreState) -> Set<String> {
    let cutoff = Date().addingTimeInterval(-14 * 86_400)
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fallback = ISO8601DateFormatter()
    return Set(current.conversations.values.compactMap { conversation in
      guard current.executionConversationIDs?.contains(conversation.id) != true else { return nil }
      let date = formatter.date(from: conversation.updatedAt) ?? fallback.date(from: conversation.updatedAt) ?? .distantPast
      return current.pinnedTranscriptIDs?.contains(conversation.id) == true || conversation.activeRunID != nil || date >= cutoff ? conversation.id : nil
    })
  }
  public func keepTranscriptOffline(_ id: String) async throws {
    try await store.setTranscriptPinned(id, true)
    try await refreshTranscriptIfNeeded(id)
    var seen = Set<String>()
    while let cursor = await store.snapshot().transcripts[id]?.olderCursor {
      guard seen.insert(cursor).inserted else { throw MobileConnectionError.invalidResponse }
      try Task.checkCancellation()
      _ = try await earlierTranscript(id, before: cursor)
    }
  }
  public func ensureArtifactCached(_ id: String) async throws -> URL {
    try await verifyRemoteWorkspace()
    guard let federation = transport as? any FederationTransport else { throw MobileConnectionError.offline }
    return try await store.artifacts.download(id: id, using: federation)
  }
  public func keepArtifactOffline(_ id: String) async throws {
    try await store.artifacts.setPinned(id, true)
    _ = try await ensureArtifactCached(id)
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
  public func earlierTranscript(_ id: String, before: String) async throws -> CompanionTranscript {
    try await verifyRemoteWorkspace()
    let page = try await transport.transcript(id, before: before)
    guard page.conversationID == id else { throw MobileConnectionError.invalidResponse }
    try await store.cacheTranscriptPage(page)
    return page
  }
  public func transcriptActivityDetail(_ id: String, activityID: String) async throws -> CompanionActivity? {
    try await transport.transcript(id).activities.first { $0.id == activityID }
  }
  public func refreshTranscriptIfNeeded(_ id: String) async throws {
    let local = await store.snapshot()
    if local.dirtyTranscriptIDs?.contains(id) == true || local.transcripts[id] == nil { try await refreshTranscript(id) }
  }
  public func refreshTranscript(_ id: String) async throws {
    try await store.cache(transport.transcript(id))
  }
}
