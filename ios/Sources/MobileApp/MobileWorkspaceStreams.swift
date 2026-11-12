import Foundation
import LibraryClient
import WovenMatterShared

/// Live streams to every listed Mac and Linux workspace that serves `stream.v1`
/// while the app is in the foreground: `workspace` on each, `conversation`
/// only for the open chat. Nothing polls those workspaces; a workspace without
/// a stream keeps its scheduled refresh.
extension MobileModel {
  /// Whether this workspace is (or will be) reached by its stream: member
  /// mode, a known serving member, and a workspace that offers one.
  func streams(_ workspace: ExecutionWorkspace) -> Bool {
    memberMode && memberIdentity != nil && workspace.endpoint != nil && !workspace.deleted &&
      workspace.capabilities.contains(StreamProtocol.capability) && !memberUnsupportedWorkspaceIDs.contains(workspace.id) &&
      membership?.audience(for: workspace) != nil
  }

  /// Whether this chat's settings (model, thinking, permission, tools, goal)
  /// arrive as `session` items on its workspace's stream. Then nothing reads
  /// them; a workspace without a stream is still read.
  func streamsSessionSettings(_ conversationID: String) -> Bool {
    guard !fixture else { return false }
    let owner = executionRoute(for: conversationID)
    return executionWorkspaces.first { $0.id == owner }.map(streams) ?? false
  }

  /// Opens, resumes or closes each workspace's stream, and points it at the open chat.
  func reconcileWorkspaceStreams() async {
    guard !fixture, let store, let memberIdentity, connectionForeground else { return }
    let wanted = Dictionary(executionWorkspaces.filter(streams).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for (id, stream) in workspaceStreams where wanted[id] == nil || wanted[id]?.endpoint != streamEndpoints[id] {
      workspaceStreams.removeValue(forKey: id); streamEndpoints.removeValue(forKey: id)
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
            let connect = try? WebSocketStreamTransport.connector(endpoint: endpoint, signer: memberIdentity.signer, audience: audience, headers: [
              "X-Woven-Protocol": String(LibraryProtocol.version), "X-Woven-Library": workspace.libraryID,
              "X-Woven-Workspace": workspace.id, "X-Woven-Device": memberIdentity.deviceID
            ]) else { continue }
      let id = workspace.id
      let stream = MobileWorkspaceStream(workspace: workspace, store: store, connection: StreamConnection(connect: connect)) { [weak self] update in
        await self?.streamUpdate(update, workspaceID: id)
      }
      workspaceStreams[id] = stream; streamEndpoints[id] = endpoint
    }
    for (id, stream) in workspaceStreams {
      await workspaceClients[id]?.setStream(stream.connection)
      await stream.start()
      await stream.open(conversationID: selectedExecutionWorkspaceID == id ? selectedConversationID : nil)
    }
  }

  /// The app went to the background: every stream closes cleanly.
  func stopWorkspaceStreams() {
    for stream in workspaceStreams.values { Task { await stream.stop() } }
  }

  /// Wake or a network path change: try now instead of waiting out the backoff.
  func reconnectWorkspaceStreams() {
    for stream in workspaceStreams.values { Task { await stream.connection.connectNow() } }
  }

  /// Pairing changed: no stream outlives its connection generation.
  func closeWorkspaceStreams() {
    let streams = workspaceStreams
    workspaceStreams = [:]; streamEndpoints = [:]; streamMembersRevision = nil
    for stream in streams.values { Task { await stream.close() } }
  }

  /// The open chat's subscription follows the selection.
  func openStreamedConversation(_ workspaceID: String) async {
    await workspaceStreams[workspaceID]?.open(conversationID: selectedExecutionWorkspaceID == workspaceID ? selectedConversationID : nil)
  }

  private func streamUpdate(_ update: MobileWorkspaceStream.Update, workspaceID id: String) async {
    guard workspaceStreams[id] != nil else { return }
    switch update {
    case .state(let state):
      switch state {
      case .open:
        workspaceReachable[id] = true; workspaceProblems.removeValue(forKey: id); workspaceRetryCount[id] = 0
        await refreshStreamedWorkspace(id)
      case .waiting(let error):
        workspaceReachable[id] = false; workspaceProblems[id] = streamProblem(error, workspaceID: id)
      case .memberRemoved:
        workspaceReachable[id] = false; workspaceProblems[id] = streamProblem(.memberRemoved, workspaceID: id)
      case .idle, .connecting: break
      }
    case .pending(let interactions):
      remotePending[id] = interactions
    case .capabilities(let conversationID, let value):
      sessionCapabilities[conversationID] = value
    case .session(let conversationID, let value):
      if streamedSessionSettings[conversationID] != value { streamedSessionSettings[conversationID] = value }
    case .history, .transcript, .receipts:
      scheduleStreamReload()
    }
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
