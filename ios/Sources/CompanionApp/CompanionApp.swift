import SwiftUI
import WovenMatterCompanion

@main struct WovenMatterCompanionApp: App {
  @State private var model = CompanionModel()
  @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
  private var theme: DashboardTheme { DashboardTheme(rawValue: storedTheme) ?? .green }
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      ZStack {
        if model.initialized { CompanionShell(model: model) }
        else { ProgressView("Opening your library…") }
      }
        .preferredColorScheme(theme.colorScheme)
        .environment(\.dashboardTheme, theme)
        .background(theme.palette.workspace)
        .task {
          #if DEBUG
          if DeviceRuntimeSmoke.enabled { await DeviceRuntimeSmoke.run(); return }
          #endif
          await model.run()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
          model.sceneChanged(phase)
          if phase == .background { MobileDictation.shared.stop() }
          if phase == .active { Task { await model.analytics.openInterface() } }
        }
        .onOpenURL { url in
          guard url.scheme == "wovenmatter", url.host == "pair" else { return }
          model.tab = .settings; model.pairingPresented = true
          Task { await model.pair(url: url) }
        }
    }
  }
}

struct CompanionShell: View {
  @Bindable var model: CompanionModel
  @Environment(\.dashboardTheme) private var theme
  @State private var keyboardVisible = false
  @State private var hoveredTab: CompanionModel.Tab?
  @State private var navigationReset = UUID()
  @Environment(\.horizontalSizeClass) private var sizeClass
  var body: some View {
    HStack(spacing: 0) {
      if sizeClass == .regular {
        VStack(alignment: .leading, spacing: 0) {
          Text("Woven Matter")
            .font(.title3.weight(.semibold)).padding(24)
          ScrollView {
            VStack(spacing: 4) {
              ForEach(Array(CompanionModel.Tab.allCases.prefix(5)), id: \.self) { tab in sidebarRow(tab) }
              Divider().padding(.vertical, 12)
              ForEach(Array(CompanionModel.Tab.allCases.dropFirst(5).filter { $0 != .trash }), id: \.self) { tab in sidebarRow(tab) }
            }.padding(.horizontal, 12)
          }
        }.frame(width: DashboardMetrics.railWidth).background(theme == .dark ? theme.palette.railFill : theme.palette.themeWhisper)
        Divider()
      }
      VStack(spacing: 0) {
        NavigationStack {
          VStack(spacing: 0) {
            pane
            if CompanionModel.Tab.allCases.prefix(5).contains(model.tab) { CompanionInlineError(model: model).padding(.horizontal, 20) }
          }
            .mobilePageSurface()
            .toolbar(CompanionModel.Tab.allCases.prefix(5).contains(model.tab) ? .hidden : .visible, for: .navigationBar)
            .toolbar {
              if !CompanionModel.Tab.allCases.prefix(5).contains(model.tab) {
                ToolbarItem(placement: .topBarLeading) {
                  Button { model.tab = .home } label: { Label("Home", glyph: .arrowLeft) }.accessibilityIdentifier("back-home")
                }
              }
            }
            .navigationDestination(isPresented: $model.executionSettingsPresented) { ExecutionSettingsPane(model: model) }
            .navigationDestination(isPresented: $model.pairingPresented) { PairingPane(model: model) }
        }.id(model.tab.rawValue + navigationReset.uuidString)
          .frame(maxWidth: 960, maxHeight: .infinity)
          .background(theme.palette.workspace).clipped()
          .frame(maxWidth: .infinity)
        if sizeClass != .regular && !keyboardVisible {
          HStack(spacing: 0) {
            ForEach(Array(CompanionModel.Tab.allCases.prefix(5)), id: \.self) { tab in
              Button { selectTab(tab) } label: {
                VStack(spacing: 5) {
                  DashboardLucideIcon(glyph: tab.icon, size: 22).frame(height: 26)
                  Text(tab.rawValue).font(.caption2.weight(isSelected(tab) ? .semibold : .regular))
                }.padding(9)
                  .foregroundStyle(isSelected(tab) ? DashboardPalette.foreground : DashboardPalette.mutedForeground)
                  .background(isSelected(tab) || hoveredTab == tab ? theme.palette.themeSoft : .clear,
                    in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
                  .contentShape(.interaction, RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
                  .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
                  .hoverEffect(.highlight)
                  .frame(maxWidth: .infinity)
              }.buttonStyle(.plain).padding(.horizontal, 4).padding(.vertical, 6)
                .onHover { hovering in hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab) }
                .accessibilityIdentifier("tab-\(tab.rawValue.lowercased())")
                .accessibilityAddTraits(isSelected(tab) ? .isSelected : [])
            }
          }.background(theme == .dark ? theme.palette.railFill : theme.palette.themeWhisper).overlay(alignment: .top) { Divider() }
        }
      }
    }
    .background(MobileKeyboardDismissal())
    .overlay(alignment: .top) { MobileDictationFeedback() }
    .onChange(of: model.tab) { _, tab in
      if tab != .chat && tab != .note { MobileDictation.shared.stop() }
    }
    .sheet(isPresented: $model.chatChooserPresented, onDismiss: { model.newChatNoteID = nil }) { NewChatChooser(model: model).environment(\.dashboardTheme, theme) }
    .scrollIndicators(.never)
    .foregroundStyle(DashboardPalette.foreground).tint(theme.palette.themeAccent)
    .background(theme.palette.workspace)
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    .environment(\.dashboardTheme, theme)
    .toggleStyle(SwitchToggleStyle(tint: DashboardPalette.primary))
  }
  private func selectTab(_ tab: CompanionModel.Tab) {
    guard !model.startingChat else { return }
    model.executionSettingsPresented = false; model.pairingPresented = false
    // Reselecting a tab returns to its root, as with a native tab bar.
    if model.tab == tab { navigationReset = UUID() }
    model.tab = tab
  }
  private func isSelected(_ tab: CompanionModel.Tab) -> Bool {
    model.tab == tab || (tab == .home && !CompanionModel.Tab.allCases.prefix(5).contains(model.tab))
  }
  private func sidebarRow(_ tab: CompanionModel.Tab) -> some View {
    WorkspaceRow(icon: tab.icon, title: tab.rawValue, selected: model.tab == tab) { selectTab(tab) }
      .accessibilityIdentifier("tab-\(tab.rawValue.lowercased())")
  }
  @ViewBuilder private var pane: some View {
    switch model.tab {
    case .home: HomePane(model: model)
    case .folders: FoldersPane(model: model)
    case .settings: CompanionSettingsPane(model: model)
    case .chat: ChatPane(model: model)
    case .note:
      if let note = model.selectedNote { NotePane(model: model, note: note).id(note.id) }
      else { EmptyNotePane(model: model) }
    case .library: LibraryPane(model: model)
    case .calendar: CalendarPane(model: model)
    case .scheduledTasks: ScheduledTasksPane(model: model)
    case .databases: DatabasesPane(model: model)
    case .usage: UsagePane(model: model)
    case .trash: TrashPane(model: model)
    }
  }

}

struct CompanionInlineError: View {
  @Bindable var model: CompanionModel
  var body: some View {
    if let message = model.errorMessage {
      HStack(alignment: .top, spacing: 8) {
        Text(message).font(.caption).foregroundStyle(DashboardPalette.danger).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("workspace-action-error")
        Button { model.errorMessage = nil } label: { DashboardLucideIcon(glyph: .close, size: 14).frame(width: 44, height: 44) }
          .buttonStyle(.plain).accessibilityLabel("Dismiss error")
      }.padding(.vertical, 8)
    }
  }
}

struct PaneHeader<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing
  var body: some View { HStack(alignment: .center) { Text(title).font(.title.weight(.semibold)).accessibilityIdentifier("pane-heading-" + title.lowercased()); Spacer(); trailing.buttonStyle(DashboardIconButtonStyle()) }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14) }
}
struct WorkspaceRow<Icon: View>: View {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.dashboardTheme) private var theme
  var icon: Icon
  var title: String
  var detail: String? = nil
  var selected = false
  var action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        icon.frame(width: 26)
        Text(title).font(.body.weight(selected ? .semibold : .regular)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        if let detail { Text(detail).font(.caption).foregroundStyle(DashboardPalette.foreground).lineLimit(2) }
      }.padding(.horizontal, 14).padding(.vertical, 13).frame(minHeight: 48)
        .background(selected ? theme.palette.themeSoft : Color.clear, in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
        .contentShape(Rectangle())
    }.buttonStyle(.plain).opacity(isEnabled ? 1 : 0.4).accessibilityAddTraits(selected ? .isSelected : [])
  }
}
extension WorkspaceRow where Icon == DashboardLucideIcon {
  init(icon: DashboardLucideGlyph, title: String, detail: String? = nil, selected: Bool = false, action: @escaping () -> Void) {
    self.init(icon: DashboardLucideIcon(glyph: icon, size: 22), title: title, detail: detail, selected: selected, action: action)
  }
}

struct GroupLabel: View {
  var text: String
  var body: some View { Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(DashboardPalette.foreground).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 22).padding(.bottom, 6) }
}

struct HomePane: View {
  @Environment(\.dashboardTheme) private var theme
  @Bindable var model: CompanionModel
  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Woven Matter") { EmptyView() }
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { quickActions }
            VStack(spacing: 12) { quickActions }
          }.padding(.vertical, 12)
          let groups = model.launcherGroups
          GroupLabel(text: "Workspaces")
          ForEach(groups.filter { $0.id != "local" }) { group in
            GroupLabel(text: group.name)
            workspaceAgents(group)
          }
          if groups.allSatisfy({ $0.id == "local" }) {
            SettingsNavigationRow(title: "Connect your Mac", icon: .monitor) { PairingPane(model: model) }
            Text("Pair once over Tailscale to use your Mac and Linux workspaces. Authorized Linux workspaces remain available when the Mac is offline.")
              .font(.caption).foregroundStyle(DashboardPalette.mutedForeground).padding(.horizontal, 14).padding(.bottom, 12)
          }
          GroupLabel(text: "Quick Chat")
          ForEach(groups.first(where: { $0.id == "local" })?.agents ?? []) { agent in agentRow(agent) }
          Divider().padding(.horizontal, 14).padding(.vertical, 18)
          ForEach([CompanionModel.Tab.calendar, .scheduledTasks, .library, .databases, .usage], id: \.self) { tab in
            SettingsNavigationRow(title: tab.rawValue, icon: tab.icon) { destination(tab) }
              .accessibilityIdentifier("open-" + tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))
          }
        }.padding(.horizontal, 18).padding(.bottom, 24)
      }.refreshable { await model.refresh() }
    }
  }
  @ViewBuilder private func workspaceAgents(_ group: CompanionAgentGroup) -> some View {
    if group.agents.isEmpty, let workspace = group.workspace {
      SettingsNavigationRow(title: workspace.name, icon: workspace.kind == .mac ? .monitor : .container) {
        WorkspaceSettingsPane(model: model, workspace: workspace)
      }
    } else {
      ForEach(group.agents) { agent in agentRow(agent) }
    }
  }
  @ViewBuilder private var quickActions: some View {
    quickAction("New chat", icon: .squarePen, detail: "Continue your work") { model.newChat() }
      .accessibilityIdentifier("action-new-chat")
    quickAction("New note", icon: .fileText, detail: "Capture an idea") {
      Task { await model.newNote() }
    }.accessibilityIdentifier("action-new-note")
  }
  private func quickAction(_ title: String, icon: DashboardLucideGlyph, detail: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        DashboardLucideIcon(glyph: icon, size: 24).foregroundStyle(theme.palette.themeAccent)
        Text(title).font(.headline)
        Text(detail).font(.caption).foregroundStyle(DashboardPalette.foreground)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
    }.buttonStyle(.plain)
  }
  private func agentRow(_ agent: CompanionAgentLauncher) -> some View {
    WorkspaceRow(icon: MobileAgentIcon(runtimeKind: agent.runtimeKind, size: 24), title: agent.name, detail: agent.workspaceName) {
      Task { await model.launchAgent(agent) }
    }.disabled(!agent.isAvailable).accessibilityIdentifier("launch-agent-" + agent.id)
  }
  @ViewBuilder private func destination(_ tab: CompanionModel.Tab) -> some View {
    switch tab {
    case .library: LibraryPane(model: model)
    case .calendar: CalendarPane(model: model)
    case .scheduledTasks: ScheduledTasksPane(model: model)
    case .databases: DatabasesPane(model: model)
    case .usage: UsagePane(model: model)
    default: EmptyView()
    }
  }
}

struct FoldersPane: View {
  @Bindable var model: CompanionModel
  @State private var newFolderWorkspace: MobileFolderWorkspace?
  @State private var folderName = ""
  @State private var expandedWorkspaces: Set<String> = []
  private let workspaceID: String?
  init(model: CompanionModel, workspaceID: String? = nil) { self.model = model; self.workspaceID = workspaceID }
  private var groups: [MobileFolderWorkspace] {
    model.folderWorkspaceGroups.filter { workspaceID == nil || $0.id == model.canonicalWorkspaceID(workspaceID!) }
  }
  var body: some View {
    Group {
      if model.folderContentsPresented {
        FolderContentsPane(model: model)
      } else {
        VStack(spacing: 0) {
          PaneHeader(title: "Folders") { EmptyView() }
          ScrollView {
            VStack(spacing: 0) {
              if workspaceID == nil {
                WorkspaceRow(icon: .folder, title: "All Workspace") { model.openFolder(nil) }
                  .accessibilityIdentifier("folder-all")
              }
              ForEach(groups.filter(\.isLocal)) { workspace in
                GroupLabel(text: "Local workspace")
                workspaceSection(workspace)
              }
              if !groups.filter({ !$0.isLocal }).isEmpty {
                GroupLabel(text: "Remote workspaces")
                ForEach(groups.filter { !$0.isLocal }) { workspace in workspaceSection(workspace) }
              }
              if workspaceID == nil, model.hasUnassignedContent {
                GroupLabel(text: "Unassigned")
                WorkspaceRow(icon: .folder, title: "Unassigned items", detail: "Existing items without a known workspace") {
                  model.openFolder(nil, workspaceID: "unassigned")
                }
                ForEach(model.folders.filter { model.folderOwner($0) == nil }) { folder in folderRow(folder) }
              }
              SettingsNavigationRow(title: "Trash", icon: .trash) { TrashPane(model: model).mobileNavigationPage("Trash") }
                .padding(.top, 18).accessibilityIdentifier("folders-trash")
            }.padding(.horizontal, 18).padding(.bottom, 24)
          }.refreshable { await model.refresh() }
        }
      }
    }
    .onAppear { for workspace in groups where workspace.isLocal { expandedWorkspaces.insert(workspace.id) } }
    .alert("New folder", isPresented: Binding(get: { newFolderWorkspace != nil }, set: { if !$0 { newFolderWorkspace = nil } })) {
      TextField("Folder name", text: $folderName)
      Button("Create") {
        guard let workspace = newFolderWorkspace else { return }
        let name = folderName; folderName = ""; newFolderWorkspace = nil
        Task {
          if workspace.isLocal { await model.newFolder(name: name) }
          else { do { try await model.newWorkspaceFolder(name: name, workspaceID: model.workspaceRoute(for: workspace.id)) } catch { model.errorMessage = model.workspaceActionMessage(error); await model.reload() } }
        }
      }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folderName.utf8.count > 4096)
      Button("Cancel", role: .cancel) { folderName = ""; newFolderWorkspace = nil }
    } message: { Text("Create in " + (newFolderWorkspace?.name ?? "this workspace") + ".") }
  }
  private func workspaceSection(_ workspace: MobileFolderWorkspace) -> some View {
    DisclosureGroup(isExpanded: Binding(get: { expandedWorkspaces.contains(workspace.id) }, set: {
      if $0 { expandedWorkspaces.insert(workspace.id) } else { expandedWorkspaces.remove(workspace.id) }
    })) {
      VStack(spacing: 0) {
        WorkspaceRow(icon: .folder, title: "All items") { model.openFolder(nil, workspaceID: workspace.id) }.accessibilityIdentifier("workspace-items-" + workspace.id)
        if workspace.canCreate {
          ForEach(model.folderAgents(in: workspace)) { agent in
            WorkspaceRow(icon: MobileAgentIcon(runtimeKind: agent.runtimeKind, size: 24), title: agent.name,
              detail: workspace.isLocal ? "Powered by Pi Durable" : nil) {
              model.selectedFolderID = nil; model.selectedFolderWorkspaceID = workspace.id
              model.newChatNoteID = nil
              Task { await model.startNewChat(with: agent) }
            }.accessibilityIdentifier("folder-agent-" + agent.id)
          }
          WorkspaceRow(icon: .fileText, title: "New note") {
            model.selectedFolderID = nil
            Task { await model.newNote(workspaceID: workspace.id) }
          }.accessibilityIdentifier("action-new-note-" + workspace.id)
          WorkspaceRow(icon: .plus, title: "New folder") {
            if !workspace.isLocal, !model.workspaceIsConnected(model.workspaceRoute(for: workspace.id)) { model.errorMessage = CompanionModel.deviceConnectionMessage }
            else { newFolderWorkspace = workspace; folderName = "" }
          }.accessibilityIdentifier("action-new-folder-" + workspace.id)
        } else if workspace.kind == .ios {
          Text("Quick Chat history syncs from this device.").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
        }
        ForEach(model.folders.filter { model.folderOwner($0) == workspace.id }) { folder in folderRow(folder) }
        WorkspaceRow(icon: .fileText, title: "Unfiled items") { model.openFolder(nil, workspaceID: workspace.id, unfiled: true) }.accessibilityIdentifier("workspace-unfiled-" + workspace.id)
      }.padding(.leading, 6)
    } label: {
      Text(workspace.name).font(.headline).frame(minHeight: 44)
    }.padding(.horizontal, 14).accessibilityIdentifier("folder-workspace-" + workspace.id)
  }
  private func folderRow(_ folder: CompanionFolder) -> some View {
    WorkspaceRow(icon: .folder, title: folder.name,
      detail: String(model.notes.filter { $0.folderID == folder.id }.count + model.conversations.filter { $0.folderID == folder.id }.count)) { model.openFolder(folder.id) }
      .accessibilityIdentifier("folder-" + folder.id)
  }
}

struct FolderContentsPane: View {
  @Bindable var model: CompanionModel
  @State private var search = ""
  private var notes: [CompanionNote] {
    model.notes.filter { model.folderScopeIncludes(owner: model.noteOwner($0), folderID: $0.folderID)
      && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
  }
  private var conversations: [CompanionConversation] {
    model.conversations.filter { model.folderScopeIncludes(owner: model.conversationOwner($0), folderID: $0.folderID)
      && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
  }
  private var folders: [CompanionFolder] {
    guard model.selectedFolderID == nil, !model.folderContentsUnfiled else { return [] }
    return model.folders.filter { model.folderScopeIncludes(owner: model.folderOwner($0), folderID: nil)
      && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button { model.closeFolder() } label: { Label("Folders", glyph: .arrowLeft).frame(minHeight: 44) }
          .accessibilityLabel("Back to Folders").accessibilityIdentifier("back-folders")
        Spacer()
      }.padding(.horizontal, 20)
      PaneHeader(title: model.selectedFolderScopeTitle) {
        if model.canCreateInFolderScope { Menu {
          Button("New chat", glyph: .squarePen) { model.newChat() }
          Button("New note", glyph: .fileText) { Task { await model.newNote() } }
        } label: { DashboardLucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44) }
          .accessibilityLabel("Add to folder") }
      }
      DashboardSearchField(text: $search, prompt: "Search notes and conversations")
        .textInputAutocapitalization(.never).padding(.horizontal, 20)
      ScrollView {
        VStack(spacing: 0) {
          if folders.isEmpty && notes.isEmpty && conversations.isEmpty {
            Text(search.isEmpty ? "This folder is empty. Add a note or start a chat." : "No matching notes or chats.")
              .foregroundStyle(DashboardPalette.mutedForeground).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24).padding(.horizontal, 14)
          }
          if !folders.isEmpty {
            GroupLabel(text: "Folders")
            ForEach(folders) { folder in
              WorkspaceRow(icon: .folder, title: folder.name) { model.openFolder(folder.id) }
            }
          }
          if !notes.isEmpty {
            GroupLabel(text: "Notes & assets")
            ForEach(notes) { note in
              WorkspaceRow(icon: MobileNoteIcon(content: note.content), title: note.title, detail: model.state.uncachedNoteIDs.contains(note.id) ? "Online" : nil) { Task { await model.openNote(note.id) } }
            }
          }
          if !conversations.isEmpty {
            GroupLabel(text: "Chats")
            ForEach(conversations) { conversation in
              WorkspaceRow(icon: .messageSquare, title: conversation.title, detail: conversation.runtimeKind) { Task { await model.selectConversation(conversation.id) } }.accessibilityIdentifier("folder-chat-" + conversation.id)
            }
          }
        }.padding(.horizontal, 18).padding(.bottom, 24)
      }.refreshable { await model.refresh() }
    }
  }

}

struct CompanionSettingsPane: View {
  @Bindable var model: CompanionModel
  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Settings") { EmptyView() }
      ScrollView {
        VStack(spacing: 2) {
          SettingsNavigationRow(title: "General", icon: .settings) { GeneralSettingsPane(model: model) }
          SettingsNavigationRow(title: "Dictation", icon: .mic) { DictationHistoryPane(model: model) }
          SettingsNavigationRow(title: "Quick Chat", icon: .bot) { DeviceAgentSettingsPane(model: model) }
          SettingsNavigationRow(title: model.deviceConnectionsTitle, icon: .plug) { ExecutionSettingsPane(model: model) }
          SettingsNavigationRow(title: "Device Connections", icon: .monitor) { PairingPane(model: model) }
          SettingsNavigationRow(title: "Workspaces", icon: .container) { WorkspacesSettingsPane(model: model) }
          SettingsNavigationRow(title: "Usage Settings", icon: .barChart) { UsageSettingsPane(model: model) }
        }.padding(.horizontal, 18).padding(.bottom, 24)
      }
    }
  }
}

struct SettingsNavigationRow<Destination: View>: View {
  let title: String
  let icon: DashboardLucideGlyph
  @ViewBuilder let destination: () -> Destination
  var body: some View {
    NavigationLink(destination: destination) {
      HStack(spacing: 14) {
        DashboardLucideIcon(glyph: icon, size: 22).frame(width: 26)
        Text(title).frame(maxWidth: .infinity, alignment: .leading)
        DashboardLucideIcon(glyph: .chevronDown, size: 16).rotationEffect(.degrees(-90)).foregroundStyle(DashboardPalette.mutedForeground)
      }.padding(.horizontal, 14).padding(.vertical, 13).frame(minHeight: 48).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}

private struct MobilePageSurface: ViewModifier {
  @Environment(\.dashboardTheme) private var theme
  func body(content: Content) -> some View {
    content
      .scrollContentBackground(.hidden)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(theme.palette.workspace.ignoresSafeArea())
  }
}

extension View {
  func mobilePageSurface() -> some View { modifier(MobilePageSurface()) }
  func mobileNavigationPage(_ title: String) -> some View {
    mobilePageSurface().navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
  }
}

struct GeneralSettingsPane: View {
  @Bindable var model: CompanionModel
  @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
  var body: some View {
    Form {
      Section("Appearance") {
        DashboardSegmentedSelector(options: DashboardTheme.allCases.map(\.rawValue), selection: $storedTheme) {
          DashboardTheme(rawValue: $0)?.title ?? $0
        }.accessibilityElement(children: .contain)
          .accessibilityLabel("Theme").listRowBackground(Color.clear)
      }
      Section("About") {
        LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
      }
      Section("Product analytics") {
        Toggle("Share product analytics",isOn:Binding(get:{model.analytics.enabled},set:{value in Task { await model.analytics.setEnabled(value) } }))
        Text("App opens and active use are sampled at most once every six hours. No content or action details are sent. This choice applies to your whole central library; offline devices receive changes when they reconnect.").font(.caption).foregroundStyle(.secondary)
        if model.analytics.state.pendingEnabled != nil { Text("Preference waiting to sync.").font(.caption).foregroundStyle(.secondary) }
        Link("Privacy policy",destination:ProductAnalyticsPolicy.url).foregroundStyle(DashboardPalette.success)
        if let error=model.analytics.errorMessage { Text(error).foregroundStyle(.red) }
      }
    }.scrollIndicators(.never).mobileNavigationPage("General")
  }
}

struct WorkspacesSettingsPane: View {
  @Bindable var model: CompanionModel
  var body: some View {
    List {
      Section {
        NavigationLink { DeviceAgentSettingsPane(model: model) } label: {
          Label("Quick Chat", glyph: .messageSquare)
        }
        if model.credential != nil || model.state.workspaceID != nil {
          NavigationLink { CentralWorkspaceSettingsPane(model: model) } label: {
            Label("Central database", glyph: .monitor).opacity(model.online ? 1 : 0.5)
          }
        }
        ForEach(model.executionWorkspaces) { workspace in
          NavigationLink { WorkspaceSettingsPane(model: model, workspace: workspace) } label: {
            Label(workspace.name, glyph: workspace.kind == .mac ? .monitor : .container)
              .opacity(model.workspaceReachable[workspace.id] == true ? 1 : 0.5)
          }
        }
      }
    }.listStyle(.insetGrouped).mobileNavigationPage("Workspaces")
      .task { await model.refreshExecutionWorkspaces(force: true) }
  }
}

private struct CentralWorkspaceSettingsPane: View {
  @Bindable var model: CompanionModel
  var body: some View {
    List {
      Section {
        LabeledContent("Connection", value: model.online ? "Connected" : "Disconnected")
        if let endpoint = model.credential?.endpoint { Text(endpoint.host ?? endpoint.absoluteString).textSelection(.enabled) }
      }
      Section("Agents") {
        ForEach(model.launcherAgents.filter { $0.workspaceID == "central" }) { agent in
          Button { Task { await model.launchAgent(agent) } } label: {
            Label { Text(agent.name) } icon: { MobileAgentIcon(runtimeKind: agent.runtimeKind, size: 22) }
          }.disabled(!agent.isAvailable)
        }
      }
    }.listStyle(.insetGrouped).mobileNavigationPage("Central database")
  }
}

private struct WorkspaceSettingsPane: View {
  @Bindable var model: CompanionModel
  let workspace: CompanionExecutionWorkspace
  var body: some View {
    List {
      Section {
        LabeledContent("Connection", value: model.workspaceReachable[workspace.id] == true ? "Connected" : "Disconnected")
        if let endpoint = workspace.endpoint { Text(endpoint.host ?? endpoint.absoluteString).textSelection(.enabled) }
      }
      Section { NavigationLink("Folders") { FoldersPane(model: model, workspaceID: workspace.id) } }
      Section("Agents") {
        ForEach(model.launcherAgents.filter { $0.workspaceID == workspace.id }) { agent in
          Button { Task { await model.launchAgent(agent) } } label: {
            Label { Text(agent.name) } icon: { MobileAgentIcon(runtimeKind: agent.runtimeKind, size: 22) }
          }.disabled(!agent.isAvailable)
        }
      }
      Section {
        Button("Refresh device access") { Task { await model.renewWorkspaceAccess(workspace.id) } }.disabled(!model.online)
        if let problem = model.workspaceProblems[workspace.id] { Text(problem).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
      }
    }.listStyle(.insetGrouped).mobileNavigationPage(workspace.name)
  }
}

import CompanionClient
import WovenMatterCompanion
