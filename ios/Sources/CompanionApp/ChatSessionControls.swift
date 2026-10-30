import SwiftUI
import CompanionClient
import CompanionInference
import WovenMatterCompanion

extension CompanionModel {
  func startNewChat(with agent: CompanionAgentLauncher) async {
    guard let current = launcherAgents.first(where: { $0.id == agent.id }) else { return }
    guard current.isAvailable else {
      chatSetupProblem = workspaceIsConnected(current.workspaceID) ? "This agent is currently unavailable." : Self.deviceConnectionMessage
      if !chatChooserPresented { errorMessage = chatSetupProblem }
      return
    }
    await startNewChat(workspaceID: agent.workspaceID, agentID: agent.providerID)
  }

  func newChatWithCurrentAgent() async {
    guard !isViewingRemoteQuickChat else { return }
    guard workspaceIsConnected(selectedExecutionWorkspaceID) else { errorMessage = Self.deviceConnectionMessage; return }
    guard let agent = activeProvider else { newChat(); return }
    let workspaceID = selectedExecutionWorkspaceID
    // The toolbar belongs to the displayed conversation, not the folder most
    // recently browsed in another tab.
    selectedFolderID = selectedConversation?.folderID
    selectedFolderWorkspaceID = canonicalWorkspaceID(workspaceID)
    newChatNoteID = nil
    await startNewChat(workspaceID: workspaceID, agentID: agent.id)
  }

  private func startNewChat(workspaceID: String, agentID: String) async {
    guard !startingChat, !sending, !chatSettingsBusy, let store else { return }
    startingChat = true; chatSetupProblem = nil
    defer { startingChat = false }
    let folder = selectedFolderID, reference = newChatNoteID
    guard routeOwnsFolder(workspaceID: workspaceID, folderID: folder) else {
      chatSetupProblem = "Choose an agent in this folder’s owning workspace."
      if !chatChooserPresented { errorMessage = chatSetupProblem }
      return
    }
    do {
      var conversationID: String?
      if workspaceID == "local", let connection = inferenceConnections.first(where: { $0.id == inferenceConnectionID }) {
        let descriptor = try await CompanionInferenceService(connection: connection, credentials: executionCredentialStore).model()
        let id = UUID().uuidString.lowercased()
        let record = DeviceConversationRecord(id: id, title: "New chat", folderID: folder,
          enabledTools: deviceAgentDefaults.enabledTools, thinkingLevel: deviceAgentDefaults.thinking(for: descriptor), executionPolicy: deviceAgentDefaults.executionPolicy ?? .init(), additionalInstructions: deviceAgentDefaults.instructions,
          connectionID: connection.id, connection: connection, modelJSON: try descriptor.descriptorJSON(), status: "ready", updatedAt: Self.executionTimestamp())
        executionRecords[id] = record
        do { try persistExecutionConfiguration() } catch { executionRecords.removeValue(forKey: id); throw error }
        await analytics.record(.active)
        try await adoptDeviceConversation(record, transcript: .init(conversationID: id))
        await reload(); conversationID = id
      } else if workspaceID != "local" {
        try await requireWorkspaceConnection(workspaceID)
        let agents = workspaceID == "central" ? providers : workspaceProviders[workspaceID] ?? []
        guard (workspaceID == "central" ? online : workspaceReachable[workspaceID] == true),
              agents.contains(where: { $0.id == agentID && $0.available && $0.canStart }) else {
          throw DeviceExecutionError.unavailable("This agent is currently unavailable.")
        }
        try await prepareExecutionFolder(folder, workspaceID: workspaceID)
        let records = workspaceID == "central" ? await store.snapshot().commands : await store.journal.commandRecords(workspaceID: workspaceID)
        let launchCommands = Set(await store.snapshot().launches.map { $0.create.commandID })
        let pending = records.first {
          $0.command.commandID == pendingChatCreation?.commandID && $0.command.providerID == agentID &&
            $0.command.folderID == folder && !launchCommands.contains($0.id) && $0.receipt?.status != .rejected
        } ?? records.first {
          $0.command.kind == .createSession && $0.command.providerID == agentID && $0.command.folderID == folder &&
            !launchCommands.contains($0.id) && $0.receipt?.status != .completed && $0.receipt?.status != .rejected
        }
        var command = pending?.command ?? CompanionCommand(deviceID: state.deviceID, kind: .createSession,
          conversationID: UUID().uuidString.lowercased(), providerID: agentID, folderID: folder)
        if workspaceID != "central" { command.workspaceID = workspaceID }
        pendingChatCreation = command
        let receipt: CompanionCommandReceipt
        if workspaceID == "central" {
          guard let engine else { throw MobileConnectionError.offline }
          receipt = try await engine.submit(command)
        } else {
          guard let client = workspaceClients[workspaceID] else { throw MobileConnectionError.offline }
          receipt = try await client.submit(command)
        }
        if receipt.status == .rejected { pendingChatCreation = nil }
        guard receipt.status == .completed, let id = command.conversationID else {
          throw DeviceExecutionError.unavailable(receipt.message ?? "The workspace has not confirmed this chat yet. Try again to recover its acknowledgement.")
        }
        pendingChatCreation = nil
        conversationID = id
        conversationWorkspaceIDs[id] = workspaceID
      }
      await flushLocalWrites()
      selectedConversationID = conversationID; executionWorkspaceID = workspaceID; providerID = agentID
      draftDeviceSettings = .init(enabledTools: deviceAgentDefaults.enabledTools)
      if let reference { referencedNoteID = reference }
      newChatNoteID = nil; chatChooserPresented = false; tab = .chat
      try persistExecutionConfiguration()
      if workspaceID != "local" { await refreshConversation() }
    } catch {
      chatSetupProblem = workspaceActionMessage(error)
      if !chatChooserPresented { errorMessage = chatSetupProblem }
    }
  }

  var deviceChatModel: InferenceModel? {
    if let id = selectedConversationID, let record = executionRecords[id] {
      return try? JSONDecoder().decode(InferenceModel.self, from: Data(record.modelJSON.utf8))
    }
    return selectedInferenceConnection?.selectedModel
  }
  var deviceChatThinking: String {
    selectedConversationID.flatMap { executionRecords[$0]?.thinkingLevel } ?? (selectedConversationID == nil ? draftDeviceSettings.thinkingLevel ?? deviceAgentDefaults.thinking(for: deviceChatModel) : "off")
  }
  var deviceChatPermission: DevicePermissionMode {
    selectedConversationID.flatMap { executionRecords[$0]?.permissionMode } ?? (selectedConversationID == nil ? draftDeviceSettings.permissionMode ?? .defaultMode : .defaultMode)
  }
  static var devicePermissionOptions: [CompanionSelection] {
    DevicePermissionMode.allCases.map { .init(id: $0.rawValue, label: $0.label) }
  }
  var deviceChatTools: [String] {
    let enabled = selectedConversationID.flatMap { executionRecords[$0]?.enabledTools } ?? (selectedConversationID == nil ? draftDeviceSettings.enabledTools ?? deviceAgentDefaults.enabledTools : nil)
    return Self.deviceToolAccessOptions.map(\.id).filter { Self.deviceToolEnabled($0, selection: enabled) }
  }
  var canConfigureDeviceChat: Bool { canConfigureDeviceChat(selectedConversationID) }
  private func canConfigureDeviceChat(_ id: String?) -> Bool {
    guard !sending, !startingChat, !fixture else { return false }
    guard let id else { return true }
    guard let record = executionRecords[id], record.quickChatVersion == 1 else { return false }
    return !configuringDeviceSessions.contains(id) && localRunTokens[id] == nil && !["running", "stopping", "interrupted"].contains(record.status)
  }

  /// Session changes never edit the account's saved defaults or another conversation.
  func configureDeviceChat(connection: InferenceConnection? = nil, thinking: String? = nil, permission: DevicePermissionMode? = nil, tools: [String]? = nil, conversationID: String? = nil) async throws {
    let id = conversationID ?? selectedConversationID
    guard canConfigureDeviceChat(id) else { throw DeviceExecutionError.unavailable("Finish or stop this run before changing its settings.") }
    let workspaceID = selectedExecutionWorkspaceID, agentID = providerID
    if let id { configuringDeviceSessions.insert(id) }
    defer { if let id { configuringDeviceSessions.remove(id) } }
    if let tools {
      let available = Set(Self.deviceToolDefinitions.compactMap { $0["name"] as? String } + Self.deviceToolAccessOptions.map(\.id))
      guard Set(tools).isSubset(of: available) else { throw InferenceError.invalidConfiguration }
    }
    let selected: InferenceModel?
    if let connection { selected = try await CompanionInferenceService(connection: connection, credentials: executionCredentialStore).model() }
    else if let id, let record = executionRecords[id] { selected = try JSONDecoder().decode(InferenceModel.self, from: Data(record.modelJSON.utf8)) }
    else { selected = deviceChatModel }
    if let thinking, selected?.supportedThinkingLevels.contains(thinking) != true { throw InferenceError.invalidConfiguration }
    if let id, var record = executionRecords[id] {
      // The runtime captures its credential/model binding; reopen it only after the idle change is saved.
      try await localRuntimes[id]?.close(); localRuntimes.removeValue(forKey: id)
      record.goalLedger = executionRecords[id]?.goalLedger
      let previous = record
      if let connection, let selected { record.connectionID = connection.id; record.connection = connection; record.modelJSON = try selected.descriptorJSON() }
      if let thinking { record.thinkingLevel = thinking }
      if selected?.supportedThinkingLevels.contains(record.thinkingLevel ?? "off") != true { record.thinkingLevel = deviceAgentDefaults.thinking(for: selected) }
      if let permission { record.permissionMode = permission }
      if let tools { record.enabledTools = tools }
      executionRecords[id] = record
      do { try persistExecutionConfiguration() } catch { executionRecords[id] = previous; throw error }
    } else {
      guard selectedConversationID == nil, selectedExecutionWorkspaceID == workspaceID, providerID == agentID else { throw CancellationError() }
      let previous = draftDeviceSettings
      if let connection { draftDeviceSettings.connection = connection }
      if let thinking { draftDeviceSettings.thinkingLevel = thinking }
      if selected?.supportedThinkingLevels.contains(draftDeviceSettings.thinkingLevel ?? "") != true { draftDeviceSettings.thinkingLevel = deviceAgentDefaults.thinking(for: selected) }
      if let permission { draftDeviceSettings.permissionMode = permission }
      if let tools { draftDeviceSettings.enabledTools = tools }
      do { try persistExecutionConfiguration() } catch { draftDeviceSettings = previous; throw error }
    }
  }
}

struct NewChatChooser: View {
  @Environment(\.dashboardTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: CompanionModel
  var body: some View {
    VStack(spacing: 0) {
      header
      if let problem = model.chatSetupProblem {
        Text(problem).font(.caption).foregroundStyle(DashboardPalette.danger)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
          .accessibilityIdentifier("chat-setup-problem")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(model.chatLauncherGroups) { workspace in workspaceSection(workspace) }
        }.padding(.horizontal, 20).padding(.bottom, 24)
      }.scrollIndicators(.never)
    }.background(theme.palette.workspace).foregroundStyle(DashboardPalette.foreground)
      .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
      .interactiveDismissDisabled(model.startingChat)
  }
  private var header: some View {
    HStack {
      Text("New Chat").font(.title3.weight(.semibold))
      Spacer()
      if model.startingChat { ProgressView() }
      Button { dismiss() } label: { DashboardLucideIcon(glyph: .close, size: 20).frame(width: 44, height: 44) }
        .buttonStyle(DashboardIconButtonStyle()).accessibilityLabel("Close agent chooser").disabled(model.startingChat)
    }.padding(.horizontal, 20).padding(.top, 10)
  }
  private func workspaceSection(_ workspace: CompanionAgentGroup) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      GroupLabel(text: workspace.name)
      ForEach(workspace.agents) { agent in agentRow(agent) }
    }
  }
  private func agentRow(_ agent: CompanionAgentLauncher) -> some View {
    Button { Task { await model.startNewChat(with: agent) } } label: {
      HStack(spacing: 12) {
        MobileAgentIcon(runtimeKind: agent.runtimeKind, size: 24)
        Text(agent.name).font(.body.weight(.medium))
        Spacer()
        DashboardLucideIcon(glyph: .arrowRight, size: 16)
      }.frame(minHeight: 44).padding(12)
        .background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius))
    }.buttonStyle(.plain).disabled(model.startingChat)
      .opacity(agent.isAvailable ? 1 : 0.45).accessibilityIdentifier("choose-chat-agent-" + agent.id)
  }
}
