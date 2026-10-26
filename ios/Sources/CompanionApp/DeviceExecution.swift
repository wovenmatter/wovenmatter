import SwiftUI
import CryptoKit
import CompanionClient
import WovenMatterCompanion
import CompanionInference
import PiDurableRuntime

enum DevicePermissionMode: String, Codable, CaseIterable {
  case ask, full
  static let defaultMode: Self = .full
  var label: String { self == .full ? "Full Access" : "Ask for Approval" }
  var detail: String {
    self == .full ? "Enabled tools run without approval prompts in this chat." : "Ask before tool actions that need approval."
  }
}

struct DeviceConversationRecord: Codable, Equatable {
  var id: String
  var goalLedger: WorkspaceGoalLedger?
  var goalUsageBaseline: Int64?
  var title: String
  var folderID: String?
  var isPinned: Bool?
  var isTrashed: Bool?
  var enabledTools: [String]?
  var thinkingLevel: String?
  var permissionMode: DevicePermissionMode?
  var executionPolicy: PiExecutionPolicy?
  var additionalInstructions: String?
  var connectionID: String
  var connection: InferenceConnection?
  var modelJSON: String
  var runID: String?
  var submissionID: Int?
  var pendingInput: String?
  /// Asset captured when the running human input was submitted; UI selection cannot retarget it.
  var inputAssetID: String?
  var sourceDraftKey: String?
  var sourceDraft: MobileChatDraft?
  var status: String
  var updatedAt: String
}

struct DeviceAgentDefaults: Codable, Equatable {
  var thinkingLevel: String?
  func thinking(for model: InferenceModel?) -> String {
    guard let model else { return "off" }
    if let thinkingLevel, model.supportedThinkingLevels.contains(thinkingLevel) { return thinkingLevel }
    return model.middleThinkingLevel
  }
  var executionPolicy: PiExecutionPolicy?
  var instructions = ""
  var enabledTools: [String]?
}

struct DeviceChatSettings: Codable, Equatable {
  var connection: InferenceConnection?
  var thinkingLevel: String?
  var permissionMode: DevicePermissionMode?
  var enabledTools: [String]?
}

struct DeviceExecutionPreferences: Codable {
  var goalCapabilityVersion: Int? = 1
  var connections: [InferenceConnection] = []
  var selectedConnectionID = ""
  var workspaceID = "local"
  var conversations: [String: DeviceConversationRecord] = [:]
  var agentDefaults: DeviceAgentDefaults?
  var chatSettings: DeviceChatSettings?
}

struct InferenceSetupCredential: InferenceCredentialReading {
  let value: String
  func read(connectionID: String) async throws -> String? { value }
}

/// Saves credentials before metadata, rolling back the credential if metadata cannot commit.
/// Tests use an in-memory credential store and resolver; app fixtures never open the real store.
@MainActor enum InferenceConnectionSaveTransaction {
  static func save(_ proposed: InferenceConnection, secret: String, existing: [InferenceConnection],
                   credentials: any InferenceCredentialWriting,
                   resolveModel: @Sendable (InferenceConnection, String) async throws -> InferenceModel = { connection, credential in
                     try await CompanionInferenceService(connection: connection, credentials: InferenceSetupCredential(value: credential)).model()
                   },
                   persist: @MainActor (InferenceConnection) throws -> Void) async throws -> InferenceConnection {
    var saved = proposed
    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
    try saved.validate()
    try Task.checkCancellation()
    let previous = existing.first { $0.id == proposed.id }
    let previousSecret = try await credentials.read(connectionID: proposed.id)
    let supplied = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    let sameAuthority = previous.map {
      $0.provider == proposed.provider && $0.route == proposed.route && $0.baseURL == proposed.baseURL &&
      $0.accountID == proposed.accountID && $0.hostScope == proposed.hostScope
    } ?? false
    let credential: String
    if !supplied.isEmpty { credential = supplied }
    else {
      guard sameAuthority, let previousSecret, !previousSecret.isEmpty else { throw InferenceError.missingCredential }
      credential = previousSecret
    }
    let reusesCredential = previous != nil && sameAuthority && previousSecret == credential
    if previous != nil && !reusesCredential {
      // Running conversations retain the old account/credential binding after edits.
      saved.id = UUID().uuidString.lowercased()
    }
    saved.selectedModel = try await resolveModel(saved, credential)
    try Task.checkCancellation()
    if reusesCredential {
      // Model/name edits share the credential identity. Never overwrite a token that may
      // have refreshed while the model was being resolved, or duplicate rotating tokens.
      try persist(saved)
      return saved
    }
    let overwritten = saved.id == proposed.id ? previousSecret : try await credentials.read(connectionID: saved.id)
    try await credentials.save(credential, connectionID: saved.id)
    do {
      try Task.checkCancellation()
      try persist(saved)
      return saved
    } catch {
      // Keep the original failure useful while making rollback failures explicit.
      do {
        if let overwritten { try await credentials.save(overwritten, connectionID: saved.id) }
        else { try await credentials.remove(connectionID: saved.id) }
      } catch {
        throw DeviceExecutionError.unavailable("The connection was not saved. Its temporary credential could not be removed; retry saving this connection.")
      }
      throw error
    }
  }
}

struct LocalToolApproval {
  var token: String
  var conversationID: String
  var continuation: CheckedContinuation<Bool, Never>
}

enum DeviceExecutionError: LocalizedError {
  case unavailable(String)
  var errorDescription: String? { if case .unavailable(let message) = self { message } else { nil } }
}

extension CompanionModel {
  var deviceWorkspaceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone" }
  var deviceConnectionsTitle: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad Connections" : "iPhone Connections" }
  var deviceWorkspaceID: String { state.deviceID }
  var launcherAgents: [CompanionAgentLauncher] {
    var known = knownAgentIDs
    for conversation in conversations {
      if let provider = conversation.providerID { known.insert(executionOwner(of: conversation.id) + ":" + provider) }
    }
    return CompanionAgentLauncher.list(deviceName: deviceWorkspaceName, centralOnline: online, providers: providers,
      workspaces: executionWorkspaces, workspaceProviders: workspaceProviders, reachable: workspaceReachable, knownAgentIDs: known)
  }
  var launcherGroups: [CompanionAgentGroup] {
    CompanionAgentGroup.list(agents: launcherAgents, workspaces: executionWorkspaces)
  }
  func launchAgent(_ launcher: CompanionAgentLauncher) async {
    guard let current = launcherAgents.first(where: { $0.id == launcher.id }), current.isAvailable else { return }
    if let latest = current.latestConversation(in: conversations, owner: { executionOwner(of: $0) }) {
      await selectConversation(latest.id, workspaceID: current.workspaceID)
    } else {
      await startNewChat(with: current)
    }
  }
  func rememberAgentCatalog() {
    guard let libraryID = state.workspaceID, let executionDirectory else { return }
    for provider in providers where provider.available && provider.canStart { knownAgentIDs.insert("central:" + provider.id) }
    for (workspace, providers) in workspaceProviders {
      for provider in providers where provider.available && provider.canStart { knownAgentIDs.insert(workspace + ":" + provider.id) }
    }
    let saved = CompanionAgentCatalog(libraryID: libraryID, providers: providers, workspaceProviders: workspaceProviders, knownAgentIDs: knownAgentIDs)
    guard saved != savedAgentCatalog else { return }
    do {
      try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
      try JSONEncoder().encode(saved).write(to: executionDirectory.appendingPathComponent("agents.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      savedAgentCatalog = saved
    } catch { /* Discovery caching must not interrupt an otherwise working connection. */ }
  }
  func restoreAgentCatalog() {
    guard let executionDirectory,
      let data = try? Data(contentsOf: executionDirectory.appendingPathComponent("agents.json")),
      let saved = try? JSONDecoder().decode(CompanionAgentCatalog.self, from: data), saved.libraryID == state.workspaceID else { return }
    providers = saved.providers; workspaceProviders = saved.workspaceProviders; knownAgentIDs = saved.knownAgentIDs
    savedAgentCatalog = saved
  }
  func saveDeviceAgentDefaults(_ defaults: DeviceAgentDefaults, connectionID: String) throws {
    guard let executionDirectory else { throw DeviceExecutionError.unavailable("The device workspace could not be opened.") }
    guard connectionID.isEmpty || inferenceConnections.contains(where: { $0.id == connectionID }) else { throw InferenceError.invalidConfiguration }
    let available = Set(Self.deviceToolDefinitions.compactMap { $0["name"] as? String } + Self.deviceToolAccessOptions.map(\.id))
    guard defaults.enabledTools.map({ Set($0).isSubset(of: available) }) ?? true else { throw DeviceExecutionError.unavailable("An unknown device tool was selected.") }
    let preferences = DeviceExecutionPreferences(connections: inferenceConnections, selectedConnectionID: connectionID,
      workspaceID: executionWorkspaceID, conversations: executionRecords, agentDefaults: defaults, chatSettings: draftDeviceSettings)
    try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
    try JSONEncoder().encode(preferences).write(to: executionDirectory.appendingPathComponent("preferences.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    deviceAgentDefaults = defaults; inferenceConnectionID = connectionID
  }
  static func instructions(for record: DeviceConversationRecord) -> String {
    let base = "You are Pi Durable running on an iOS Woven Matter workspace. Use the focused Woven MCP tools for local notes, history, sessions, goals, timers, calendar, library, usage and Executor. Select the central target explicitly for the paired Mac. Use execute_command for bundled Python, SQLite and file commands in this conversation workspace. Model inference is remote; your tools and durable execution run on this device. Workspace paths are relative to this conversation's directory. Python includes its standard library and await woven_mcp(name, arguments) using those same tool schemas; it does not provide OS subprocesses, package downloads, sockets or unrestricted host filesystem access. Use woven_context when the user refers to their open note; its captured asset cannot change during this input. Notes and saved artifacts synchronize with the central library when reachable. Ask before consequential changes."
    let additional = record.additionalInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return additional.isEmpty ? base : base + "\n\nUser instructions for this conversation:\n" + additional
  }
  func executionOwner(of conversationID: String) -> String {
    if executionRecords[conversationID] != nil { return "local" }
    if let workspaceID = conversationWorkspaceIDs[conversationID] { return workspaceID == deviceWorkspaceID ? "local" : workspaceID }
    return "central"
  }
  /// All entry points resolve the same agent identity, including Folders and pending requests.
  func preferredExecutionRoute(for conversationID: String) -> String {
    let owner = executionOwner(of: conversationID)
    guard owner != "local", let provider = state.conversations[conversationID]?.providerID else { return owner }
    return launcherAgents.first { agent in
      agent.isAvailable && ((agent.workspaceID == owner && agent.providerID == provider)
        || agent.conversationRoutes[owner]?.contains(provider) == true)
    }?.workspaceID ?? owner
  }
  /// A transport fallback never changes which workspace owns retained history.
  func executionRoute(for conversationID: String) -> String {
    if let route = selectedConversationRoute, route.conversationID == conversationID { return route.workspaceID }
    return executionOwner(of: conversationID)
  }
  var selectedExecutionWorkspaceID: String {
    selectedConversationID.map { executionRoute(for: $0) } ?? executionWorkspaceID
  }
  func executionAvailable(for conversationID: String) -> Bool {
    switch executionRoute(for: conversationID) {
    case "local": return !fixture
    case "central": return online
    default: return workspaceReachable[executionRoute(for: conversationID)] == true
    }
  }
  var executionName: String {
    switch selectedExecutionWorkspaceID {
    case "local": deviceWorkspaceName
    case "central": "Central Mac"
    default: executionWorkspaces.first { $0.id == selectedExecutionWorkspaceID }?.name ?? "Workspace"
    }
  }
  var executionOnline: Bool {
    switch selectedExecutionWorkspaceID {
    case "local": !fixture && executionDirectory != nil
    case "central": online
    default: workspaceReachable[selectedExecutionWorkspaceID] == true
    }
  }
  var selectedInferenceConnection: InferenceConnection? {
    if let id = selectedConversationID, let connection = executionRecords[id]?.connection { return connection }
    if selectedConversationID == nil, let connection = draftDeviceSettings.connection { return connection }
    let id = selectedConversationID.flatMap { executionRecords[$0]?.connectionID } ?? inferenceConnectionID
    return inferenceConnections.first { $0.id == id }
  }
  var availableExecutionProviders: [CompanionProvider] {
    if selectedExecutionWorkspaceID == "local" { return [deviceProvider] }
    if selectedExecutionWorkspaceID == "central" { return providers }
    return workspaceProviders[selectedExecutionWorkspaceID] ?? []
  }
  var deviceProvider: CompanionProvider {
    .init(id: "pi-durable-device", runtimeKind: "pi", displayName: "Pi Durable", routeName: deviceWorkspaceName,
          available: selectedInferenceConnection != nil && executionOnline, canStart: true, canResume: true,
          canSteer: false, canStop: true, supportsApprovals: true, supportsQuestions: true,
          unavailableReason: selectedInferenceConnection == nil ? "Add an inference connection in Settings." : nil)
  }
  var activeProvider: CompanionProvider? {
    if selectedExecutionWorkspaceID == "local" { return deviceProvider }
    if selectedExecutionWorkspaceID == "central" { return centralProvider }
    return selectedConversationID.flatMap { sessionCapabilities[$0] } ?? availableExecutionProviders.first { $0.id == (selectedConversation?.providerID ?? providerID) }
  }
  var executionStatus: String {
    if selectedExecutionWorkspaceID == "local" {
      if let id = selectedConversationID, let record = executionRecords[id], record.status == "stopping" { return "Stopping saved execution…" }
      if let id = selectedConversationID, let record = executionRecords[id], record.status == "interrupted" { return "Saved on this device · ready to resume" }
      if let connection = selectedInferenceConnection { return "\(deviceWorkspaceName) · \(connection.name)" }
      return "\(deviceWorkspaceName) · choose an inference connection"
    }
    return executionOnline ? executionName : "\(executionName) unavailable · draft saved here"
  }
  var composerHelp: String? {
    if selectedExecutionWorkspaceID == "local", selectedInferenceConnection == nil { return "Add a cloud or Tailscale inference connection in Settings. Pi Durable and its tools run on this device." }
    if !executionOnline { return "This workspace is unavailable. You can keep writing; your draft is saved on this device." }
    if activeRunID != nil && activeProvider?.canSteer != true { return "This agent is running. Stop it or wait before sending another message." }
    return nil
  }
  var canResumeLocalRun: Bool {
    guard let id = selectedConversationID else { return false }
    return executionRecords[id]?.status == "interrupted" && localRunTasks[id] == nil && !localStopping.contains(id) && !localInterrupting.contains(id)
  }

  func loadExecutionConfiguration() async throws {
    guard let executionDirectory else { return }
    try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
    let file = executionDirectory.appendingPathComponent("preferences.json")
    if FileManager.default.fileExists(atPath: file.path) {
      let saved = try JSONDecoder().decode(DeviceExecutionPreferences.self, from: Data(contentsOf: file))
      inferenceConnections = saved.connections; inferenceConnectionID = saved.selectedConnectionID
      executionWorkspaceID = saved.workspaceID; executionRecords = saved.conversations
      deviceAgentDefaults = saved.agentDefaults ?? .init()
      draftDeviceSettings = saved.chatSettings ?? .init(enabledTools: deviceAgentDefaults.enabledTools)
      for id in executionRecords.keys {
        executionRecords[id]?.enabledTools = Self.migratedDeviceToolSelection(executionRecords[id]?.enabledTools)
      }
      deviceAgentDefaults.enabledTools = Self.migratedDeviceToolSelection(deviceAgentDefaults.enabledTools)
      draftDeviceSettings.enabledTools = Self.migratedDeviceToolSelection(draftDeviceSettings.enabledTools)
      for id in executionRecords.keys { executionRecords[id]?.goalLedger?.recover() }
      for id in executionRecords.keys where executionRecords[id]?.status == "running" {
        executionRecords[id]?.status = "interrupted"
      }
      try persistExecutionConfiguration()
    }
    restoreAgentCatalog()
    try await store?.restoreExecutionProjection()
    for record in executionRecords.values where record.isTrashed != true { try await adoptDeviceConversation(record, transcript: nil) }
    await reload()
  }
  func persistExecutionConfiguration() throws {
    guard let executionDirectory else { throw DeviceExecutionError.unavailable("The device workspace could not be opened.") }
    let saved = DeviceExecutionPreferences(connections: inferenceConnections, selectedConnectionID: inferenceConnectionID,
                                           workspaceID: executionWorkspaceID, conversations: executionRecords, agentDefaults: deviceAgentDefaults, chatSettings: draftDeviceSettings)
    try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
    try JSONEncoder().encode(saved).write(to: executionDirectory.appendingPathComponent("preferences.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  func saveInferenceConnection(_ connection: InferenceConnection, secret: String) async throws {
    guard !fixture, !isolatedTestHost else { throw DeviceExecutionError.unavailable("Use the regular app to configure inference connections.") }
    guard let executionDirectory else { throw DeviceExecutionError.unavailable("The device workspace could not be opened.") }
    let saved = try await InferenceConnectionSaveTransaction.save(connection, secret: secret, existing: inferenceConnections,
      credentials: executionCredentialStore) { saved in
      var connections = inferenceConnections.filter { $0.id != connection.id }
      connections.append(saved)
      var records = executionRecords
      if let previous = inferenceConnections.first(where: { $0.id == connection.id }) {
        for id in records.keys where records[id]?.connectionID == previous.id && records[id]?.connection == nil {
          records[id]?.connection = previous
        }
      }
      let workspaceID = credential == nil && selectedConversationID == nil ? "local" : executionWorkspaceID
      let preferences = DeviceExecutionPreferences(connections: connections, selectedConnectionID: saved.id,
        workspaceID: workspaceID, conversations: records, agentDefaults: deviceAgentDefaults, chatSettings: draftDeviceSettings)
      try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
      try JSONEncoder().encode(preferences).write(to: executionDirectory.appendingPathComponent("preferences.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      executionRecords = records
    }
    inferenceConnections.removeAll { $0.id == connection.id }; inferenceConnections.append(saved)
    inferenceConnectionID = saved.id
    if credential == nil && selectedConversationID == nil { executionWorkspaceID = "local"; providerID = "" }
    inferenceProblem = nil
  }
  func selectExecutionWorkspace(_ id: String) {
    guard selectedConversationID == nil else { return }
    executionWorkspaceID = id; providerID = ""
    if id != "local" { providerID = availableExecutionProviders.first { $0.available && $0.canStart }?.id ?? "" }
    do { try persistExecutionConfiguration() } catch { errorMessage = error.localizedDescription }
  }
  func selectInferenceConnection(_ id: String) {
    guard selectedConversationID == nil else { return }
    inferenceConnectionID = id
    do { try persistExecutionConfiguration() } catch { errorMessage = error.localizedDescription }
  }

  func sendOnDevice(userInitiated: Bool = true) async {
    guard !sending, !startingChat, selectedConversationID.map({ !configuringDeviceSessions.contains($0) }) ?? true, executionOnline, activeRunID == nil, !canResumeLocalRun,
          !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard let connection = selectedInferenceConnection else { executionSettingsPresented = true; return }
    let sourceKey = draftKey, text = composer, draft = currentDraft, noteID = referencedNoteID
    let defaults = deviceAgentDefaults
    let chatSettings = draftDeviceSettings
    let selection = selectedConversationID
    let id = selection ?? UUID().uuidString.lowercased()
    guard localRunTokens[id] == nil, !localStopping.contains(id), !localInterrupting.contains(id), executionRecords[id]?.status != "stopping" else { return }
    sending = true; configuringDeviceSessions.insert(id)
    defer { sending = false; configuringDeviceSessions.remove(id) }
    var attemptID: String?
    await flushLocalWrites()
    do {
      if executionRecords[id] == nil {
        let service = CompanionInferenceService(connection: connection, credentials: executionCredentialStore)
        let model = try await service.model()
        executionRecords[id] = .init(id: id, title: String(text.prefix(80)), folderID: selectedFolderID,
          enabledTools: chatSettings.enabledTools ?? defaults.enabledTools, thinkingLevel: chatSettings.thinkingLevel.flatMap { model.supportedThinkingLevels.contains($0) ? $0 : nil } ?? defaults.thinking(for: model), permissionMode: chatSettings.permissionMode, executionPolicy: defaults.executionPolicy ?? .init(), additionalInstructions: defaults.instructions, connectionID: connection.id, connection: connection, modelJSON: try model.descriptorJSON(), status: "ready", updatedAt: Self.executionTimestamp())
        try persistExecutionConfiguration()
        if userInitiated { await analytics.record(.active) }
      }
      if executionRecords[id]?.title == "New chat", state.transcripts[id]?.messages.isEmpty != false {
        executionRecords[id]?.title = String(text.prefix(80))
        try persistExecutionConfiguration()
      }
      let runtime = try await deviceRuntime(id)
      let requestID = UUID().uuidString.lowercased()
      var prompt = WorkspaceGoalCommand(text)?.agentPrompt ?? text
      executionRecords[id]?.inputAssetID = noteID
      executionRecords[id]?.goalUsageBaseline = try await deviceTokenUsage(runtime)
      executionRecords[id]?.goalLedger?.enroll(requestID)
      if (try? deviceToolContext(conversationID: id).enabled.contains(.goals)) == true { prompt += WorkspaceGoal.guidance }
      executionRecords[id]?.runID = requestID; executionRecords[id]?.status = "running"
      executionRecords[id]?.pendingInput = prompt
      executionRecords[id]?.sourceDraftKey = sourceKey; executionRecords[id]?.sourceDraft = draft
      executionRecords[id]?.updatedAt = Self.executionTimestamp()
      try persistExecutionConfiguration()
      if selectedConversationID == selection { selectedConversationID = id }
      if userInitiated { await analytics.record(.active) }
      attemptID = beginDeviceExecutionAttempt(id, runID: requestID, runtime: runtime, userInitiated: userInitiated)
      let receipt = try await runtime.submit(text: prompt, requestID: requestID)
      guard executionRecords[id]?.runID == requestID, executionRecords[id]?.status == "running" else { return }
      let object = try Self.executionObject(receipt)
      let submissionID = (object["submissionId"] ?? object["submissionID"] ?? object["id"]) as? Int
      guard let submissionID else { throw DeviceExecutionError.unavailable("Pi Durable accepted a message but returned an unreadable receipt. Reopen this conversation to recover its saved state.") }
      executionRecords[id]?.submissionID = submissionID
      executionRecords[id]?.pendingInput = nil
      try persistExecutionConfiguration()
      if selectedConversationID == selection { selectedConversationID = id }
      clearAcknowledgedDeviceDraft(id)
      inferenceProblem = nil
      await refreshDeviceTranscript(id)
      guard executionRecords[id]?.runID == requestID, executionRecords[id]?.status == "running" else { return }
      observeDeviceRun(id, submissionID: submissionID, runtime: runtime)
    } catch {
      if localInterrupting.contains(id) || attemptID.map({ localExecutionAttempts[id] != $0 }) == true { return }
      if let runID = executionRecords[id]?.runID, let runtime = localRuntimes[id], let attemptID {
        await interruptDeviceExecution(id, runID: runID, attemptID: attemptID, runtime: runtime)
      } else if executionRecords[id]?.status != "stopped" && executionRecords[id]?.status != "stopping" {
        executionRecords[id]?.status = executionRecords[id]?.runID == nil ? "failed" : "interrupted"
        try? persistExecutionConfiguration()
      }
      inferenceProblem = error.localizedDescription; errorMessage = error.localizedDescription
      await refreshDeviceTranscript(id)
    }
  }
  func deviceRuntime(_ id: String) async throws -> PiDurableRuntime {
    guard !localInterrupting.contains(id) else { throw DeviceExecutionError.unavailable("This agent is saving its progress. Try again when it finishes.") }
    if let existing = localRuntimes[id] { try await finishDeviceCancellation(id, runtime: existing); return existing }
    guard let record = executionRecords[id], let root = executionDirectory,
          let connection = record.connection ?? inferenceConnections.first(where: { $0.id == record.connectionID }) else { throw InferenceError.missingCredential }
    let pinned = try JSONDecoder().decode(InferenceModel.self, from: Data(record.modelJSON.utf8))
    let service = CompanionInferenceService(connection: connection, credentials: executionCredentialStore, model: pinned)
    let runtime = try PiDurableRuntime(storageDirectory: root.appendingPathComponent("sessions/" + id, isDirectory: true),
      configuration: .init(conversationID: id, modelJSON: record.modelJSON, toolsJSON: try toolsJSON(for: record),
        instructions: Self.instructions(for: record), thinkingLevel: record.thinkingLevel ?? "off", executionPolicy: record.executionPolicy ?? deviceAgentDefaults.executionPolicy ?? .init()),
      inference: { request, emit in try await service.stream(requestJSON: request, emit: emit) },
      tool: { [weak self] request in
        guard let self else { throw CancellationError() }
        return try await self.performDeviceTool(request)
      },
      onEvents: { [weak self] events in
        self?.recordDeviceExecutionProgress(id, events: events)
        self?.scheduleDeviceTranscriptRefresh(id)
      })
    localRuntimes[id] = runtime
    do { try await runtime.open(); try await finishDeviceCancellation(id, runtime: runtime) }
    catch { localRuntimes.removeValue(forKey: id); throw error }
    return runtime
  }
  func openDeviceConversation(_ id: String) async {
    guard !fixture, !localInterrupting.contains(id) else { return }
    do { _ = try await deviceRuntime(id); await refreshDeviceTranscript(id); await exportDeviceNativeHistory(id) }
    catch { errorMessage = error.localizedDescription }
  }
  func observeDeviceRun(_ id: String, submissionID: Int, runtime: PiDurableRuntime) {
    guard !localInterrupting.contains(id), localRunTokens[id] == nil, let runID = executionRecords[id]?.runID else { return }
    // Tool/scheduled submissions attach observers without requesting user-started OS grants.
    let attemptID = localExecutionAttempts[id] ?? beginDeviceExecutionAttempt(id, runID: runID, runtime: runtime, userInitiated: false)
    let token = UUID().uuidString
    localRunTokens[id] = token
    localRunTasks[id] = Task { [weak self] in
      do {
        let receipt = try Self.executionObject(await runtime.wait(submissionID: submissionID))
        guard let self, self.localRunTokens[id] == token, self.localExecutionAttempts[id] == attemptID else { return }
        if self.executionRecords[id]?.status != "stopped" && self.executionRecords[id]?.status != "stopping" {
          let status = receipt["status"] as? String == "done" ? "completed" : "failed"
          // The SDK result is durable; keep our run recoverable until the inbox receipt is too.
          // A persistence error closes this attempt as interrupted rather than losing its ID.
          try await self.completeDeviceToolSubmission(requestID: runID, status: status, error: receipt["reason"] as? String)
          guard self.localRunTokens[id] == token, self.localExecutionAttempts[id] == attemptID else { return }
          let usage = try await self.deviceTokenUsage(runtime)
          let baseline = self.executionRecords[id]?.goalUsageBaseline
          self.executionRecords[id]?.goalLedger?.settle(runID, tokens: usage.flatMap { total in baseline.flatMap { total >= $0 ? total - $0 : nil } }, succeeded: status == "completed")
          self.executionRecords[id]?.status = status
          if let reason = receipt["reason"] as? String { self.inferenceProblem = reason; self.errorMessage = reason }
        }
        self.finishDeviceExecutionAttempt(id, runID: runID, attemptID: attemptID,
          success: self.executionRecords[id]?.status == "completed")
        if self.executionRecords[id]?.status != "stopping" {
          self.executionRecords[id]?.runID = nil; self.executionRecords[id]?.submissionID = nil
        }
        try self.persistExecutionConfiguration()
      } catch {
        guard let self, self.localRunTokens[id] == token else { return }
        if self.executionRecords[id]?.status == "running" {
          await self.interruptDeviceExecution(id, runID: runID, attemptID: attemptID, runtime: runtime)
          self.errorMessage = error.localizedDescription
          return
        }
        self.finishDeviceExecutionAttempt(id, runID: runID, attemptID: attemptID, success: false)
        try? self.persistExecutionConfiguration()
      }
      guard let self, self.localRunTokens[id] == token else { return }
      self.localRunTokens.removeValue(forKey: id)
      self.localRunTasks.removeValue(forKey: id)
      await self.refreshDeviceTranscript(id)
      await self.exportDeviceNativeHistory(id)
      self.endIdleExecutionBackgroundTask()
      await self.refreshDeviceToolSubmissions()
      if UIApplication.shared.applicationState == .active { await self.processDeviceToolSubmissions() }
    }
  }
  func resumeDeviceRun(userInitiated: Bool = true) async {
    guard let id = selectedConversationID, canResumeLocalRun, !sending, !configuringDeviceSessions.contains(id),
          let requestID = executionRecords[id]?.runID else { return }
    sending = true; configuringDeviceSessions.insert(id)
    defer { sending = false; configuringDeviceSessions.remove(id) }
    var attemptID: String?
    do {
      executionRecords[id]?.status = "running"
      try persistExecutionConfiguration()
      let runtime = try await deviceRuntime(id)
      guard executionRecords[id]?.runID == requestID, executionRecords[id]?.status == "running" else { return }
      attemptID = beginDeviceExecutionAttempt(id, runID: requestID, runtime: runtime, userInitiated: userInitiated)
      if let pendingInput = executionRecords[id]?.pendingInput {
        let receipt = try Self.executionObject(await runtime.submit(text: pendingInput, requestID: requestID))
        guard executionRecords[id]?.runID == requestID, executionRecords[id]?.status == "running" else { return }
        guard let submissionID = receipt["id"] as? Int else { throw DeviceExecutionError.unavailable("The saved submission could not be recovered.") }
        executionRecords[id]?.submissionID = submissionID; executionRecords[id]?.pendingInput = nil
      }
      guard let submissionID = executionRecords[id]?.submissionID else { throw DeviceExecutionError.unavailable("This conversation has no saved submission to resume. Stop the saved run before sending a new message.") }
      try await runtime.resume()
      guard executionRecords[id]?.runID == requestID, executionRecords[id]?.status == "running" else { return }
      try persistExecutionConfiguration()
      clearAcknowledgedDeviceDraft(id)
      observeDeviceRun(id, submissionID: submissionID, runtime: runtime)
      await refreshDeviceTranscript(id)
    } catch {
      if localInterrupting.contains(id) || attemptID.map({ localExecutionAttempts[id] != $0 }) == true { return }
      if let runtime = localRuntimes[id], let attemptID {
        await interruptDeviceExecution(id, runID: requestID, attemptID: attemptID, runtime: runtime)
      } else if executionRecords[id]?.runID == requestID, executionRecords[id]?.status == "running" {
        executionRecords[id]?.status = "interrupted"
        try? persistExecutionConfiguration()
      }
      errorMessage = error.localizedDescription
    }
  }
  func clearAcknowledgedDeviceDraft(_ id: String) {
    guard let record = executionRecords[id], let key = record.sourceDraftKey, let draft = record.sourceDraft else { return }
    if (draftBuffer[key] ?? state.chatDrafts[key]) == draft { updateChatDraft(key: key, draft: .init(text: "")) }
  }
  func stopOnDevice() async {
    guard let id = selectedConversationID, !localStopping.contains(id), !localInterrupting.contains(id) else { return }
    do { try await stopDeviceConversation(id) } catch { errorMessage = error.localizedDescription }
  }
  func stopDeviceConversation(_ id: String) async throws {
    guard !localStopping.contains(id), !localInterrupting.contains(id) else { throw DeviceExecutionError.unavailable("This session is already stopping.") }
    localStopping.insert(id); defer { localStopping.remove(id) }
    do {
      // Commit cancellation intent before touching the SDK. Reopening must finish this abort before any new input.
      executionRecords[id]?.goalLedger?.recover()
      executionRecords[id]?.status = "stopping"; try persistExecutionConfiguration()
      cancelDeviceApprovals(id)
      let runtime = try await deviceRuntime(id)
      try await finishDeviceCancellation(id, runtime: runtime)
      await refreshDeviceTranscript(id)
    } catch {
      if let runID = executionRecords[id]?.runID {
        finishDeviceExecutionAttempt(id, runID: runID, attemptID: localExecutionAttempts[id], success: false)
      }
      if let runtime = localRuntimes[id] {
        try? await runtime.close()
        if localRuntimes[id] === runtime { localRuntimes.removeValue(forKey: id) }
      }
      throw error
    }
    await refreshDeviceToolSubmissions()
  }
  func finishDeviceCancellation(_ id: String, runtime: PiDurableRuntime) async throws {
    guard let record = executionRecords[id], record.status == "stopping" || record.status == "stopped" && record.runID != nil else { return }
    localRunTokens.removeValue(forKey: id)
    localRunTasks.removeValue(forKey: id)?.cancel()
    try await runtime.abort()
    if let runID = record.runID {
      let usage = try await deviceTokenUsage(runtime)
      executionRecords[id]?.goalLedger?.settle(runID, tokens: usage.flatMap { total in record.goalUsageBaseline.flatMap { total >= $0 ? total - $0 : nil } }, succeeded: false)
      try await completeDeviceToolSubmission(requestID: runID, status: "cancelled")
      finishDeviceExecutionAttempt(id, runID: runID, attemptID: localExecutionAttempts[id], success: false)
    }
    executionRecords[id]?.status = "stopped"
    executionRecords[id]?.runID = nil; executionRecords[id]?.submissionID = nil; executionRecords[id]?.pendingInput = nil
    try persistExecutionConfiguration()
    endIdleExecutionBackgroundTask()
  }
  func scheduleDeviceTranscriptRefresh(_ id: String) {
    guard executionRefreshTasks[id] == nil else { return }
    executionRefreshTasks[id] = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(120))
      await self?.refreshDeviceTranscript(id)
      self?.executionRefreshTasks.removeValue(forKey: id)
    }
  }
  func refreshDeviceTranscript(_ id: String) async {
    guard let runtime = localRuntimes[id], !deviceSnapshotInProgress.contains(id) else { return }
    deviceSnapshotInProgress.insert(id); defer { deviceSnapshotInProgress.remove(id) }
    do {
      let object = try Self.executionObject(await runtime.snapshot())
      guard let record = executionRecords[id] else { return }
      let transcript = CompanionDeviceTranscript.project(snapshot: object, conversationID: id,
        activeRunID: record.status == "running" ? record.runID : nil,
        runStatus: record.status == "idle" ? "completed" : record.status)
      try await adoptDeviceConversation(record, transcript: transcript)
      await reload()
    } catch {
      guard !localInterrupting.contains(id), localRuntimes[id] === runtime else { return }
      errorMessage = "Couldn’t save execution history: " + error.localizedDescription
    }
  }
  func adoptDeviceConversation(_ record: DeviceConversationRecord, transcript: CompanionTranscript?) async throws {
    guard record.isTrashed != true else { return }
    let conversation = CompanionConversation(id: record.id, title: record.title, folderID: record.folderID,
      providerID: "pi-durable-device", routeID: deviceWorkspaceID, runtimeKind: "pi", activeRunID: record.status == "running" ? record.runID : nil,
      preview: String((transcript?.messages.last?.content ?? state.conversations[record.id]?.preview ?? "").unicodeScalars.prefix(512)), updatedAt: record.updatedAt, isPinned: record.isPinned)
    try await store?.adoptExecution(conversation: conversation, transcript: transcript)
    // The durable workspace journal also retains history for central synchronization.
    try await recordDeviceHistory(conversation: conversation, transcript: transcript)
  }
  static func executionTimestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
  static func executionObject(_ text: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw DeviceExecutionError.unavailable("The execution record could not be read.") }
    return object
  }
  static func messageText(_ value: Any?) -> String {
    if let text = value as? String { return text }
    return (value as? [[String: Any]] ?? []).compactMap { block in
      if block["type"] as? String == "text" { return block["text"] as? String }
      if block["type"] as? String == "toolCall" { return (block["name"] as? String).map { "Tool: " + $0 } }
      return nil
    }.joined(separator: "\n")
  }
  func exportDeviceNativeHistory(_ id: String) async {
    guard let runtime = localRuntimes[id], let store else { return }
    do {
      var conversations: [Int] = [], conversationCursor: String?
      repeat {
        let page = try Self.executionObject(await runtime.conversations(cursorJSON: conversationCursor))
        conversations += (page["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int }
        conversationCursor = try page["next"].flatMap { $0 is NSNull ? nil : String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self) }
      } while conversationCursor != nil
      for nativeID in conversations {
        var cursor: String?
        repeat {
          let page = try Self.executionObject(await runtime.history(nativeConversationID: nativeID, cursorJSON: cursor))
          for entry in page["items"] as? [[String: Any]] ?? [] {
            let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try await store.journal.appendNativeRecord(workspaceID: deviceWorkspaceID, conversationID: id,
              recordID: "pi-\(id)-\(nativeID)-\(entry["id"] as? Int ?? 0)-\(digest)", format: "pi-durable.entry.v1", data: data)
          }
          cursor = try page["next"].flatMap { $0 is NSNull ? nil : String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self) }
        } while cursor != nil
      }
    } catch {
      guard !localInterrupting.contains(id), localRuntimes[id] === runtime else { return }
      errorMessage = "Native history is saved in this workspace but could not be queued for central sync: " + error.localizedDescription
    }
  }
  func sceneChanged(_ phase: ScenePhase) {
    switch phase {
    case .active:
      connectionDidBecomeActive()
      endExecutionBackgroundTask()
      if !fixture && !isolatedTestHost { startDeviceScheduler() }
    case .inactive:
      connectionForeground = false
      stopDeviceScheduler()
    case .background:
      connectionForeground = false
      stopDeviceScheduler()
      beginFallbackExecutionBackgroundTask()
    @unknown default: break
    }
  }
}
