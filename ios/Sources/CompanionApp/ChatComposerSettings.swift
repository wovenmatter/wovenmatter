import SwiftUI
import CompanionClient
import CompanionInference
import WovenMatterCompanion

private struct ChatModelOption: Identifiable {
  var connection: InferenceConnection
  var descriptor: InferenceModel
  var id: String { connection.id + ":" + descriptor.id }
}

struct ChatComposerSettings: View {
  @Bindable var model: CompanionModel
  @Environment(\.dashboardTheme) private var theme
  @State private var settings: CompanionSessionSettings?
  @State private var modelOpen = false
  @State private var thinkingOpen = false
  @State private var toolsOpen = false
  @State private var options: [ChatModelOption] = []
  @State private var search = ""
  @State private var loading = false
  @State private var saving = false
  @State private var problem: String?
  @State private var pendingTools: [String]?
  @State private var confirmTimers = false
  private var local: Bool { model.selectedExecutionWorkspaceID == "local" }
  private var context: String { model.selectedExecutionWorkspaceID + ":" + (model.selectedConversationID ?? model.providerID) }
  private var configurable: Bool { !saving && (local ? model.canConfigureDeviceChat : settings?.canConfigure == true && model.executionOnline) }
  private var connectionGroups: [InferenceConnection] {
    var values = model.inferenceConnections
    if let selected = model.selectedInferenceConnection, !values.contains(where: { $0.id == selected.id }) { values.insert(selected, at: 0) }
    return values
  }
  private var modelLabel: String {
    if local { return model.deviceChatModel?.name ?? model.selectedInferenceConnection?.modelID ?? "Model" }
    return settings?.models.first { $0.id == settings?.model }?.label ?? "Model"
  }
  private var thinkingOptions: [CompanionSelection] {
    local ? (model.deviceChatModel?.supportedThinkingLevels ?? []).map { .init(id: $0, label: $0 == "xhigh" ? "Extra high" : $0.capitalized) } : settings?.thinkingLevels ?? []
  }
  private var thinkingLabel: String {
    thinkingOptions.first { $0.id == (local ? model.deviceChatThinking : settings?.thinking) }?.label ?? "Thinking"
  }
  private var toolOptions: [CompanionSelection] {
    local ? CompanionModel.deviceToolDefinitions.compactMap {
      guard let name = $0["name"] as? String else { return nil }
      return .init(id: name, label: name.replacingOccurrences(of: "_", with: " ").capitalized)
    } : settings?.availableTools ?? []
  }
  private var enabledTools: [String] { local ? model.deviceChatTools : settings?.enabledTools ?? [] }
  var body: some View {
    Group {
      Button { dismissKeyboard(); problem = nil; modelOpen = true } label: {
        HStack(spacing: 3) {
          Text(modelLabel).lineLimit(1)
          DashboardLucideIcon(glyph: .chevronDown, size: 10)
        }.font(.caption.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
      }.buttonStyle(.plain).accessibilityLabel("Choose model").disabled(saving)
        .popover(isPresented: $modelOpen) {
          popout("Model", height: min(420, max(160, CGFloat(local ? options.count : settings?.models.count ?? 0) * 44 + 130))) {
            DashboardSearchField(text: $search, prompt: "Search models").padding(.bottom, 8)
            if local {
              if options.isEmpty && !loading { Text("No signed-in providers.").font(.callout).foregroundStyle(DashboardPalette.mutedForeground) }
              ForEach(connectionGroups) { connection in
                let matches = options.filter { $0.connection.id == connection.id && (search.isEmpty || $0.descriptor.name.localizedCaseInsensitiveContains(search)) }
                if !matches.isEmpty {
                  Text(connection.name).font(.caption.weight(.semibold)).foregroundStyle(DashboardPalette.mutedForeground).padding(.top, 10)
                  ForEach(matches) { option in
                    selectionRow(option.descriptor.name, selected: model.selectedInferenceConnection?.id == option.connection.id && model.selectedInferenceConnection?.modelID == option.descriptor.id) {
                      var connection = option.connection; connection.modelID = option.descriptor.id; connection.selectedModel = option.descriptor
                      Task { await apply { try await model.configureDeviceChat(connection: connection) }; if problem == nil { modelOpen = false } }
                    }
                  }
                }
              }
            } else {
              ForEach((settings?.models ?? []).filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }) { option in
                selectionRow(option.label, selected: option.id == settings?.model) { configureRemote(modelID: option.id) }
              }
              if settings?.models.isEmpty != false && !loading { Text("No model choices available.").font(.callout).foregroundStyle(DashboardPalette.mutedForeground) }
            }
          }.task { if local { await loadModels() } else { await loadSession() } }
        }
      Button { dismissKeyboard(); problem = nil; thinkingOpen = true } label: {
        HStack(spacing: 3) {
          DashboardLucideIcon(glyph: .brain, size: 16)
          Text(thinkingLabel).lineLimit(1).minimumScaleFactor(0.8)
        }.font(.caption.weight(.medium)).frame(minWidth: 44, minHeight: 44)
      }.buttonStyle(.plain).accessibilityLabel("Thinking level").disabled(thinkingOptions.isEmpty || !configurable)
        .popover(isPresented: $thinkingOpen) {
          popout("Thinking Level", height: min(380, CGFloat(thinkingOptions.count) * 44 + 70)) {
            ForEach(thinkingOptions) { option in
              selectionRow(option.label, selected: option.id == (local ? model.deviceChatThinking : settings?.thinking)) {
                if local { Task { await apply { try await model.configureDeviceChat(thinking: option.id) }; if problem == nil { thinkingOpen = false } } }
                else { configureRemote(thinking: option.id) }
              }
            }
          }
        }
      Button { dismissKeyboard(); problem = nil; toolsOpen = true } label: {
        HStack(spacing: 3) { Text("Tools"); DashboardLucideIcon(glyph: .chevronDown, size: 10) }
          .font(.caption.weight(.medium)).frame(minWidth: 44, minHeight: 44)
      }.buttonStyle(.plain).accessibilityLabel("Session tools").disabled(saving)
        .popover(isPresented: $toolsOpen) {
          popout("Tools") {
            ForEach(toolOptions) { tool in
              Toggle(tool.label, isOn: Binding(get: { enabledTools.contains(tool.id) }, set: { enabled in
                var tools = Set(enabledTools)
                if enabled { tools.insert(tool.id) } else { tools.remove(tool.id) }
                if !local && tool.id == "timers" && !enabled { pendingTools = tools.sorted(); confirmTimers = true }
                else { saveTools(tools.sorted(), confirmed: false) }
              })).disabled(!configurable).frame(minHeight: 44)
            }
            if toolOptions.isEmpty { Text("No configurable tools.").font(.callout).foregroundStyle(DashboardPalette.mutedForeground) }
          }.confirmationDialog("Removing timer access pauses this session’s timers.", isPresented: $confirmTimers, titleVisibility: .visible) {
            Button("Pause timers and remove access") { if let pendingTools { saveTools(pendingTools, confirmed: true) } }
            Button("Cancel", role: .cancel) { pendingTools = nil }
          }
        }
    }
    .task(id: context) { settings = nil; problem = nil; if !local { await loadSession() } }
    .onChange(of: model.activeRunID) { Task { if !local { await loadSession() } } }
  }
  private func dismissKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
  private func popout<Content: View>(_ title: String, height: CGFloat = 380, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      ScrollView { VStack(alignment: .leading, spacing: 6) { content() }.frame(maxWidth: .infinity, alignment: .leading) }
      if loading || saving { ProgressView() }
      if let problem { Text(problem).font(.caption).foregroundStyle(DashboardPalette.danger) }
    }.padding(18).frame(width: 310, height: height).background(theme.palette.workspace)
      .foregroundStyle(DashboardPalette.foreground).scrollIndicators(.never)
      .presentationCompactAdaptation(.popover)
  }
  private func selectionRow(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack { Text(label).multilineTextAlignment(.leading); Spacer(); if selected { DashboardLucideIcon(glyph: .check, size: 16) } }
        .font(.callout).frame(minHeight: 44).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(!configurable).accessibilityAddTraits(selected ? .isSelected : [])
  }
  private func loadModels() async {
    let target = context
    loading = true; defer { loading = false }
    var connections = model.inferenceConnections
    if let selected = model.selectedInferenceConnection, !connections.contains(where: { $0.id == selected.id }) { connections.insert(selected, at: 0) }
    options = connections.compactMap { connection in connection.selectedModel.map { ChatModelOption(connection: connection, descriptor: $0) } }
    if let connection = model.selectedInferenceConnection, let descriptor = model.deviceChatModel {
      let selected = ChatModelOption(connection: connection, descriptor: descriptor)
      if !options.contains(where: { $0.id == selected.id }) { options.insert(selected, at: 0) }
    }
    for connection in connections {
      guard !Task.isCancelled, target == context else { return }
      if model.fixture || model.isolatedTestHost || connection.provider.hasPrefix("local-server-") { continue }
      do {
        let models = try await CompanionInferenceService(connection: connection, credentials: model.executionCredentialStore).catalog()
        guard !Task.isCancelled, target == context else { return }
        for descriptor in models {
          let option = ChatModelOption(connection: connection, descriptor: descriptor)
          if !options.contains(where: { $0.id == option.id }) { options.append(option) }
        }
      } catch { if !Task.isCancelled { problem = "Couldn’t refresh all models. Saved models remain available." } }
    }
    options.sort { $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending }
  }
  private func loadSession() async {
    guard let id = model.selectedConversationID else { return }
    let target = context
    loading = true; defer { loading = false }
    do {
      guard case .session(let result) = try await model.workspace(.session(id: id)) else { throw MobileConnectionError.invalidResponse }
      if !Task.isCancelled, target == context { settings = result }
    } catch { if !Task.isCancelled, target == context { problem = "Couldn’t load this agent’s settings." } }
  }
  private func apply(_ operation: () async throws -> Void) async {
    guard !saving else { return }; saving = true; model.chatSettingsBusy = true; problem = nil
    defer { saving = false; model.chatSettingsBusy = false }
    do { try await operation() } catch { problem = error.localizedDescription }
  }
  private func configureRemote(modelID: String? = nil, thinking: String? = nil) {
    guard let id = model.selectedConversationID, configurable else { return }
    Task {
      await apply {
        guard await model.perform(.configureSession(id: id, model: modelID, thinking: thinking, permission: nil)) else { throw DeviceExecutionError.unavailable(model.errorMessage ?? "Couldn’t change this session.") }
        await loadSession()
      }
      if problem == nil { modelOpen = false; thinkingOpen = false }
    }
  }
  private func saveTools(_ tools: [String], confirmed: Bool) {
    guard configurable else { return }
    let id = model.selectedConversationID, isLocal = local
    Task {
      await apply {
        if isLocal { try await model.configureDeviceChat(tools: tools) }
        else if let id {
          guard await model.perform(.sessionTools(id: id, enabled: tools, confirmPausingTimers: confirmed)) else { throw DeviceExecutionError.unavailable(model.errorMessage ?? "Couldn’t change tool access.") }
          await loadSession()
        }
      }
    }
  }
}
