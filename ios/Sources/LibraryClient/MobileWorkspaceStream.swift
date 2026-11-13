import Foundation
import WovenMatterShared

/// One listed workspace's live stream on the phone (docs/architecture/WOVEN_EVERYWHERE.md,
/// "Streaming", iPhone): `workspace` always, `conversation` only for the open
/// chat. Journal entries go to the phone's `WorkspaceJournal` exactly as HTTP
/// pages did, written in batches; the open chat's transcript goes to the
/// store's cache. The app stops it in the background and starts it again in
/// the foreground.
///
/// The library host's stream also carries the "central" route: the host's own
/// sessions, which its library holds unassigned. Its summaries keep that
/// identity (`setLibraryHost`), and its `conversation` subscription follows an
/// open central chat exactly as another workspace's follows its own.
public actor MobileWorkspaceStream {
  public enum Update: Sendable, Equatable {
    case state(StreamConnection.State)
    case pending([PendingInteraction])
    /// Journal entries or conversation summaries reached the store.
    case history
    case transcript(conversationID: String)
    case capabilities(conversationID: String, HarnessCapabilities)
    /// The open chat's settings (model, thinking, permission, tools, goal).
    case session(conversationID: String, SessionSettings)
    /// Receipts learned for commands whose reply was lost.
    case receipts([LibraryCommandReceipt])
    /// The server ended the open chat's subscription (it does not serve that
    /// chat, or it is too large for one frame); nothing streams for it now.
    case conversationEnded(conversationID: String, StreamError?)
    /// The server ended the `workspace` subscription for good (a
    /// non-retryable error): nothing about this workspace streams on this
    /// connection. The next connection subscribes again.
    case workspaceEnded(StreamError?)
    /// The server's library change cursor (`library` items), with the
    /// server's member device ID from its `hello`: a phone that syncs with
    /// that server and holds an older cursor synchronizes now.
    case library(cursor: Int64, serverDeviceID: String)
  }

  /// Consecutive journal items are written together: at most this many, and
  /// no later than `journalDelay` after the first, or when anything else
  /// (`synchronized`, `pending`, …) arrives.
  static let journalBatchLimit = 256
  static let journalDelay: Duration = .milliseconds(50)

  public nonisolated let workspaceID: String
  public nonisolated let connection: StreamConnection
  private let libraryID: String
  private let centralHistory: Bool
  private var libraryHost = false
  private let store: MobileStore
  private let update: @Sendable (Update) async -> Void
  private var workspaceSubscription: StreamSubscription?
  /// Identifies the current subscription attempt, so an event of an older one is ignored.
  private var workspaceToken = 0
  private var workspaceSubscribing = false
  /// The server ended `workspace` for good on this connection.
  private var workspaceEnded = false
  /// A cursor to subscribe again from, asked for before `subscribe` returned.
  private var workspaceRestart: Int64?
  private var conversation: (id: String, token: Int, subscription: StreamSubscription?)?
  private var nextToken = 0
  /// The open chat whose subscription the server ended. It is not asked for
  /// again on this connection, so a refusal never loops.
  private var endedConversationID: String?
  private var wantedConversationID: String?
  private var opening = false
  private var stateTask: Task<Void, Never>?
  /// Journal entries taken and not yet written, in order.
  private var journalBuffer: [ExecutionJournalEntry] = []
  /// The last sequence of the batch being written.
  private var journalInFlight: Int64?
  private var journalWrite: Task<Void, Never>?
  private var journalTimer: Task<Void, Never>?
  /// Batches written (one journal write and one projection restore each).
  private(set) var journalWrites = 0

  public init(workspace: ExecutionWorkspace, store: MobileStore, connection: StreamConnection,
              update: @escaping @Sendable (Update) async -> Void) {
    workspaceID = workspace.id; libraryID = workspace.libraryID
    centralHistory = workspace.capabilities.contains("history.central.v1")
    self.store = store; self.connection = connection; self.update = update
  }

  /// The open chat, if it is this workspace's.
  public var conversationID: String? { conversation?.id }

  /// Whether this workspace is the library host the phone syncs with. Its
  /// conversation summaries then keep the library's identity for them.
  public func setLibraryHost(_ value: Bool) { libraryHost = value }

  public func start() async {
    if stateTask == nil {
      let connection = connection
      stateTask = Task { [weak self] in
        for await state in connection.states { await self?.stateChanged(state) }
      }
    }
    if workspaceSubscription == nil, !workspaceSubscribing, !workspaceEnded { await subscribeWorkspace() }
    await connection.start()
  }

  /// Closes the socket cleanly; subscriptions resume on `start()`.
  public func stop() async {
    await connection.stop()
  }

  /// Ends everything, for a workspace that is no longer listed.
  public func close() async {
    stateTask?.cancel(); stateTask = nil
    await flushJournal()
    await stop()
  }

  private func subscribeWorkspace() async {
    nextToken += 1
    let token = nextToken
    workspaceToken = token; workspaceSubscribing = true; workspaceEnded = false
    defer { if workspaceToken == token { workspaceSubscribing = false } }
    let after = await store.journal.snapshot().directCursors[workspaceID] ?? 0
    let subscription = await connection.subscribe(.workspace, params: .init(after: after)) { [weak self] event in
      await self?.workspaceEvent(event, token: token) ?? .accepted
    }
    // Ended while it was being sent: the connection has already dropped it.
    guard workspaceToken == token, !workspaceEnded else { return }
    workspaceSubscription = subscription
    if let cursor = workspaceRestart {
      workspaceRestart = nil
      await connection.resubscribe(subscription, params: .init(after: cursor))
    }
  }

  /// Subscribes `conversationID` (nil: none) as the open chat, ending the previous one.
  /// Calls that overlap (the selection changing while a subscription is sent)
  /// leave exactly one subscription, for the latest chat asked for. Items
  /// that arrive while the subscription is still being sent are kept.
  public func open(conversationID: String?) async {
    wantedConversationID = conversationID
    guard !opening else { return }
    opening = true; defer { opening = false }
    while conversation?.id != wantedConversationID {
      if let previous = conversation {
        conversation = nil
        if let subscription = previous.subscription { await connection.unsubscribe(subscription) }
        continue
      }
      guard let target = wantedConversationID, target != endedConversationID else { return }
      endedConversationID = nil
      nextToken += 1
      let token = nextToken
      // Known before the subscription is sent, so its first snapshot is not dropped.
      conversation = (target, token, nil)
      let subscription = await connection.subscribe(.conversation, params: .init(conversationID: target)) { [weak self] event in
        await self?.conversationEvent(event, conversationID: target, token: token) ?? .accepted
      }
      // Ended meanwhile: the connection already dropped it, and the loop stops.
      if conversation?.token == token { conversation?.subscription = subscription }
    }
  }

  private func stateChanged(_ state: StreamConnection.State) async {
    if case .open = state { endedConversationID = nil }
    // The server must answer for the listed workspace.
    if case .open(let hello) = state, hello.workspaceID != workspaceID || hello.libraryID != libraryID {
      await connection.stop()
      await update(.state(.waiting(.refused(status: 200, code: "wrong_workspace", message: "It answered as another workspace."))))
      return
    }
    // Reported before subscribing again, so an end that answers the new
    // subscription is reported after it, and the fallback reads resume.
    await update(.state(state))
    // A new connection asks again for a `workspace` the server ended on the last one.
    if case .open = state, workspaceEnded { await subscribeWorkspace() }
    guard case .open = state else { return }
    // Commands whose reply was lost are asked about, never resent. Not from
    // a subscription handler: the replies arrive on this same socket.
    let (connection, store, workspaceID) = (connection, store, workspaceID)
    Task {
      guard let learned = try? await StreamCommands.resolveUnknown(workspaceID: workspaceID, journal: store.journal, connection: connection),
            !learned.isEmpty else { return }
      for receipt in learned {
        for launch in await store.snapshot().launches where launch.create.workspaceID == workspaceID &&
          (launch.create.commandID == receipt.commandID || launch.initialSend.commandID == receipt.commandID) {
          _ = try? await store.rememberLaunchReceipt(receipt, launchID: launch.id)
        }
      }
      await self.update(.receipts(learned))
    }
  }

  private func workspaceEvent(_ event: StreamSubscriptionEvent, token: Int) async -> StreamItemDisposition {
    guard token == workspaceToken else { return .accepted }
    let item: StreamItem
    switch event {
    case .ended(let error):
      await flushJournal()
      workspaceSubscription = nil; workspaceEnded = true; workspaceSubscribing = false
      await update(.workspaceEnded(error))
      return .accepted
    case .item(let value): item = value
    }
    if case .journal(let value) = item.payload { return await takeJournal(value.entry) }
    // Anything else follows the journal entries before it.
    await flushJournal()
    switch item.payload {
    case .conversations(let value):
      guard centralHistory else { return .accepted }
      if libraryHost { try? await store.cacheLibraryHostConversations(value.conversations) }
      else { try? await store.cacheCentralConversations(value.conversations) }
      await update(.history)
    case .pending(let value):
      await update(.pending(value.interactions))
    case .library(let value):
      // The socket's own `hello` names the server; cursors are per server.
      guard let server = await connection.hello?.deviceID.lowercased() else { return .accepted }
      await update(.library(cursor: value.cursor, serverDeviceID: server))
    case .journal, .transcript, .capabilities, .session, .owner, .synchronized, .serverState, .unknown:
      break
    }
    return .accepted
  }

  // MARK: Journal batches

  /// One journal item: kept for the next batch when it continues the last
  /// one taken; one already held is skipped; a gap writes what came in order
  /// and subscribes again from the stored cursor.
  private func takeJournal(_ entry: ExecutionJournalEntry) async -> StreamItemDisposition {
    let last: Int64
    if let buffered = journalBuffer.last?.originSequence ?? journalInFlight { last = buffered }
    else { last = await storedCursor() }
    guard entry.originSequence > last else { return .accepted }
    guard entry.originSequence == last + 1 else {
      await flushJournal()
      return .resubscribe(.init(after: await storedCursor()))
    }
    journalBuffer.append(entry)
    if journalBuffer.count >= Self.journalBatchLimit { await flushJournal() }
    else if journalTimer == nil {
      journalTimer = Task { [weak self] in
        do { try await Task.sleep(for: Self.journalDelay) } catch { return }
        await self?.flushJournal()
      }
    }
    return .accepted
  }

  private func storedCursor() async -> Int64 { await store.journal.snapshot().directCursors[workspaceID] ?? 0 }

  /// Writes the entries taken so far: one journal write and one projection
  /// restore for the whole batch. Writes run one after another.
  private func flushJournal() async {
    journalTimer?.cancel(); journalTimer = nil
    let previous = journalWrite
    let write = Task { await previous?.value; await self.writeJournal() }
    journalWrite = write
    await write.value
  }

  private func writeJournal() async {
    guard !journalBuffer.isEmpty else { return }
    let entries = journalBuffer
    journalBuffer = []
    journalInFlight = entries.last?.originSequence
    defer { journalInFlight = nil }
    let page = ExecutionJournalPage(libraryID: libraryID, cursor: entries.last?.originSequence ?? 0, entries: entries)
    do {
      try await store.journal.receiveWorkspace(page, workspaceID: workspaceID, localDeviceID: store.snapshot().deviceID)
      try await store.restoreExecutionProjection()
      journalWrites += 1
      await update(.history)
    } catch {
      // Not taken (a gap, or a store that failed to write): what came after
      // is dropped, and the subscription replays from the saved cursor. It
      // keeps its questions and approvals meanwhile.
      journalBuffer = []
      let cursor = await storedCursor()
      if let subscription = workspaceSubscription { await connection.resubscribe(subscription, params: .init(after: cursor)) }
      else { workspaceRestart = cursor }
    }
  }

  private func conversationEvent(_ event: StreamSubscriptionEvent, conversationID: String, token: Int) async -> StreamItemDisposition {
    guard conversation?.token == token else { return .accepted }
    switch event {
    case .ended(let error):
      conversation = nil; endedConversationID = conversationID
      await update(.conversationEnded(conversationID: conversationID, error))
    case .item(let item):
      switch item.payload {
      case .transcript(let value):
        guard value.transcript.conversationID == conversationID else { return .accepted }
        let current = await store.snapshot().transcripts[conversationID] ?? .init(conversationID: conversationID)
        try? await store.cache(current.applying(value))
        await update(.transcript(conversationID: conversationID))
      case .capabilities(let value):
        await update(.capabilities(conversationID: conversationID, value.capabilities))
      case .session(let value):
        guard value.settings.conversationID == conversationID else { return .accepted }
        await update(.session(conversationID: conversationID, value.settings))
      case .conversations, .pending, .journal, .owner, .library, .synchronized, .serverState, .unknown:
        break
      }
    }
    return .accepted
  }
}
