import Foundation
import WovenMatterShared

/// One listed workspace's live stream on the phone (docs/architecture/WOVEN_EVERYWHERE.md,
/// "Streaming", iPhone): `workspace` always, `conversation` only for the open
/// chat. Journal entries go to the phone's `WorkspaceJournal` exactly as HTTP
/// pages did; the open chat's transcript goes to the store's cache. The app
/// stops it in the background and starts it again in the foreground.
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
  }

  public nonisolated let workspaceID: String
  public nonisolated let connection: StreamConnection
  private let libraryID: String
  private let centralHistory: Bool
  private let store: MobileStore
  private let update: @Sendable (Update) async -> Void
  private var workspaceSubscription: StreamSubscription?
  private var conversation: (id: String, subscription: StreamSubscription)?
  private var stateTask: Task<Void, Never>?

  public init(workspace: ExecutionWorkspace, store: MobileStore, connection: StreamConnection,
              update: @escaping @Sendable (Update) async -> Void) {
    workspaceID = workspace.id; libraryID = workspace.libraryID
    centralHistory = workspace.capabilities.contains("history.central.v1")
    self.store = store; self.connection = connection; self.update = update
  }

  /// The open chat, if it is this workspace's.
  public var conversationID: String? { conversation?.id }

  public func start() async {
    if workspaceSubscription == nil {
      let workspaceID = workspaceID
      let after: Int64 = await store.journal.snapshot().directCursors[workspaceID] ?? 0
      workspaceSubscription = await connection.subscribe(.workspace, params: .init(after: after)) { [weak self] event in
        await self?.workspaceEvent(event) ?? .accepted
      }
      let connection = connection
      stateTask = Task { [weak self] in
        for await state in connection.states { await self?.stateChanged(state) }
      }
    }
    await connection.start()
  }

  /// Closes the socket cleanly; subscriptions resume on `start()`.
  public func stop() async {
    await connection.stop()
  }

  /// Ends everything, for a workspace that is no longer listed.
  public func close() async {
    stateTask?.cancel(); stateTask = nil
    await stop()
  }

  /// Subscribes `conversationID` (nil: none) as the open chat, ending the previous one.
  public func open(conversationID: String?) async {
    guard conversation?.id != conversationID else { return }
    if let previous = conversation { conversation = nil; await connection.unsubscribe(previous.subscription) }
    guard let conversationID else { return }
    let subscription = await connection.subscribe(.conversation, params: .init(conversationID: conversationID)) { [weak self] event in
      await self?.conversationEvent(event, conversationID: conversationID) ?? .accepted
    }
    conversation = (conversationID, subscription)
  }

  private func stateChanged(_ state: StreamConnection.State) async {
    // The server must answer for the listed workspace.
    if case .open(let hello) = state, hello.workspaceID != workspaceID || hello.libraryID != libraryID {
      await connection.stop()
      await update(.state(.waiting(.refused(status: 200, code: "wrong_workspace", message: "It answered as another workspace."))))
      return
    }
    await update(.state(state))
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

  private func workspaceEvent(_ event: StreamSubscriptionEvent) async -> StreamItemDisposition {
    guard case .item(let item) = event else { return .accepted }
    switch item.payload {
    case .journal(let value):
      let cursor = await store.journal.snapshot().directCursors[workspaceID] ?? 0
      guard value.entry.originSequence > cursor else { return .accepted }
      let page = ExecutionJournalPage(libraryID: libraryID, cursor: value.entry.originSequence, entries: [value.entry])
      do {
        try await store.journal.receiveWorkspace(page, workspaceID: workspaceID, localDeviceID: store.snapshot().deviceID)
        try await store.restoreExecutionProjection()
      } catch WorkspaceJournal.Failure.replayGap {
        return .resubscribe(.init(after: cursor))
      } catch {
        // Not taken: this socket keeps its questions and approvals; the next
        // start replays from the saved cursor.
        return .resubscribe(.init())
      }
      await update(.history)
    case .conversations(let value):
      guard centralHistory else { return .accepted }
      try? await store.cacheCentralConversations(value.conversations)
      await update(.history)
    case .pending(let value):
      await update(.pending(value.interactions))
    case .transcript, .capabilities, .session, .owner, .synchronized, .serverState, .unknown:
      break
    }
    return .accepted
  }

  private func conversationEvent(_ event: StreamSubscriptionEvent, conversationID: String) async -> StreamItemDisposition {
    guard conversation?.id == conversationID else { return .accepted }
    switch event {
    case .ended:
      conversation = nil
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
      case .conversations, .pending, .journal, .owner, .synchronized, .serverState, .unknown:
        break
      }
    }
    return .accepted
  }
}
