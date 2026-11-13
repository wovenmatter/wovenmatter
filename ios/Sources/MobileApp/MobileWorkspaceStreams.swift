import Foundation
import LibraryClient
import WovenMatterShared

/// Live streams to every listed Mac and Linux workspace that serves `stream.v1`
/// while the app is in the foreground: `workspace` on each, `conversation`
/// only for the open chat. The library host's stream also carries the central
/// route (its own sessions). Nothing polls an execution workspace: one without
/// a stream is read once when it connects, when a chat opens and after a command.
extension MobileModel {
  /// Whether this workspace is (or will be) reached by its stream: member
  /// mode, a known serving member, and a workspace that offers one.
  func streams(_ workspace: ExecutionWorkspace) -> Bool {
    memberMode && memberIdentity != nil && workspace.endpoint != nil && !workspace.deleted &&
      workspace.capabilities.contains(StreamProtocol.capability) && !memberUnsupportedWorkspaceIDs.contains(workspace.id) &&
      membership?.audience(for: workspace) != nil
  }

  /// The workspace whose stream carries `route`: the route's own workspace,
  /// or for "central" the library host's registered Mac. Nil for this device
  /// and for a route nothing streams.
  func streamedWorkspace(forRoute route: String) -> ExecutionWorkspace? {
    let workspace = route == "central" ? centralExecutionWorkspace : executionWorkspaces.first { $0.id == route }
    return workspace.flatMap { streams($0) ? $0 : nil }
  }

  /// Whether the central route's live view (transcript, run state, questions
  /// and approvals, capabilities, settings) arrives on the library host's stream.
  var streamsCentral: Bool { !fixture && streamedWorkspace(forRoute: "central") != nil }

  /// Whether this chat's settings (model, thinking, permission, tools, goal)
  /// arrive as `session` items on its workspace's stream. Then nothing reads
  /// them; a workspace without a stream is still read.
  func streamsSessionSettings(_ conversationID: String) -> Bool {
    guard !fixture else { return false }
    return streamedWorkspace(forRoute: executionRoute(for: conversationID)) != nil
  }

  /// Why the open chat's stream is not connected (a wrong clock, a removed
  /// member, an unreachable machine), for a quiet caption in the chat.
  var selectedStreamProblem: String? {
    guard let id = selectedConversationID, let workspace = streamedWorkspace(forRoute: executionRoute(for: id)),
          workspaceReachable[workspace.id] == false else { return nil }
    return workspaceProblems[workspace.id]
  }

  /// The chat a workspace's stream follows: the open chat when its route is
  /// that workspace, or "central" and that workspace is the library host.
  func streamedConversationID(for workspaceID: String) -> String? {
    guard let id = selectedConversationID, streamedWorkspace(forRoute: executionRoute(for: id))?.id == workspaceID else { return nil }
    return id
  }

  /// Opens, resumes or closes each workspace's stream, and points it at the open chat.
  func reconcileWorkspaceStreams() async {
    guard !fixture, let store, let memberIdentity, connectionForeground else { return }
    let wanted = Dictionary(executionWorkspaces.filter(streams).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for (id, stream) in workspaceStreams where wanted[id] == nil || wanted[id]?.endpoint != streamEndpoints[id] {
      workspaceStreams.removeValue(forKey: id); streamEndpoints.removeValue(forKey: id)
      if libraryStream?.workspaceID == id { setLibraryStream(nil) }
      await workspaceClients[id]?.setStream(nil)
      await stream.close()
    }
    let revision = membership?.membersRevision
    if revision != streamMembersRevision {
      if streamMembersRevision != nil { for stream in workspaceStreams.values { await stream.connection.membersChanged() } }
      streamMembersRevision = revision
    }
    for workspace in wanted.values where workspaceStreams[workspace.id] == nil {
      guard let endpoint = workspace.endpoint, let audience = membership?.audience(for: workspace),
            let connect = streamConnector?(workspace) ?? (try? WebSocketStreamTransport.connector(endpoint: endpoint, signer: memberIdentity.signer, audience: audience, headers: [
              "X-Woven-Protocol": String(LibraryProtocol.version), "X-Woven-Library": workspace.libraryID,
              "X-Woven-Workspace": workspace.id, "X-Woven-Device": memberIdentity.deviceID
            ])) else { continue }
      let id = workspace.id
      let stream = MobileWorkspaceStream(workspace: workspace, store: store, connection: StreamConnection(configuration: streamConfiguration, connect: connect)) { [weak self] update in
        await self?.streamUpdate(update, workspaceID: id)
      }
      workspaceStreams[id] = stream; streamEndpoints[id] = endpoint
    }
    let host = centralExecutionWorkspace?.id
    // The central route's pending list comes from the host's stream alone.
    if streamsCentral, !pending.isEmpty { pending = [] }
    for (id, stream) in workspaceStreams {
      await workspaceClients[id]?.setStream(stream.connection)
      await stream.setLibraryHost(id == host)
      // Gone to the background meanwhile: it stays closed until the foreground.
      guard connectionForeground else { return }
      await stream.start()
      await stream.open(conversationID: streamedConversationID(for: id))
    }
  }

  /// The app went to the background: every stream closes cleanly (1000).
  func stopWorkspaceStreams() {
    setLibraryStream(nil)
    let streams = Array(workspaceStreams.values)
    streamLifecycle = Task { [previous = streamLifecycle] in
      await previous?.value
      for stream in streams { await stream.stop() }
    }
  }

  /// The app is in the foreground again: every stream reconnects at once,
  /// with its subscriptions, instead of waiting for the next refresh.
  func resumeWorkspaceStreams() {
    guard connectionForeground else { return }
    let streams = Array(workspaceStreams.values)
    streamLifecycle = Task { [weak self, previous = streamLifecycle] in
      await previous?.value
      for stream in streams where self?.connectionForeground == true { await stream.start() }
    }
  }

  /// Wake or a network path change: try now instead of waiting out the backoff.
  func reconnectWorkspaceStreams() {
    for stream in workspaceStreams.values { Task { await stream.connection.connectNow() } }
  }

  /// Pairing changed: no stream outlives its connection generation.
  func closeWorkspaceStreams() {
    setLibraryStream(nil)
    let streams = workspaceStreams
    workspaceStreams = [:]; streamEndpoints = [:]; streamMembersRevision = nil
    for stream in streams.values { Task { await stream.close() } }
  }

  /// The open chat's subscription follows the selection.
  func openStreamedConversation(_ workspaceID: String) async {
    await workspaceStreams[workspaceID]?.open(conversationID: streamedConversationID(for: workspaceID))
  }

  /// The selection changed: each stream follows the open chat (and leaves the previous one).
  func followSelectedConversation() async {
    for id in workspaceStreams.keys { await openStreamedConversation(id) }
  }

  private func streamUpdate(_ update: MobileWorkspaceStream.Update, workspaceID id: String) async {
    guard workspaceStreams[id] != nil else { return }
    switch update {
    case .state(let state):
      switch state {
      case .open:
        workspaceReachable[id] = true; workspaceProblems.removeValue(forKey: id)
        await refreshStreamedWorkspace(id)
        if id == centralExecutionWorkspace?.id { await recoverCentralReceipts() }
      case .waiting(let error):
        workspaceReachable[id] = false; workspaceProblems[id] = streamProblem(error, workspaceID: id)
      case .memberRemoved:
        workspaceReachable[id] = false; workspaceProblems[id] = streamProblem(.memberRemoved, workspaceID: id)
      case .idle, .connecting: break
      }
      // A closed stream announces nothing: the library timer returns until
      // the next `library` item on a reconnected stream.
      if case .open = state {} else if libraryStream?.workspaceID == id { setLibraryStream(nil) }
    case .library(let cursor, let server):
      await libraryChanged(cursor: cursor, serverDeviceID: server, workspaceID: id)
    case .pending(let interactions):
      remotePending[id] = interactions
    case .capabilities(let conversationID, let value):
      sessionCapabilities[conversationID] = value
    case .session(let conversationID, let value):
      if streamedSessionSettings[conversationID] != value { streamedSessionSettings[conversationID] = value }
    case .history, .transcript, .receipts:
      scheduleStreamReload()
    case .conversationEnded(let conversationID, _):
      // Not served live (a chat its server does not run): read it once.
      // Not from the subscription's handler: the socket's next frame waits on it.
      guard conversationID == selectedConversationID else { return }
      Task { await self.readConversationOnce(conversationID) }
    }
  }

  /// Central commands whose reply was lost are resolved by receipt once per
  /// connection to the host, never on a timer.
  func recoverCentralReceipts() async {
    guard let engine else { return }
    do { try await engine.recoverCommandReceipts(); await reload() } catch { /* The next connection asks again. */ }
  }

  private func streamProblem(_ error: StreamConnectionError?, workspaceID: String) -> String {
    let name = executionWorkspaces.first { $0.id == workspaceID }?.name ?? "This workspace"
    switch error {
    case .memberTimeStale: return "This device's clock is wrong. Turn on Set Automatically in Settings › General › Date & Time."
    case .unauthorized: return "\(name) doesn’t recognize this device yet. It will once your devices synchronize."
    case .memberRemoved: return "\(name) no longer lists this device as a member."
    case .protocolUnsupported: return "Update Woven Matter on every device."
    case .refused(_, .some(StreamProtocol.ErrorCode.unavailable.rawValue), _): return "\(name) isn’t ready yet. Woven Matter reconnects automatically."
    case nil, .disconnected, .timedOut, .notConnected: return "\(name) isn’t connected. Woven Matter reconnects automatically."
    case let error?: return error.localizedDescription
    }
  }

  /// What the stream does not carry: the agent list, pinned offline chats.
  /// Read once per connection, and when the New Chat menu asks again.
  func refreshStreamedWorkspace(_ workspaceID: String) async {
    guard let client = workspaceClients[workspaceID] else { return }
    do {
      let discovered = try await client.providers()
      guard workspaceClients[workspaceID] === client else { return }
      workspaceProviders[workspaceID] = discovered
      for id in state.pinnedTranscriptIDs ?? [] where executionOwner(of: id) == workspaceID && (state.transcripts[id] == nil || state.transcripts[id]?.olderCursor != nil) {
        do { try await downloadOfflineConversation(id) }
        catch { offlineProblems["chat:" + id] = error.localizedDescription }
      }
      rememberAgentCatalog()
      if providerID.isEmpty { providerID = availableExecutionProviders.first { $0.available && $0.canStart }?.id ?? "" }
      await reload()
    } catch { workspaceProblems[workspaceID] = error.localizedDescription }
  }

  /// Pushed changes reach the views at most every 50 ms.
  private func scheduleStreamReload() {
    guard !streamReloadScheduled else { return }
    streamReloadScheduled = true
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(50))
      guard let self else { return }
      self.streamReloadScheduled = false
      if let store = self.store { self.conversationWorkspaceIDs.merge(await store.journal.snapshot().conversationWorkspaceIDs) { _, new in new } }
      await self.reload()
    }
  }
}
