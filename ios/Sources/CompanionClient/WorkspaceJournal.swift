import Foundation
import CryptoKit
import WovenMatterCompanion

public struct WorkspaceJournalState: Codable, Equatable, Sendable {
  public var formatVersion = 1
  public var libraryID: String?
  public var centralCursor: Int64 = 0
  public var workspaces: [String: CompanionExecutionWorkspace] = [:]
  public var pendingRegistrations: Set<String> = []
  public var centralWorkspaceRevisions: [String: Int64] = [:]
  public var entries: [String: CompanionJournalEntry] = [:]
  public var pendingEventIDs: Set<String> = []
  public var originSequences: [String: Int64] = [:]
  var conversationOwners: [String: String]?
  public var directCursors: [String: Int64] = [:]
  public var conversations: [String: CompanionConversation] = [:]
  public var transcripts: [String: CompanionTranscript] = [:]
  public var deletedConversationIDs: Set<String> = []
  public var commands: [String: MobileCommandRecord] = [:]
  public init() {}
  public var conversationWorkspaceIDs: [String: String] {
    conversationOwners ?? Dictionary(entries.values.map { ($0.conversationID, $0.workspaceID) }, uniquingKeysWith: { first, _ in first })
  }
  public var pendingEntries: [CompanionJournalEntry] {
    entries.values.filter { pendingEventIDs.contains($0.eventID) }.sorted {
      $0.workspaceID == $1.workspaceID ? $0.originSequence < $1.originSequence : $0.workspaceID < $1.workspaceID
    }
  }
}

/// Runtime history is never part of the evictable transcript cache. Receipts and
/// origin records survive process death and lost central acknowledgements.
public actor WorkspaceJournal {
  public enum Failure: Error, LocalizedError {
    case incompatibleStore, wrongLibrary, replayGap, reusedIdentity, invalidAcknowledgement, storageFull, deletedWorkspace
    public var errorDescription: String? {
      switch self {
      case .incompatibleStore: "This workspace journal requires a newer application."
      case .wrongLibrary: "This workspace belongs to another central library. Saved work has been retained."
      case .replayGap: "Workspace history has a missing or out-of-order record. Synchronization stopped without advancing its cursor."
      case .reusedIdentity: "A workspace reused a durable record identity with different contents."
      case .invalidAcknowledgement: "The central library returned an incomplete acknowledgement. History remains saved locally."
      case .storageFull: "The local execution history is full. Saved work has been retained."
      case .deletedWorkspace: "This execution workspace has been removed."
      }
    }
  }
  private let file: URL
  private var state: WorkspaceJournalState
  public init(file: URL) throws {
    self.file = file
    if FileManager.default.fileExists(atPath: file.path) {
      state = try WorkspaceJournalPersistence.load(at: file)
      guard state.formatVersion == 1 else { throw Failure.incompatibleStore }
    } else { state = .init() }
    if state.conversationOwners == nil { state.conversationOwners = state.conversationWorkspaceIDs }
  }
  public func snapshot() -> WorkspaceJournalState { state }
  public func bind(libraryID: String) throws {
    try transaction { next in
      guard next.libraryID == nil || next.libraryID == libraryID else { throw Failure.wrongLibrary }
      next.libraryID = libraryID
    }
  }
  public func upsertWorkspace(_ workspace: CompanionExecutionWorkspace, pending: Bool = true) throws {
    try transaction { next in
      guard next.libraryID == nil || next.libraryID == workspace.libraryID else { throw Failure.wrongLibrary }
      next.libraryID = workspace.libraryID
      if let existing = next.workspaces[workspace.id], existing.revision > workspace.revision { return }
      next.workspaces[workspace.id] = workspace
      if pending { next.pendingRegistrations.insert(workspace.id) }
      else { next.pendingRegistrations.remove(workspace.id); next.centralWorkspaceRevisions[workspace.id] = workspace.revision }
    }
  }
  public func mergeRegistry(_ workspaces: [CompanionExecutionWorkspace]) throws {
    for workspace in workspaces where !state.pendingRegistrations.contains(workspace.id) { try upsertWorkspace(workspace, pending: false) }
  }
  public func record(_ entry: CompanionJournalEntry) throws {
    try transaction { next in try Self.insert(entry, into: &next); next.pendingEventIDs.insert(entry.eventID) }
  }
  /// Only the execution owner calls this helper. Observing clients replay its
  /// immutable entries; they must not invent a second sequence for that workspace.
  @discardableResult public func append(workspaceID: String, conversation: CompanionConversation? = nil,
    transcript: CompanionTranscript? = nil, receipt: CompanionCommandReceipt? = nil) throws -> [CompanionJournalEntry] {
    var recorded: [CompanionJournalEntry] = []
    var transcript = transcript
    // Streaming UI rows are transient. The runtime emits their durable final
    // messages with stable native IDs; retaining both would duplicate output.
    transcript?.messages.removeAll { $0.status == "streaming" }
    if var delta = transcript, let previous = state.transcripts[delta.conversationID] {
      delta.messages = delta.messages.filter { message in !previous.messages.contains(message) }
      delta.activities = delta.activities.filter { activity in !previous.activities.contains(activity) }
      if delta.messages.isEmpty && delta.activities.isEmpty && delta.activeRunID == previous.activeRunID && delta.olderCursor == previous.olderCursor { transcript = nil }
      else { transcript = delta }
    }
    try transaction { next in
      guard next.workspaces[workspaceID]?.deleted != true else { throw Failure.deletedWorkspace }
      func add(_ kind: CompanionJournalEntry.Kind, id: String, runID: String? = nil) throws {
        let entry = CompanionJournalEntry(workspaceID: workspaceID, originSequence: (next.originSequences[workspaceID] ?? 0) + 1,
          conversationID: id, runID: runID, kind: kind, conversation: kind == .conversation ? conversation : nil,
          transcript: kind == .transcript ? transcript : nil, receipt: kind == .receipt ? receipt : nil)
        try Self.insert(entry, into: &next); next.pendingEventIDs.insert(entry.eventID); recorded.append(entry)
      }
      if let conversation, next.conversations[conversation.id] != conversation { try add(.conversation, id: conversation.id, runID: conversation.activeRunID) }
      if let transcript, next.transcripts[transcript.conversationID] != transcript { try add(.transcript, id: transcript.conversationID, runID: transcript.activeRunID) }
      if let receipt, let id = receipt.conversationID { try add(.receipt, id: id, runID: receipt.runID) }
    }
    return recorded
  }
  public func deleteConversation(workspaceID: String, conversationID: String) throws {
    guard !state.deletedConversationIDs.contains(conversationID) else { return }
    try record(.init(workspaceID: workspaceID, originSequence: (state.originSequences[workspaceID] ?? 0) + 1,
      conversationID: conversationID, kind: .deletedConversation))
  }
  public func restoreConversation(workspaceID: String, conversation: CompanionConversation) throws {
    guard state.deletedConversationIDs.contains(conversation.id) else { return }
    try record(.init(workspaceID: workspaceID, originSequence: (state.originSequences[workspaceID] ?? 0) + 1,
      conversationID: conversation.id, kind: .restoredConversation, conversation: conversation))
  }
  /// Preserve complete native history, without truncating it to a UI transcript.
  /// A recordID identifies one immutable native record in the workspace. The
  /// checksum verifies bytes; it must not serve as identity for distinct records.
  @discardableResult public func appendNativeRecord(workspaceID: String, conversationID: String, runID: String? = nil,
    recordID: String, format: String, data: Data) throws -> [CompanionJournalEntry] {
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let existing = state.entries.values.filter { $0.workspaceID == workspaceID && $0.nativeRecord?.recordID == recordID }
    if !existing.isEmpty {
      guard existing.allSatisfy({ $0.conversationID == conversationID && $0.runID == runID && $0.nativeRecord?.sha256 == sha && $0.nativeRecord?.format == format }) else { throw Failure.reusedIdentity }
      return existing.sorted { $0.originSequence < $1.originSequence }
    }
    let partBytes = 64 * 1_024, count = max(1, (data.count + partBytes - 1) / partBytes)
    var recorded: [CompanionJournalEntry] = []
    try transaction { next in
      for index in 0..<count {
        let start = index * partBytes, end = min(data.count, start + partBytes)
        let part = CompanionNativeRecordPart(recordID: recordID, format: format, partIndex: index, partCount: count,
          byteCount: Int64(data.count), sha256: sha, data: data.subdata(in: start..<end))
        let entry = CompanionJournalEntry(workspaceID: workspaceID, originSequence: (next.originSequences[workspaceID] ?? 0) + 1,
          conversationID: conversationID, runID: runID, kind: .nativeRecord, nativeRecord: part)
        try Self.insert(entry, into: &next); next.pendingEventIDs.insert(entry.eventID); recorded.append(entry)
      }
    }
    return recorded
  }
  public func acknowledge(_ result: CompanionJournalBatchResult, submitted: [CompanionJournalEntry]) throws {
    guard result.libraryID == state.libraryID, Set(result.acceptedEventIDs) == Set(submitted.map(\.eventID)),
      result.acceptedEventIDs.count == submitted.count else { throw Failure.invalidAcknowledgement }
    try transaction { next in
      for entry in submitted {
        guard next.entries[entry.eventID] == entry else { throw Failure.invalidAcknowledgement }
        next.pendingEventIDs.remove(entry.eventID)
      }
      // This is an upload receipt, never a read cursor. Other workspaces can have
      // interleaved records that this client still needs to download.
    }
  }
  public func receiveCentral(_ page: CompanionJournalPage) throws {
    try transaction { next in
      guard next.libraryID == page.libraryID else { throw Failure.wrongLibrary }
      guard page.cursor == next.centralCursor + Int64(page.entries.count), !page.hasMore || !page.entries.isEmpty else { throw Failure.replayGap }
      for entry in page.entries { try Self.insert(entry, into: &next) }
      next.centralCursor = page.cursor
    }
  }
  public func receiveWorkspace(_ page: CompanionJournalPage, workspaceID: String) throws {
    try transaction { next in
      guard next.libraryID == page.libraryID else { throw Failure.wrongLibrary }
      let cursor = next.directCursors[workspaceID] ?? 0
      guard page.cursor == cursor + Int64(page.entries.count), !page.hasMore || !page.entries.isEmpty else { throw Failure.replayGap }
      for (index, entry) in page.entries.enumerated() {
        guard entry.workspaceID == workspaceID, entry.originSequence == cursor + Int64(index) + 1 else { throw Failure.replayGap }
        try Self.insert(entry, into: &next); next.pendingEventIDs.insert(entry.eventID)
      }
      next.directCursors[workspaceID] = page.cursor
    }
  }
  public func rememberCommand(_ command: CompanionCommand, workspaceID: String) throws -> CompanionCommand {
    let key = Self.commandKey(workspaceID, command.commandID)
    if let existing = state.commands[key] {
      guard existing.command == command else { throw Failure.reusedIdentity }
      return existing.command
    }
    try transaction { $0.commands[key] = .init(command: command) }
    return command
  }
  public func rememberReceipt(_ receipt: CompanionCommandReceipt, workspaceID: String) throws {
    try transaction { next in
      let key = Self.commandKey(workspaceID, receipt.commandID)
      guard let command = next.commands[key]?.command, command.deviceID == receipt.deviceID else { throw Failure.invalidAcknowledgement }
      if let old = next.commands[key]?.receipt, old.status == .completed || old.status == .rejected { return }
      next.commands[key]?.receipt = receipt
    }
  }
  public func commandRecords(workspaceID: String) -> [MobileCommandRecord] {
    state.commands.filter { $0.key.hasPrefix(workspaceID + ":") }.map(\.value)
  }
  private static func commandKey(_ workspaceID: String, _ commandID: String) -> String { workspaceID + ":" + commandID }
  private static func insert(_ entry: CompanionJournalEntry, into next: inout WorkspaceJournalState) throws {
    if let existing = next.entries[entry.eventID] {
      guard existing == entry else { throw Failure.reusedIdentity }; return
    }
    guard entry.originSequence == (next.originSequences[entry.workspaceID] ?? 0) + 1 else { throw Failure.replayGap }
    if let owner = next.conversationWorkspaceIDs[entry.conversationID], owner != entry.workspaceID { throw Failure.reusedIdentity }
    guard entry.conversation?.id == nil || entry.conversation?.id == entry.conversationID,
      entry.transcript?.conversationID == nil || entry.transcript?.conversationID == entry.conversationID,
      entry.transcript?.messages.allSatisfy({ $0.conversationID == entry.conversationID }) != false else { throw Failure.reusedIdentity }
    switch entry.kind {
    case .conversation:
      guard let value = entry.conversation else { throw Failure.reusedIdentity }
      if !next.deletedConversationIDs.contains(value.id) { next.conversations[value.id] = value }
    case .transcript:
      guard let value = entry.transcript else { throw Failure.reusedIdentity }
      if !next.deletedConversationIDs.contains(value.conversationID) {
        next.transcripts[value.conversationID] = mergeTranscript(value, into: next.transcripts[value.conversationID])
      }
    case .restoredConversation:
      guard let value = entry.conversation, next.conversationWorkspaceIDs[value.id] != nil else { throw Failure.reusedIdentity }
      next.deletedConversationIDs.remove(value.id); next.conversations[value.id] = value
      var history: CompanionTranscript?
      for previous in next.entries.values.filter({ $0.conversationID == value.id && $0.kind == .transcript }).sorted(by: { $0.originSequence < $1.originSequence }) {
        if let transcript = previous.transcript { history = mergeTranscript(transcript, into: history) }
      }
      next.transcripts[value.id] = history
    case .receipt:
      guard entry.receipt != nil else { throw Failure.reusedIdentity }
    case .nativeRecord:
      guard entry.nativeRecord != nil else { throw Failure.reusedIdentity }
    case .deletedConversation:
      next.deletedConversationIDs.insert(entry.conversationID)
      next.conversations.removeValue(forKey: entry.conversationID); next.transcripts.removeValue(forKey: entry.conversationID)
    }
    next.entries[entry.eventID] = entry
    if next.conversationOwners == nil { next.conversationOwners = [:] }
    next.conversationOwners?[entry.conversationID] = entry.workspaceID
    next.originSequences[entry.workspaceID] = entry.originSequence
  }
  private static func mergeTranscript(_ value: CompanionTranscript, into prior: CompanionTranscript?) -> CompanionTranscript {
    var merged = prior ?? .init(conversationID: value.conversationID)
    for message in value.messages {
      if let index = merged.messages.firstIndex(where: { $0.id == message.id }) { merged.messages[index] = message }
      else { merged.messages.append(message) }
    }
    for activity in value.activities {
      if let index = merged.activities.firstIndex(where: { $0.id == activity.id }) { merged.activities[index] = activity }
      else { merged.activities.append(activity) }
    }
    merged.activeRunID = value.activeRunID; merged.olderCursor = value.olderCursor
    return merged
  }
  private func transaction(_ change: (inout WorkspaceJournalState) throws -> Void) throws {
    var next = state; try change(&next); guard next != state else { return }
    try WorkspaceJournalPersistence.persist(next, at: file); state = next
  }
}

public actor WorkspaceClient {
  public let store: MobileStore
  public let workspaceID: String
  private let transport: any ExecutionWorkspaceTransport
  private var refreshTask: Task<Void, Error>?
  private var launchTasks: [String: Task<MobileLaunchRecord, Error>] = [:]
  private var centralHistory = false
  public init(store: MobileStore, workspaceID: String, transport: any ExecutionWorkspaceTransport) {
    self.store = store; self.workspaceID = workspaceID; self.transport = transport
  }
  public func providers() async throws -> [CompanionProvider] { try await transport.providers() }
  public func pending() async throws -> [CompanionPendingInteraction] { try await transport.pending() }
  public func capabilities(_ id: String) async throws -> CompanionProvider { try await verify(); return try await transport.capabilities(id) }
  public func earlierTranscript(_ id: String, before: String) async throws -> CompanionTranscript { try await verify(); return try await transport.transcript(id, before: before) }
  public func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult { try await verify(); return try await transport.readWorkspace(request) }
  private func verify() async throws {
    let workspace = try await transport.identity()
    guard workspace.id == workspaceID, !workspace.deleted else { throw MobileStore.Failure.wrongWorkspace }
    centralHistory = workspace.capabilities.contains("history.central.v1")
    if let libraryID = await store.snapshot().workspaceID, libraryID != workspace.libraryID { throw WorkspaceJournal.Failure.wrongLibrary }
    if await store.journal.snapshot().workspaces[workspaceID] == nil {
      try await store.journal.upsertWorkspace(workspace, pending: !centralHistory)
    }
  }
  public func startConversation(_ requested: MobileLaunchRecord) async throws -> MobileLaunchRecord {
    if let task = launchTasks[requested.id] { return try await task.value }
    let task = Task { try await self.performLaunch(requested) }; launchTasks[requested.id] = task
    defer { launchTasks.removeValue(forKey: requested.id) }; return try await task.value
  }
  private func performLaunch(_ requested: MobileLaunchRecord) async throws -> MobileLaunchRecord {
    var requested = requested
    requested.create.workspaceID = workspaceID; requested.initialSend.workspaceID = workspaceID
    try await store.rememberLaunchIfMissing(requested)
    var launch = await store.snapshot().launches.first { $0.id == requested.id } ?? requested
    guard launch.create.workspaceID == workspaceID, launch.initialSend.workspaceID == workspaceID else { throw MobileStore.Failure.wrongWorkspace }
    if launch.terminalFailure || launch.accepted { return launch }
    if launch.createReceipt?.status != .completed {
      let receipt = try await submit(launch.create)
      launch = try await store.rememberLaunchReceipt(receipt, launchID: launch.id) ?? launch
      guard receipt.status == .completed else { return launch }
    }
    // Direct workspace prompts contain an explicit saved note snapshot; there is
    // no dependency on synchronizing a central note revision first.
    if !launch.sendPrepared { launch = try await store.prepareLaunchSend(id: launch.id, noteRevision: launch.initialSend.noteRevision) ?? launch }
    let receipt = try await submit(launch.initialSend)
    return try await store.rememberLaunchReceipt(receipt, launchID: launch.id) ?? launch
  }
  public func unresolvedCommand(matching command: CompanionCommand) async -> CompanionCommand? {
    await store.journal.commandRecords(workspaceID: workspaceID).first {
      ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) && $0.command.kind == command.kind &&
      $0.command.conversationID == command.conversationID && $0.command.runID == command.runID &&
      $0.command.text == command.text && $0.command.interactionID == command.interactionID
    }?.command
  }
  public func submit(_ requested: CompanionCommand) async throws -> CompanionCommandReceipt {
    try await verify()
    let saved = await store.journal.commandRecords(workspaceID: workspaceID).first { $0.id == requested.commandID }?.command
    let command = try await store.journal.rememberCommand(saved ?? requested, workspaceID: workspaceID)
    // An explicit retry always uses the persisted payload, even if the composer
    // has since changed. Recording a different payload under that ID is rejected.
    // Recover an acknowledgement before resubmitting the exact same command.
    let receipt: CompanionCommandReceipt
    if let existing = try await transport.receipt(command.commandID) { receipt = existing }
    else { receipt = try await transport.command(command) }
    try await store.journal.rememberReceipt(receipt, workspaceID: workspaceID)
    return receipt
  }
  public func refresh() async throws {
    if let refreshTask { return try await refreshTask.value }
    let task = Task { try await self.performRefresh() }; refreshTask = task
    defer { refreshTask = nil }; try await task.value
  }
  private func performRefresh() async throws {
    try await store.restoreExecutionProjection()
    try await verify()
    if centralHistory { try await store.cacheCentralConversations(transport.conversations()) }
    for _ in 0..<100 {
      let cursor = await store.journal.snapshot().directCursors[workspaceID] ?? 0
      let page = try await transport.events(after: cursor)
      try await store.journal.receiveWorkspace(page, workspaceID: workspaceID)
      try await store.restoreExecutionProjection()
      if !page.hasMore { break }
    }
    for record in await store.journal.commandRecords(workspaceID: workspaceID) where record.receipt?.status != .completed && record.receipt?.status != .rejected {
      if let receipt = try await transport.receipt(record.id) {
        try await store.journal.rememberReceipt(receipt, workspaceID: workspaceID)
        for launch in await store.snapshot().launches where launch.create.workspaceID == workspaceID && (launch.create.commandID == receipt.commandID || launch.initialSend.commandID == receipt.commandID) {
          try await store.rememberLaunchReceipt(receipt, launchID: launch.id)
        }
      }
    }
  }
  public func refreshTranscript(_ id: String) async throws -> CompanionTranscript {
    try await verify()
    let value = try await transport.transcript(id)
    guard value.conversationID == id else { throw MobileConnectionError.invalidResponse }
    try await store.cache(value); return value
  }
}
