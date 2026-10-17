import XCTest
import CompanionClient
import CompanionInference
import WovenMatterCompanion
@testable import WovenMatterMobileApp

private actor ExecutionTestLibrary: CompanionTransport {
  func workspaceIdentity() async throws -> String { throw MobileConnectionError.offline }
  func snapshot() async throws -> CompanionSnapshot { throw MobileConnectionError.offline }
  func changes(after: Int64) async throws -> CompanionChangePage { throw MobileConnectionError.offline }
  func mutate(_ mutation: CompanionMutation) async throws -> CompanionMutationResult { throw MobileConnectionError.offline }
  func note(_ id: String) async throws -> CompanionNote { throw MobileConnectionError.offline }
  func providers() async throws -> [CompanionProvider] { throw MobileConnectionError.offline }
  func pending() async throws -> [CompanionPendingInteraction] { throw MobileConnectionError.offline }
  func transcript(_ id: String) async throws -> CompanionTranscript { throw MobileConnectionError.offline }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt { XCTFail("Direct execution must not use the central library"); throw MobileConnectionError.offline }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? { throw MobileConnectionError.offline }
}

private actor ExecutionTestWorkspace: ExecutionWorkspaceTransport {
  let workspace: CompanionExecutionWorkspace
  var commands: [CompanionCommand] = []
  var receipts: [String: CompanionCommandReceipt] = [:]
  var dropSendAcknowledgement = true
  var dropCreateAcknowledgement = false
  func dropNextCreateAcknowledgement() { dropCreateAcknowledgement = true }
  init(_ workspace: CompanionExecutionWorkspace) { self.workspace = workspace }
  func identity() async throws -> CompanionExecutionWorkspace { workspace }
  func providers() async throws -> [CompanionProvider] { [.init(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)] }
  func pending() async throws -> [CompanionPendingInteraction] { [] }
  func capabilities(_ id: String) async throws -> CompanionProvider { .init(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true) }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt {
    commands.append(command)
    let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID)
    receipts[command.commandID] = receipt
    if command.kind == .createSession && dropCreateAcknowledgement { dropCreateAcknowledgement = false; throw MobileConnectionError.offline }
    if command.kind == .send && dropSendAcknowledgement { dropSendAcknowledgement = false; throw MobileConnectionError.offline }
    return receipt
  }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? { receipts[id] }
  func events(after: Int64) async throws -> CompanionJournalPage { .init(libraryID: workspace.libraryID, cursor: after) }
  func conversations() async throws -> [CompanionConversation] { [] }
  func transcript(_ id: String) async throws -> CompanionTranscript { .init(conversationID: id) }
  func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult {
    guard case .exportConversation = request else { throw MobileConnectionError.invalidResponse }
    return .file(.init(name: "conversation.md", mimeType: "text/markdown", data: Data("direct export".utf8)))
  }
}

final class ExecutionRoutingTests: XCTestCase {
  @MainActor func testDeviceGoalsPersistAndRouteWithoutStartingInference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    model.executionDirectory = root.appendingPathComponent("execution")
    let id = UUID().uuidString.lowercased()
    let descriptor = InferenceModel(id: "gpt-test", name: "Test model", provider: "openai", api: "openai-responses", baseUrl: "https://api.openai.com/v1", reasoning: true)
    model.executionRecords[id] = DeviceConversationRecord(id: id, title: "Goal chat", connectionID: "fixture", modelJSON: try descriptor.descriptorJSON(), status: "ready", updatedAt: "")
    let set = await model.perform(.goal(id: id, mutation: .set(objective: "Verify device work", tokenBudget: nil, turnBudget: 2)))
    XCTAssertTrue(set)
    guard case .session(let settings) = try await model.workspace(.session(id: id)) else { XCTFail("Missing owner status"); return }
    let goal = try XCTUnwrap(settings.goal)
    XCTAssertEqual(goal.sessionID, id)
    XCTAssertTrue(model.localRuntimes.isEmpty)
    let requestID = UUID().uuidString
    let arguments = ["goals", "checkpoint", "--id", goal.id, "--evidence", "Verified a change", "--request-id", requestID]
    let first = try await model.performDeviceCLI(arguments: arguments, conversationID: id, requestID: requestID)
    let retry = try await model.performDeviceCLI(arguments: arguments, conversationID: id, requestID: requestID)
    XCTAssertEqual(first, retry)
    XCTAssertEqual(model.executionRecords[id]?.goalLedger?.goal?.progressRevision, 1)
    XCTAssertTrue(model.localPending.isEmpty, "Goal evidence does not require approval for an external effect")
    let pause = await model.perform(.goal(id: id, mutation: .pause(id: goal.id)))
    XCTAssertTrue(pause)
    let resume = await model.perform(.goal(id: id, mutation: .resume(id: goal.id)))
    XCTAssertTrue(resume)
    try await model.configureDeviceChat(tools: [], conversationID: id)
    XCTAssertEqual(model.executionRecords[id]?.goalLedger?.goal?.status, .active)
    let reopened = CompanionModel(store: store, transport: ExecutionTestLibrary())
    reopened.executionDirectory = model.executionDirectory
    try await reopened.loadExecutionConfiguration()
    XCTAssertEqual(reopened.executionRecords[id]?.goalLedger?.goal?.status, .paused)
    XCTAssertTrue(reopened.localRuntimes.isEmpty)
    let clear = await reopened.perform(.goal(id: id, mutation: .clear(id: goal.id)))
    XCTAssertTrue(clear)
    XCTAssertNil(reopened.executionRecords[id]?.goalLedger?.goal)
  }


  @MainActor func testFallbackRouteControlsTheChatWithoutChangingHistoryOwnership() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library")
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    model.state = await store.snapshot()
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library",
      ownerDeviceID: "owner", kind: .mac, name: "Mac", capabilities: ["history.central.v1"])
    try await store.journal.bind(libraryID: "library")
    try await store.journal.upsertWorkspace(workspace, pending: false)
    let direct = ExecutionTestWorkspace(workspace)
    model.workspaceClients[workspace.id] = WorkspaceClient(store: store, workspaceID: workspace.id, transport: direct)
    let id = UUID().uuidString.lowercased(), runID = UUID().uuidString.lowercased()
    model.selectedConversationID = id
    model.selectedConversationRoute = (id, workspace.id)
    model.workspaceReachable[workspace.id] = true; model.online = false
    XCTAssertEqual(model.executionOwner(of: id), "central")
    XCTAssertTrue(model.executionAvailable(for: id))
    await model.submitExecutionCommand(.init(deviceID: model.state.deviceID, kind: .stop, conversationID: id, runID: runID))
    await model.respond(.init(id: "approval", conversationID: id, runID: runID, kind: .approval, title: "Approve"), response: .init(optionID: "allow"))
    let configured = await model.perform(.configureSession(id: id, model: "model", thinking: "high", permission: nil))
    XCTAssertTrue(configured)
    let exported = try await model.workspace(.exportConversation(id: id, format: "markdown"))
    XCTAssertEqual(exported, .file(.init(name: "conversation.md", mimeType: "text/markdown", data: Data("direct export".utf8))))
    let commands = await direct.commands
    XCTAssertEqual(commands.map(\.kind), [.stop, .respond, .workspace])
    XCTAssertTrue(commands.allSatisfy { $0.workspaceID == workspace.id && $0.conversationID == id })
    XCTAssertEqual(model.executionOwner(of: id), "central")
    XCTAssertEqual(model.executionRoute(for: "another-chat"), "central")
    // The reverse fallback uses central transport while preserving the direct owner.
    model.conversationWorkspaceIDs[id] = workspace.id
    model.selectedConversationRoute = (id, "central"); model.online = true
    XCTAssertEqual(model.executionOwner(of: id), workspace.id)
    XCTAssertEqual(model.executionRoute(for: id), "central")
    XCTAssertTrue(model.executionAvailable(for: id))
  }

  @MainActor func testFolderAndPendingRequestEntryPointsResolveOnlyTheSameAgent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library")
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    model.state = await store.snapshot()
    let central = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library",
      ownerDeviceID: "central-owner", kind: .mac, name: "Central", capabilities: ["history.central.v1"])
    let other = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library",
      ownerDeviceID: "other-owner", kind: .mac, name: "Another Mac")
    try await store.journal.bind(libraryID: "library")
    for workspace in [central, other] { try await store.journal.upsertWorkspace(workspace, pending: false) }
    let provider = CompanionProvider(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true)
    model.executionWorkspaces = [other, central]
    model.providers = [provider]; model.workspaceProviders = [central.id: [provider], other.id: [provider]]
    model.workspaceReachable = [central.id: true, other.id: true]; model.online = false
    let id = UUID().uuidString.lowercased()
    model.state.conversations[id] = .init(id: id, title: "Existing", providerID: provider.id, runtimeKind: provider.runtimeKind)
    // Folders and Pending Requests both select a conversation without an explicit route.
    await model.selectConversation(id)
    XCTAssertEqual(model.selectedExecutionWorkspaceID, central.id)
    XCTAssertEqual(model.executionOwner(of: id), "central")
    model.workspaceReachable[central.id] = false
    XCTAssertEqual(model.preferredExecutionRoute(for: id), "central", "An unrelated Mac cannot substitute for this agent")
    model.conversationWorkspaceIDs[id] = central.id; model.online = true
    XCTAssertEqual(model.preferredExecutionRoute(for: id), "central")
    model.conversationWorkspaceIDs[id] = other.id
    XCTAssertEqual(model.preferredExecutionRoute(for: id), other.id)
    model.workspaceReachable[other.id] = false
    XCTAssertEqual(model.preferredExecutionRoute(for: id), other.id, "Central access cannot substitute for another Mac's own session")
  }

  @MainActor func testHomeLauncherKeepsExactWorkspaceAndDimsDisconnectedAgents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = CompanionModel(store: try MobileStore(file: root.appendingPathComponent("library.json")), transport: ExecutionTestLibrary())
    model.executionDirectory = root.appendingPathComponent("execution")
    let connected = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "owner", kind: .linux, name: "Connected")
    let disconnected = CompanionExecutionWorkspace(id: "disconnected", libraryID: "library", ownerDeviceID: "owner", kind: .linux, name: "Disconnected")
    model.executionWorkspaces = [connected, disconnected]
    model.workspaceReachable = [connected.id: true, disconnected.id: false]
    let agent = CompanionProvider(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)
    model.workspaceProviders = [connected.id: [agent], disconnected.id: [agent]]
    model.workspaceClients[connected.id] = WorkspaceClient(store: try XCTUnwrap(model.store), workspaceID: connected.id, transport: ExecutionTestWorkspace(connected))
    model.providers = [agent]; model.online = false; model.selectedConversationID = "existing-chat"
    let launchers = model.launcherAgents
    XCTAssertEqual(launchers.map(\.workspaceID), ["local", "central", connected.id, disconnected.id])
    XCTAssertFalse(try XCTUnwrap(launchers.last).isAvailable)
    await model.launchAgent(try XCTUnwrap(launchers.last))
    XCTAssertEqual(model.selectedConversationID, "existing-chat")
    await model.launchAgent(try XCTUnwrap(launchers.first { $0.workspaceID == connected.id }))
    XCTAssertEqual(model.tab, .chat)
    XCTAssertNotNil(model.selectedConversationID)
    XCTAssertEqual(model.selectedExecutionWorkspaceID, connected.id)
    XCTAssertEqual(model.providerID, agent.id)
    await model.launchAgent(try XCTUnwrap(launchers.first))
    XCTAssertEqual(model.selectedExecutionWorkspaceID, "local")
    XCTAssertEqual(model.providerID, "pi-durable-device")
    model.online = true
    model.providers = [agent, .init(id: "remote:" + connected.id + ":pi", runtimeKind: "pi", displayName: "Pi Durable", routeName: connected.name, available: true)]
    XCTAssertEqual(model.launcherAgents.filter { $0.workspaceID == "central" }.map(\.providerID), [agent.id])
    XCTAssertEqual(model.launcherAgents.filter { $0.workspaceID == connected.id }.count, 1)
  }

  @MainActor func testNewChatChooserPreservesCurrentConversationUntilAgentSelection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = CompanionModel(store: try MobileStore(file: root.appendingPathComponent("library.json")), transport: ExecutionTestLibrary())
    model.selectedConversationID = "current"
    model.composer = "Unsent work"
    model.newChat(referencing: "reference-note")
    XCTAssertTrue(model.chatChooserPresented)
    XCTAssertEqual(model.selectedConversationID, "current")
    XCTAssertEqual(model.composer, "Unsent work")
    XCTAssertNil(model.referencedNoteID)
    XCTAssertEqual(model.newChatNoteID, "reference-note")
  }

  @MainActor func testChooserRecoversCreationWithoutSendingOrDuplicatingSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    let workspace = CompanionExecutionWorkspace(id: "direct", libraryID: "library", ownerDeviceID: "owner", kind: .linux, name: "Linux")
    let endpoint = ExecutionTestWorkspace(workspace)
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    model.executionDirectory = root.appendingPathComponent("execution")
    model.executionWorkspaces = [workspace]; model.workspaceReachable[workspace.id] = true
    model.workspaceProviders[workspace.id] = try await endpoint.providers()
    model.workspaceClients[workspace.id] = WorkspaceClient(store: store, workspaceID: workspace.id, transport: endpoint)
    model.newChat()
    await endpoint.dropNextCreateAcknowledgement()
    let agent = try XCTUnwrap(model.launcherAgents.first { $0.workspaceID == workspace.id })
    await model.startNewChat(with: agent)
    XCTAssertTrue(model.chatChooserPresented)
    XCTAssertNotNil(model.chatSetupProblem)
    // Background polling may discover the receipt before the user retries the chooser.
    try await model.workspaceClients[workspace.id]?.refresh()
    await model.startNewChat(with: agent)
    XCTAssertFalse(model.chatChooserPresented)
    XCTAssertNotNil(model.selectedConversationID)
    XCTAssertEqual(model.selectedExecutionWorkspaceID, workspace.id)
    let commands = await endpoint.commands
    XCTAssertEqual(commands.count, 1)
    XCTAssertEqual(commands.first?.kind, .createSession)
    XCTAssertEqual(commands.first?.workspaceID, workspace.id)
    await model.refreshExecutionWorkspaces()
    XCTAssertEqual(model.selectedExecutionWorkspaceID, workspace.id, "Ownership survives polling before history arrives")
    await model.newChatWithCurrentAgent()
    let nextCommands = await endpoint.commands
    XCTAssertEqual(nextCommands.count, 2)
    XCTAssertNotEqual(nextCommands.first?.conversationID, nextCommands.last?.conversationID)
    XCTAssertEqual(nextCommands.last?.providerID, agent.providerID)
  }

  @MainActor func testComposerConfigurationStaysWithItsConversationAndRejectsBusyChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = CompanionModel(store: try MobileStore(file: root.appendingPathComponent("library.json")), transport: ExecutionTestLibrary())
    model.executionDirectory = root.appendingPathComponent("execution")
    let descriptor = InferenceModel(id: "gpt-test", name: "Test model", provider: "openai", api: "openai-responses", baseUrl: "https://api.openai.com/v1", reasoning: true)
    let connection = InferenceConnection(id: "account", name: "Saved account", provider: "openai", route: .direct, modelID: descriptor.id, selectedModel: descriptor)
    model.inferenceConnections = [connection]; model.inferenceConnectionID = connection.id
    await model.startNewChat(with: try XCTUnwrap(model.launcherAgents.first))
    let created = try XCTUnwrap(model.selectedConversationID)
    XCTAssertEqual(model.executionRecords[created]?.status, "ready")
    XCTAssertEqual(model.executionRecords[created]?.thinkingLevel, "medium", "New chats use the middle supported non-Off level")
    XCTAssertTrue(model.localRuntimes.isEmpty, "Choosing an agent must not start inference")
    XCTAssertEqual(model.state.transcripts[created]?.messages, [])
    let record = DeviceConversationRecord(id: "first", title: "First", connectionID: connection.id, connection: connection, modelJSON: try descriptor.descriptorJSON(), status: "ready", updatedAt: "")
    var other = record; other.id = "second"
    model.executionRecords = [record.id: record, other.id: other]; model.selectedConversationID = record.id
    try await model.configureDeviceChat(thinking: "high", permission: .full, tools: ["read_note"])
    XCTAssertEqual(model.executionRecords[record.id]?.thinkingLevel, "high")
    XCTAssertEqual(model.executionRecords[record.id]?.enabledTools, ["read_note"])
    XCTAssertEqual(model.executionRecords[other.id], other)
    XCTAssertEqual(model.inferenceConnections, [connection])
    let saved = try JSONDecoder().decode(DeviceExecutionPreferences.self, from: Data(contentsOf: root.appendingPathComponent("execution/preferences.json")))
    XCTAssertEqual(saved.conversations[record.id]?.thinkingLevel, "high")
    XCTAssertEqual(saved.conversations[record.id]?.permissionMode, .full)
    guard case .session(let settings) = try await model.readDeviceWorkspace(.session(id: record.id)) else { return XCTFail("Missing settings") }
    XCTAssertEqual(settings.permission, "full")
    XCTAssertEqual(settings.permissions.map(\.id), ["ask", "full"])
    let changed = await model.performDeviceAction(.configureSession(id: record.id, model: nil, thinking: nil, permission: "ask"))
    XCTAssertTrue(changed)
    XCTAssertEqual(model.executionRecords[record.id]?.permissionMode, .ask)
    model.executionRecords[record.id]?.status = "running"
    do { try await model.configureDeviceChat(thinking: "low"); XCTFail("An active run must retain its configuration") }
    catch { XCTAssertEqual(model.executionRecords[record.id]?.thinkingLevel, "high") }
  }

  @MainActor func testDeviceDefaultsPersistWithoutChangingExistingConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    model.executionDirectory = root.appendingPathComponent("execution")
    let descriptor = InferenceModel(id: "existing-model", name: "Saved model", provider: "openai", api: "openai-responses", baseUrl: "https://api.openai.com/v1", reasoning: true)
    let connection = InferenceConnection(id: "saved", name: "Saved key", provider: "openai", route: .direct, modelID: descriptor.id, selectedModel: descriptor)
    model.inferenceConnections = [connection]
    let record = DeviceConversationRecord(id: "existing", title: "Existing", enabledTools: ["read_note"], additionalInstructions: "Original instructions",
      connectionID: connection.id, connection: connection, modelJSON: "{}", status: "ready", updatedAt: "")
    model.executionRecords = [record.id: record]; model.selectedConversationID = record.id
    let defaults = DeviceAgentDefaults(thinkingLevel: "high", instructions: "New conversations only", enabledTools: [])
    try model.saveDeviceAgentDefaults(defaults, connectionID: connection.id)
    XCTAssertEqual(model.executionRecords[record.id], record)
    XCTAssertTrue(CompanionModel.instructions(for: record).contains("Original instructions"))
    XCTAssertFalse(CompanionModel.instructions(for: record).contains(defaults.instructions))
    let file = try XCTUnwrap(model.executionDirectory).appendingPathComponent("preferences.json")
    let persisted = try JSONDecoder().decode(DeviceExecutionPreferences.self, from: Data(contentsOf: file))
    XCTAssertEqual(persisted.agentDefaults, defaults)
    XCTAssertEqual(persisted.conversations[record.id], record)
    let reopened = CompanionModel(store: store, transport: ExecutionTestLibrary())
    reopened.executionDirectory = model.executionDirectory
    try await reopened.loadExecutionConfiguration()
    XCTAssertEqual(reopened.deviceAgentDefaults, defaults)
    XCTAssertEqual(reopened.inferenceConnectionID, connection.id)
    await reopened.startNewChat(with: try XCTUnwrap(reopened.launcherAgents.first))
    let newID = try XCTUnwrap(reopened.selectedConversationID)
    XCTAssertNotEqual(newID, record.id)
    XCTAssertEqual(reopened.executionRecords[newID]?.thinkingLevel, "high")
    XCTAssertEqual(reopened.executionRecords[record.id], record)
  }

  @MainActor func testThinkingDefaultMigratesAndFallsBackForDifferentModels() throws {
    let legacy = try JSONDecoder().decode(DeviceAgentDefaults.self, from: Data(#"{"instructions":"","enabledTools":[]}"#.utf8))
    var descriptor = InferenceModel(id: "reasoning", name: "Reasoning", provider: "openai", api: "openai-responses", baseUrl: "https://api.openai.com/v1", reasoning: true,
      thinkingLevelMap: ["minimal": nil, "xhigh": "xhigh", "max": "max"])
    XCTAssertNil(legacy.thinkingLevel)
    XCTAssertEqual(legacy.thinking(for: descriptor), "high")
    let explicit = DeviceAgentDefaults(thinkingLevel: "max")
    XCTAssertEqual(explicit.thinking(for: descriptor), "max")
    descriptor.thinkingLevelMap = nil
    XCTAssertEqual(explicit.thinking(for: descriptor), "medium")
    descriptor.reasoning = false
    XCTAssertEqual(explicit.thinking(for: descriptor), "off")
  }

  @MainActor func testToolAccessGatesOnlyCLIAndItsLegacyNoteAliases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = CompanionModel(store: try MobileStore(file: root.appendingPathComponent("library.json")), transport: ExecutionTestLibrary())
    model.executionDirectory = root.appendingPathComponent("execution")
    let connection = InferenceConnection(id: "saved", name: "Saved", provider: "openai", route: .direct, modelID: "test")
    let record = DeviceConversationRecord(id: "tools", title: "Tools", enabledTools: [], connectionID: connection.id, connection: connection, modelJSON: "{}", status: "ready", updatedAt: "")
    model.executionRecords[record.id] = record
    let tools = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(model.toolsJSON(for: record).utf8)) as? [[String: Any]])
    let names = Set(tools.compactMap { $0["name"] as? String })
    XCTAssertTrue(names.isSuperset(of: ["list_files", "read_file", "write_file", "read_image", "read_document", "fetch_url", "ask_user", "execute_command"]))
    XCTAssertEqual(names.filter { $0.hasPrefix("wovenmatter_") }, ["wovenmatter_goals"])
    XCTAssertFalse(names.contains("read_note"))
    let context = try model.deviceToolContext(conversationID: record.id)
    XCTAssertEqual(context.enabled, [.goals])
    for name in ["wovenmatter_calendar", "read_note"] {
      do {
        _ = try await model.performDeviceTool(CompanionModel.toolJSON(["name": name, "conversationID": record.id, "arguments": [:]]))
        XCTFail("Disabled app-data access was accepted")
      } catch { XCTAssertTrue(error.localizedDescription.contains("disabled")) }
    }
    XCTAssertTrue(CompanionModel.deviceToolEnabled("read_note", selection: ["wovenmatter_notes"]))
    XCTAssertTrue(CompanionModel.deviceToolEnabled("wovenmatter_browser", selection: nil))
    XCTAssertFalse(CompanionModel.deviceToolEnabled("wovenmatter_computer", selection: nil))
    XCTAssertTrue(CompanionModel.deviceToolEnabled("wovenmatter_computer", selection: ["wovenmatter_computer"]))
    XCTAssertTrue(CompanionModel.deviceToolEnabled("read_note", selection: ["read_note"]))
    XCTAssertFalse(CompanionModel.deviceToolEnabled("wovenmatter_notes", selection: ["read_note"]))
    XCTAssertEqual(Set(CompanionModel.deviceToolAccessOptions.map(\.id)), Set(WorkspaceToolGroup.allCases.filter { $0 != .goals }.map { "wovenmatter_" + $0.rawValue }))
    XCTAssertTrue(CompanionModel.deviceCLITools.contains { $0["name"] as? String == "wovenmatter_goals" })
  }

  @MainActor func testDirectWorkspaceRecoversLostSendReceiptWhileCentralIsOffline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    let libraryID = UUID().uuidString.lowercased(), workspaceID = UUID().uuidString.lowercased()
    try await store.apply(CompanionSnapshot(workspaceID: libraryID, cursor: 0))
    let workspace = CompanionExecutionWorkspace(id: workspaceID, libraryID: libraryID, ownerDeviceID: "owner", kind: .linux,
      name: "Linux", endpoint: URL(string: "https://workspace.example.ts.net/wovenmatter"))
    try await store.journal.upsertWorkspace(workspace)
    let endpoint = ExecutionTestWorkspace(workspace)
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    await model.reload(); model.online = false; model.executionWorkspaceID = workspaceID
    model.workspaceClients[workspaceID] = WorkspaceClient(store: store, workspaceID: workspaceID, transport: endpoint)
    model.workspaceReachable[workspaceID] = true
    model.workspaceProviders[workspaceID] = try await endpoint.providers()
    model.providerID = "pi"; model.composer = "Run exactly once"
    await model.send()
    XCTAssertEqual(model.composer, "Run exactly once")
    XCTAssertNotNil(model.errorMessage)
    let first = await store.snapshot().launches
    XCTAssertEqual(first.count, 1)
    XCTAssertNil(first[0].sendReceipt)
    await model.send()
    let calls = await endpoint.commands
    XCTAssertEqual(calls.filter { $0.kind == .createSession }.count, 1)
    XCTAssertEqual(calls.filter { $0.kind == .send }.count, 1)
    XCTAssertEqual(model.selectedExecutionWorkspaceID, workspaceID)
    XCTAssertFalse(model.online)
    let reopened = try MobileStore(file: root.appendingPathComponent("library.json"))
    let launches = await reopened.snapshot().launches
    XCTAssertTrue(launches[0].accepted)
  }

  @MainActor func testPendingResponseUsesConversationOwnerAfterNavigation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    let libraryID = UUID().uuidString.lowercased(), workspaceID = UUID().uuidString.lowercased()
    let workspace = CompanionExecutionWorkspace(id: workspaceID, libraryID: libraryID, ownerDeviceID: "owner", kind: .linux, name: "Linux")
    let endpoint = ExecutionTestWorkspace(workspace)
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    await model.reload(); model.online = false
    model.workspaceClients[workspaceID] = WorkspaceClient(store: store, workspaceID: workspaceID, transport: endpoint)
    model.conversationWorkspaceIDs["remote-conversation"] = workspaceID
    model.executionWorkspaceID = "local"
    await model.respond(.init(id: "approval", conversationID: "remote-conversation", runID: "remote-run", kind: .approval, title: "Permission"), response: .init(optionID: "allow"))
    let calls = await endpoint.commands
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(calls.count, 1, model.errorMessage ?? "Expected the conversation owner's workspace to receive the response")
    let submitted = try XCTUnwrap(calls.first)
    XCTAssertEqual(submitted.conversationID, "remote-conversation")
    XCTAssertEqual(submitted.workspaceID, workspaceID)
    XCTAssertEqual(submitted.kind, .respond)
    XCTAssertEqual(submitted.runID, "remote-run")
    XCTAssertEqual(submitted.interactionID, "approval")
    XCTAssertEqual(submitted.response?.optionID, "allow")
  }

  @MainActor func testNoteReadVersionChangesForOfflineEditsAtSameServerRevision() throws {
    let original = CompanionNote(id: "note", title: "Before", content: "Text", revision: 4)
    var edited = original
    edited.content = "New local text"
    XCTAssertEqual(original.revision, edited.revision)
    XCTAssertNotEqual(try CompanionModel.noteLocalVersion(original), try CompanionModel.noteLocalVersion(edited))
  }

  @MainActor func testFullAccessRunsToolsWithoutPromptsAndAskModeStillRequiresApproval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = CompanionModel(store: try MobileStore(file: root.appendingPathComponent("library.json")), transport: ExecutionTestLibrary())
    model.executionDirectory = root.appendingPathComponent("execution")
    let full = DeviceConversationRecord(id: "full", title: "Full", permissionMode: .full, connectionID: "fixture", modelJSON: "{}", status: "ready", updatedAt: "")
    var ask = full; ask.id = "ask"; ask.permissionMode = nil
    model.executionRecords = [full.id: full, ask.id: ask]
    model.selectedConversationID = ask.id
    let request = try CompanionModel.toolJSON(["name": "write_file", "conversationID": full.id, "arguments": ["path": "result.txt", "content": "Saved"]])
    _ = try await model.performDeviceTool(request)
    XCTAssertEqual(try String(contentsOf: model.deviceWorkspaceURL(conversationID: full.id, path: "result.txt"), encoding: .utf8), "Saved")
    XCTAssertTrue(model.localPending.isEmpty, "Permission belongs to the tool's owner, not the selected chat")
    model.selectedConversationID = full.id
    let waiting = Task { try await model.requireDeviceApproval(id: "ask-write", conversationID: ask.id, title: "Write", detail: "File") }
    for _ in 0..<100 where model.localApprovals["ask-write"] == nil { await Task.yield() }
    XCTAssertEqual(model.localPending.map(\.id), ["ask-write"], "Legacy chats keep asking until explicitly changed")
    waiting.cancel()
    do { try await waiting.value; XCTFail("Cancelled approval must not continue") } catch is CancellationError { }
    let question = Task { try await model.askDeviceQuestion(id: "question", conversationID: full.id, question: "Which file?") }
    for _ in 0..<100 where model.localApprovals["question"] == nil { await Task.yield() }
    XCTAssertEqual(model.localPending.map(\.id), ["question"], "Full access must still surface questions")
    question.cancel()
    do { _ = try await question.value; XCTFail("Cancelled question must not continue") } catch is CancellationError { }
  }

  @MainActor func testDraftPermissionPersistsAndInvalidRemoteModeIsRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    model.executionDirectory = root.appendingPathComponent("execution")
    XCTAssertEqual(model.deviceChatPermission, .ask)
    try await model.configureDeviceChat(permission: .full)
    let reopened = CompanionModel(store: store, transport: ExecutionTestLibrary())
    reopened.executionDirectory = model.executionDirectory
    try await reopened.loadExecutionConfiguration()
    XCTAssertEqual(reopened.deviceChatPermission, .full)
    model.executionRecords["chat"] = .init(id: "chat", title: "Chat", connectionID: "fixture", modelJSON: "{}", status: "ready", updatedAt: "")
    let changed = await model.performDeviceAction(.configureSession(id: "chat", model: nil, thinking: nil, permission: "unknown"))
    XCTAssertFalse(changed)
    XCTAssertNil(model.executionRecords["chat"]?.permissionMode)
  }

  @MainActor func testCancellingDeviceApprovalRemovesPendingWait() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    let waiting = Task {
      do {
        try await model.requireDeviceApproval(id: "approval", conversationID: "device-chat", title: "Write", detail: "File")
        return false
      } catch is CancellationError { return true }
      catch { return false }
    }
    for _ in 0..<100 where model.localApprovals["approval"] == nil { await Task.yield() }
    XCTAssertNotNil(model.localApprovals["approval"])
    XCTAssertEqual(model.localPending.map(\.id), ["approval"])
    waiting.cancel()
    let cancelled = await waiting.value
    XCTAssertTrue(cancelled)
    XCTAssertNil(model.localApprovals["approval"])
    XCTAssertTrue(model.localPending.isEmpty)
  }

  @MainActor func testLateQuestionCancellationDoesNotRemoveReplacementWait() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    func questionTask() -> Task<Bool, Never> {
      Task { @MainActor in
        do {
          _ = try await model.askDeviceQuestion(id: "question", conversationID: "device-chat", question: "Continue?")
          return false
        } catch is CancellationError { return true }
        catch { return false }
      }
    }
    let first = questionTask()
    for _ in 0..<100 where model.localApprovals["question"] == nil { await Task.yield() }
    let firstToken = try XCTUnwrap(model.localApprovals["question"]?.token)
    first.cancel()
    let firstCancelled = await first.value
    XCTAssertTrue(firstCancelled)
    let second = questionTask()
    for _ in 0..<100 where model.localApprovals["question"] == nil { await Task.yield() }
    let secondToken = try XCTUnwrap(model.localApprovals["question"]?.token)
    XCTAssertNotEqual(firstToken, secondToken)
    model.cancelDeviceApproval("question", token: firstToken)
    XCTAssertEqual(model.localApprovals["question"]?.token, secondToken)
    XCTAssertEqual(model.localPending.map(\.id), ["question"])
    second.cancel()
    let secondCancelled = await second.value
    XCTAssertTrue(secondCancelled)
    XCTAssertTrue(model.localPending.isEmpty)
    XCTAssertTrue(model.localQuestionAnswers.isEmpty)
  }

  @MainActor func testWorkspaceFileToolsRejectTraversalAndSymlinkEscape() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    let model = CompanionModel(store: store, transport: ExecutionTestLibrary())
    model.executionDirectory = root.appendingPathComponent("execution")
    let id = UUID().uuidString.lowercased()
    let workspace = try model.deviceWorkspaceURL(conversationID: id, path: "", directory: true)
    XCTAssertThrowsError(try model.deviceWorkspaceURL(conversationID: id, path: "../library.json"))
    XCTAssertThrowsError(try model.deviceWorkspaceURL(conversationID: id, path: "/etc/passwd"))
    try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("outside"), withDestinationURL: root)
    XCTAssertThrowsError(try model.deviceWorkspaceURL(conversationID: id, path: "outside/library.json"))
  }
}

private actor InferenceSetupMemoryCredentials: InferenceCredentialWriting {
  private var values: [String: String]
  init(_ values: [String: String] = [:]) { self.values = values }
  func read(connectionID: String) -> String? { values[connectionID] }
  func save(_ secret: String, connectionID: String) { values[connectionID] = secret }
  func remove(connectionID: String) { values.removeValue(forKey: connectionID) }
  func snapshot() -> [String: String] { values }
}

final class InferenceSetupTests: XCTestCase {
  private static func descriptor(_ id: String = "selected-model", name: String = "Selected model", provider: String = "opencode-go") -> InferenceModel {
    .init(id: id, name: name, provider: provider, api: "openai-completions", baseUrl: "https://opencode.ai/zen/go/v1")
  }
  @MainActor func testUnpairedAPIKeySaveAndReopenUsesOnlyInjectedDeviceCredentials() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("preferences.json"), credentials = InferenceSetupMemoryCredentials()
    let descriptor = Self.descriptor()
    let connection = InferenceConnection(name: " OpenCode Go ", provider: "opencode-go", route: .direct, modelID: descriptor.id)
    let saved = try await InferenceConnectionSaveTransaction.save(connection, secret: " \n device-key \t", existing: [], credentials: credentials,
      resolveModel: { candidate, key in
        XCTAssertEqual(candidate.route, .direct); XCTAssertNil(candidate.hostScope); XCTAssertNil(candidate.baseURL)
        XCTAssertEqual(key, "device-key")
        return descriptor
      }) { value in
        try JSONEncoder().encode(DeviceExecutionPreferences(connections: [value], selectedConnectionID: value.id)).write(to: file, options: .atomic)
      }
    let reopened = try JSONDecoder().decode(DeviceExecutionPreferences.self, from: Data(contentsOf: file))
    XCTAssertEqual(reopened.workspaceID, "local")
    XCTAssertEqual(reopened.connections, [saved])
    XCTAssertEqual(reopened.selectedConnectionID, saved.id)
    XCTAssertEqual(saved.name, "OpenCode Go")
    XCTAssertEqual(saved.selectedModel, descriptor)
    let stored = await credentials.read(connectionID: saved.id)
    XCTAssertEqual(stored, "device-key")
    XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("device-key"))
    let resaved = try await InferenceConnectionSaveTransaction.save(saved, secret: "  ", existing: reopened.connections, credentials: credentials,
      resolveModel: { _, key in XCTAssertEqual(key, "device-key"); return descriptor }, persist: { _ in })
    XCTAssertEqual(resaved.id, saved.id)
    let reopenedKeys = await credentials.snapshot()
    XCTAssertEqual(reopenedKeys, [saved.id: "device-key"])
  }
  @MainActor func testCredentialReplacementKeepsOldBindingAndRollsBackFailedSave() async throws {
    let descriptor = Self.descriptor()
    let original = InferenceConnection(id: "existing-device-connection", name: "OpenCode Go", provider: "opencode-go", route: .direct, modelID: descriptor.id, selectedModel: descriptor)
    let credentials = InferenceSetupMemoryCredentials([original.id: "old-device-key"])
    let saved = try await InferenceConnectionSaveTransaction.save(original, secret: "new-device-key", existing: [original], credentials: credentials,
      resolveModel: { _, _ in descriptor }, persist: { _ in })
    XCTAssertNotEqual(saved.id, original.id)
    let beforeFailure = await credentials.snapshot()
    XCTAssertEqual(beforeFailure[original.id], "old-device-key")
    XCTAssertEqual(beforeFailure[saved.id], "new-device-key")
    do {
      _ = try await InferenceConnectionSaveTransaction.save(original, secret: "unsaved-device-key", existing: [original], credentials: credentials,
        resolveModel: { _, _ in descriptor }, persist: { _ in throw CocoaError(.fileWriteOutOfSpace) })
      XCTFail("Preference write failure must fail the save")
    } catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteOutOfSpace) }
    let afterFailure = await credentials.snapshot()
    XCTAssertEqual(afterFailure, beforeFailure)
  }
  @MainActor func testOAuthModelEditKeepsBindingAndDoesNotOverwriteRefreshedCredential() async throws {
    let originalModel = Self.descriptor("first-model", provider: "openai-codex")
    let replacementModel = Self.descriptor("second-model", provider: "openai-codex")
    let original = InferenceConnection(id: "phone-account", name: "ChatGPT", provider: "openai-codex", accountID: "signed-in-account",
      route: .direct, modelID: originalModel.id, selectedModel: originalModel)
    let credentials = InferenceSetupMemoryCredentials([original.id: "oauth-before-refresh"])
    var proposed = original; proposed.modelID = replacementModel.id; proposed.selectedModel = replacementModel
    let saved = try await InferenceConnectionSaveTransaction.save(proposed, secret: "", existing: [original], credentials: credentials,
      resolveModel: { candidate, credential in
        XCTAssertEqual(candidate.id, original.id)
        XCTAssertEqual(credential, "oauth-before-refresh")
        // A concurrent inference run refreshes this account while setup awaits its model.
        await credentials.save("oauth-after-refresh", connectionID: original.id)
        return replacementModel
      }, persist: { _ in })
    XCTAssertEqual(saved.id, original.id)
    XCTAssertEqual(saved.modelID, replacementModel.id)
    let stored = await credentials.snapshot()
    XCTAssertEqual(stored, [original.id: "oauth-after-refresh"])
  }
  @MainActor func testEmptyKeyCannotCreateConnectionOrStartModelResolution() async throws {
    let credentials = InferenceSetupMemoryCredentials(), descriptor = Self.descriptor()
    let connection = InferenceConnection(name: "OpenCode Go", provider: "opencode-go", route: .direct, modelID: descriptor.id)
    do {
      _ = try await InferenceConnectionSaveTransaction.save(connection, secret: " \n\t", existing: [], credentials: credentials,
        resolveModel: { _, _ in XCTFail("No credential was supplied"); return descriptor }, persist: { _ in XCTFail("Invalid setup cannot persist") })
      XCTFail("A new connection requires a nonempty key")
    } catch InferenceError.missingCredential {}
    let stored = await credentials.snapshot()
    XCTAssertTrue(stored.isEmpty)
  }
  @MainActor func testProviderSwitchFencesOldCatalogAndSignInResults() {
    let state = InferenceConnectionSetupState(provider: "openai-codex")
    let catalogGeneration = state.beginCatalog(), authenticationGeneration = state.authenticationGeneration
    state.secret = "old-provider-credential"; state.storedCredentialAvailable = true
    state.chooseProvider("opencode-go")
    XCTAssertEqual(state.mode, .device)
    XCTAssertEqual(state.name, InferenceConnectionSetupState.providerName("opencode-go"))
    XCTAssertEqual(state.secret, ""); XCTAssertFalse(state.storedCredentialAvailable)
    XCTAssertFalse(state.receiveModels([Self.descriptor()], generation: catalogGeneration))
    XCTAssertFalse(state.receiveCredential("late-credential", accountID: "old-account", generation: authenticationGeneration))
    XCTAssertTrue(state.models.isEmpty); XCTAssertTrue(state.secret.isEmpty)
  }
  @MainActor func testSignedInAccountWaitsForCatalogBeforeAutomaticSave() throws {
    let state = InferenceConnectionSetupState(provider: "openai-codex")
    let generation = state.beginCatalog()
    XCTAssertTrue(state.receiveCredential("test-credential", accountID: "test-account", generation: state.authenticationGeneration))
    XCTAssertTrue(state.pendingSignInSave)
    XCTAssertNotNil(state.saveProblem)
    state.receiveModels([Self.descriptor(provider: "openai-codex")], generation: generation)
    state.loadingModels = false
    XCTAssertNil(state.saveProblem)
    let saved = try state.configuredConnection()
    XCTAssertEqual(saved.accountID, "test-account")
    XCTAssertEqual(saved.modelID, "selected-model")
    state.chooseProvider("opencode-go")
    XCTAssertFalse(state.pendingSignInSave)
  }
  @MainActor func testCatalogChoosesVisibleDefaultButPreservesSavedModel() {
    let first = Self.descriptor("alpha", name: "Alpha"), second = Self.descriptor("beta", name: "Beta")
    let state = InferenceConnectionSetupState(provider: "opencode-go")
    state.receiveModels([second, first], generation: state.beginCatalog())
    XCTAssertEqual(state.modelID, "alpha")
    state.loadingModels = false; state.secret = " device-key "
    XCTAssertNil(state.saveProblem)
    let existing = InferenceConnection(name: "My provider", provider: "opencode-go", route: .direct, modelID: second.id, selectedModel: second)
    let editing = InferenceConnectionSetupState(connection: existing)
    var changedCatalogModel = second; changedCatalogModel.contextWindow *= 2
    editing.receiveModels([first, changedCatalogModel], generation: editing.beginCatalog())
    XCTAssertEqual(editing.modelID, "beta")
    XCTAssertEqual(editing.models.first(where: { $0.id == second.id }), second)
    var recommended = second; recommended.metadata["recommended"] = .bool(true)
    let fresh = InferenceConnectionSetupState(provider: "opencode-go")
    fresh.receiveModels([first, recommended], generation: fresh.beginCatalog())
    XCTAssertEqual(fresh.modelID, "beta")
  }
}
