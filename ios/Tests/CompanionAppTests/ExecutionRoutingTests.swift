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
  init(_ workspace: CompanionExecutionWorkspace) { self.workspace = workspace }
  func identity() async throws -> CompanionExecutionWorkspace { workspace }
  func providers() async throws -> [CompanionProvider] { [.init(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)] }
  func pending() async throws -> [CompanionPendingInteraction] { [] }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt {
    commands.append(command)
    let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID)
    receipts[command.commandID] = receipt
    if command.kind == .send && dropSendAcknowledgement { dropSendAcknowledgement = false; throw MobileConnectionError.offline }
    return receipt
  }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? { receipts[id] }
  func events(after: Int64) async throws -> CompanionJournalPage { .init(libraryID: workspace.libraryID, cursor: after) }
  func conversations() async throws -> [CompanionConversation] { [] }
  func transcript(_ id: String) async throws -> CompanionTranscript { .init(conversationID: id) }
}

final class ExecutionRoutingTests: XCTestCase {
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
