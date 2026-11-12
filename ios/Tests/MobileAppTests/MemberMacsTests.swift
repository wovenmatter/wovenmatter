import XCTest
import LibraryClient
import WovenMatterShared
@testable import WovenMatterMobileApp

/// The library host's mobile API: counts agent list requests and can go offline.
private actor CountingLibrary: OfflineLibraryTransport {
  var providerRequests = 0
  var offline = false
  var codexReady = false
  func setOffline(_ value: Bool) { offline = value }
  func setCodexReady(_ value: Bool) { codexReady = value }
  func workspaceIdentity() async throws -> String {
    if offline { throw MobileConnectionError.offline }
    return "library-a"
  }
  func snapshot() async throws -> LibrarySnapshot {
    if offline { throw MobileConnectionError.offline }
    return .init(workspaceID: "library-a", cursor: 1)
  }
  func changes(after: Int64) async throws -> LibraryChangePage {
    if offline { throw MobileConnectionError.offline }
    return .init(workspaceID: "library-a", cursor: 1)
  }
  func providers() async throws -> [HarnessCapabilities] {
    providerRequests += 1
    return [.init(id: "local:default_agent", runtimeKind: "default_agent", displayName: "Pi Durable", available: true),
            .init(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: codexReady, canStart: codexReady,
                  unavailableReason: codexReady ? nil : "Enable and configure this agent on the Mac.")]
  }
  func pending() async throws -> [PendingInteraction] { [] }
  func transcript(_ id: String) async throws -> LibraryTranscript { .init(conversationID: id) }
  func receipt(_ id: String) async throws -> LibraryCommandReceipt? { nil }
}

/// A Mac workspace that holds each message until the test releases it.
private actor SlowWorkspace: ExecutionWorkspaceTransport {
  let workspace: ExecutionWorkspace
  var transcriptValue: LibraryTranscript
  var held: CheckedContinuation<Void, Never>?
  var receipts: [String: LibraryCommandReceipt] = [:]
  init(_ workspace: ExecutionWorkspace, transcript: LibraryTranscript) { self.workspace = workspace; transcriptValue = transcript }
  var holding: Bool { held != nil }
  func release() { held?.resume(); held = nil }
  func identity() async throws -> ExecutionWorkspace { workspace }
  func providers() async throws -> [HarnessCapabilities] { [.init(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)] }
  func pending() async throws -> [PendingInteraction] { [] }
  func capabilities(_ id: String) async throws -> HarnessCapabilities { .init(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true) }
  func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt {
    await withCheckedContinuation { held = $0 }
    let runID = "run-" + command.commandID
    transcriptValue.messages.append(.init(id: "server-" + command.commandID, conversationID: command.conversationID ?? "",
      runID: runID, role: "user", content: command.text ?? ""))
    transcriptValue.activeRunID = runID
    let receipt = LibraryCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .accepted,
      conversationID: command.conversationID, runID: runID)
    receipts[command.commandID] = receipt
    return receipt
  }
  func receipt(_ id: String) async throws -> LibraryCommandReceipt? { receipts[id] }
  func events(after: Int64) async throws -> ExecutionJournalPage { .init(libraryID: workspace.libraryID, cursor: after) }
  func conversations() async throws -> [LibraryConversation] { [] }
  func transcript(_ id: String) async throws -> LibraryTranscript { transcriptValue }
}

final class MemberMacsTests: XCTestCase {
  private let airHost = "e775f2b2-1e79-4bc2-b723-39b3fab2d9c5", miniHost = "7c072eba-eb7c-490b-9434-fb710c7f828f"
  private var air: ExecutionWorkspace {
    .init(id: "0446435c-8e64-440e-b9eb-3c5dadb27e04", libraryID: "library-a", ownerDeviceID: airHost, kind: .mac,
          name: "James’s MacBook Air (Dev) · worktrees-b8e80bfb02", endpoint: URL(string: "https://air.tail1.ts.net/wovenmatter"),
          capabilities: ["execution.v1", "history.central.v1"], executionDeviceID: airHost)
  }
  private var mini: ExecutionWorkspace {
    .init(id: "b03923c3-89d1-4f29-910a-b7e3ce7b586c", libraryID: "library-b", ownerDeviceID: miniHost, kind: .mac,
          name: "James’s Mac Mini (Dev) · woven-everywhere", endpoint: URL(string: "https://mini.tail1.ts.net/wovenmatter"),
          capabilities: ["execution.v1", "history.central.v1"], executionDeviceID: miniHost)
  }

  /// Both Dev Macs advertise central history. The central list is the
  /// library host's (the Air's), so the Air appears once and the Mini under
  /// its own name; Quick Chat leads. A Linux workspace is listed by the same
  /// paired-and-reachable rule once its own connection answers, under its
  /// registry name, even though the library host registered it.
  @MainActor func testEachMacOnceUnderItsNameAndLinuxOnceReachable() {
    let model = MobileModel()
    let linux = ExecutionWorkspace(id: "0fa3b77c-1819-411f-804f-b183d86e2dcd", libraryID: "library-a", ownerDeviceID: airHost,
      kind: .linux, name: "Workstation (Dev)", capabilities: ["execution.v1", "inference.v1"])
    model.executionWorkspaces = [mini, air, linux]
    var membership = MobileMembershipState(deviceID: model.state.deviceID, pairedEndpoint: air.endpoint!, pairedHostDeviceID: airHost)
    membership.currentHost = .init(deviceID: airHost, kind: "mac", name: air.name, endpoint: air.endpoint!)
    model.membership = membership
    let pi = HarnessCapabilities(id: "local:default_agent", runtimeKind: "default_agent", displayName: "Pi Durable", available: true)
    let codex = HarnessCapabilities(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true)
    model.providers = [pi, .init(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: false, canStart: false)]
    model.workspaceProviders = [air.id: [pi, codex], mini.id: [pi, codex], linux.id: [pi]]
    model.workspaceReachable = [air.id: true, mini.id: true]
    model.online = true
    XCTAssertEqual(model.centralExecutionWorkspace?.id, air.id)
    XCTAssertEqual(model.launcherGroups.map(\.name), [model.deviceWorkspaceName, air.name, mini.name])
    XCTAssertEqual(model.chatLauncherGroups.map(\.id), ["local", "central", mini.id])
    XCTAssertTrue(model.launcherGroups[1].agents.allSatisfy(\.isAvailable))
    XCTAssertTrue(model.launcherGroups[2].agents.allSatisfy { $0.workspaceID == mini.id })

    // Registered without an endpoint and not reachable: not listed.
    XCTAssertFalse(model.workspaceIsActive(linux))
    // Adopted: reachable through its own endpoint.
    model.workspaceReachable[linux.id] = true
    XCTAssertEqual(model.chatLauncherGroups.map(\.name), [model.deviceWorkspaceName, air.name, mini.name, linux.name])
    XCTAssertEqual(model.chatLauncherGroups.last?.agents.map(\.workspaceID), [linux.id])
  }

  /// The library host's agent list is fetched again when the New Chat menu
  /// opens and on reconnect, so an agent set up since then is not left as
  /// needing setup.
  @MainActor func testCentralAgentListRefreshesWhenNewChatOpensAndOnReconnect() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library-a")
    let library = CountingLibrary()
    let model = MobileModel(store: store, transport: library)
    await model.reload()
    await model.refresh()
    var requests = await library.providerRequests
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(model.providers.first { $0.id == "local:codex" }?.available, false)
    await model.refresh()
    requests = await library.providerRequests
    XCTAssertEqual(requests, 1, "Routine refreshes reuse a fresh list")

    await library.setCodexReady(true)
    await model.refreshAgentAvailability()
    requests = await library.providerRequests
    XCTAssertEqual(requests, 2)
    XCTAssertEqual(model.providers.first { $0.id == "local:codex" }?.available, true)

    await library.setOffline(true)
    await model.refresh()
    XCTAssertFalse(model.online)
    await library.setOffline(false)
    await model.refresh()
    requests = await library.providerRequests
    XCTAssertEqual(requests, 3, "Reconnecting asks the host for its current agents")
  }

  /// A message to a Mac session shows at once with progress while the Mac
  /// takes time to accept it, then appears exactly once from the Mac.
  @MainActor func testMessageToAMacSessionShowsAtOnceAndOnceAfterItArrives() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.apply(LibrarySnapshot(workspaceID: "library-a", cursor: 0, conversations: [
      .init(id: "chat", title: "Hello", providerID: "pi", runtimeKind: "pi", workspaceID: air.id)]))
    let earlier = LibraryTranscript(conversationID: "chat", messages: [
      .init(id: "hello", conversationID: "chat", runID: "run-1", role: "user", content: "Hey"),
      .init(id: "reply", conversationID: "chat", runID: "run-1", role: "assistant", content: "Hi", status: "completed")])
    try await store.cache(earlier)
    try await store.journal.upsertWorkspace(air)
    let endpoint = SlowWorkspace(air, transcript: earlier)
    let model = MobileModel(store: store, transport: CountingLibrary())
    await model.reload(); model.online = false
    model.executionWorkspaces = [air]
    model.workspaceClients[air.id] = WorkspaceClient(store: store, workspaceID: air.id, transport: endpoint)
    model.workspaceReachable[air.id] = true
    model.workspaceProviders[air.id] = try await endpoint.providers()
    model.conversationWorkspaceIDs["chat"] = air.id
    model.selectedConversationID = "chat"; model.providerID = "pi"
    model.composer = "Next step?"
    await model.flushLocalWrites()

    let sending = Task { await model.send() }
    for _ in 0..<500 where !(await endpoint.holding) { try await Task.sleep(for: .milliseconds(10)) }
    let holding = await endpoint.holding
    XCTAssertTrue(holding)
    XCTAssertEqual(model.composer, "", "The composer clears as the message is shown")
    XCTAssertEqual(model.displayedTranscript?.messages.map(\.content), ["Hey", "Hi", "Next step?"])
    XCTAssertEqual(model.sendProgress, "Sending to " + air.name + "…")
    let saved = await store.snapshot().chatDrafts["chat"]?.text
    XCTAssertEqual(saved, "Next step?", "The saved draft stays until the Mac accepts it")

    await endpoint.release()
    await sending.value
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.displayedTranscript?.messages.filter { $0.content == "Next step?" }.map(\.id).count, 1)
    XCTAssertEqual(model.displayedTranscript?.messages.last?.id.hasPrefix("server-"), true, "The Mac's copy replaces the local one")
    XCTAssertNil(model.sendProgress, "The turn is running on the Mac")
    XCTAssertTrue(model.pendingSends.isEmpty)
    await model.flushLocalWrites()
    let cleared = await store.snapshot().chatDrafts["chat"]?.text ?? ""
    XCTAssertEqual(cleared, "")
  }
}
