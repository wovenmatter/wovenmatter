import SwiftUI

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
        .onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
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
                  DashboardLucideIcon(glyph: tab.icon, size: 22)
                    .frame(width: 54, height: 30)
                    .background(isSelected(tab) ? theme.palette.themeSoft : .clear, in: Capsule())
                  Text(tab.rawValue).font(.caption2.weight(isSelected(tab) ? .semibold : .regular))
                }.frame(maxWidth: .infinity).padding(.vertical, 11)
                  .foregroundStyle(isSelected(tab) ? DashboardPalette.foreground : DashboardPalette.mutedForeground)
              }.accessibilityIdentifier("tab-\(tab.rawValue.lowercased())")
                .accessibilityAddTraits(isSelected(tab) ? .isSelected : [])
            }
          }.background(theme == .dark ? theme.palette.railFill : theme.palette.themeWhisper).overlay(alignment: .top) { Divider() }
        }
      }
    }
    .background(MobileKeyboardDismissal())
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

extension WorkspaceRow where Icon == Image {
  init(systemIcon: String, title: String, detail: String? = nil, action: @escaping () -> Void) {
    self.init(icon: Image(systemName: systemIcon), title: title, detail: detail, action: action)
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
          GroupLabel(text: "Agents")
          ForEach(groups.first(where: { $0.id == "local" })?.agents ?? []) { agent in agentRow(agent) }
          if let mac = groups.first(where: { $0.id == "central" }) {
            GroupLabel(text: "Local agent workspace")
            workspaceAgents(mac)
          }
          ForEach(groups.filter { $0.id != "central" && $0.workspace?.kind == .mac }) { mac in
            GroupLabel(text: mac.name)
            workspaceAgents(mac)
          }
          let remote = groups.filter { $0.id != "local" && $0.id != "central" && $0.workspace?.kind != .mac }
          if !remote.isEmpty {
            GroupLabel(text: "Remote workspaces")
            ForEach(remote) { workspaceAgents($0) }
          }
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
  @State private var newFolderPresented = false
  @State private var folderName = ""
  var body: some View {
    Group {
      if model.folderContentsPresented {
        FolderContentsPane(model: model)
      } else {
        VStack(spacing: 0) {
          PaneHeader(title: "Folders") { EmptyView() }
          ScrollView {
            VStack(spacing: 0) {
              WorkspaceRow(icon: .squarePen, title: "New chat") { model.newChat() }
                .accessibilityIdentifier("action-new-chat")
              WorkspaceRow(icon: .fileText, title: "New note") { Task { await model.newNote() } }
                .accessibilityIdentifier("action-new-note")
              WorkspaceRow(icon: .plus, title: "New folder") { newFolderPresented = true }
              WorkspaceRow(icon: .folder, title: "All workspace") { model.openFolder(nil) }
                .accessibilityIdentifier("folder-all")
              ForEach(model.folders) { folder in
                WorkspaceRow(icon: .folder, title: folder.name,
                  detail: String(model.notes.filter { $0.folderID == folder.id }.count + model.conversations.filter { $0.folderID == folder.id }.count)) { model.openFolder(folder.id) }
                  .accessibilityIdentifier("folder-" + folder.id)
              }
              SettingsNavigationRow(title: "Trash", icon: .trash) { TrashPane(model: model).mobileNavigationPage("Trash") }
                .padding(.top, 18).accessibilityIdentifier("folders-trash")
            }.padding(.horizontal, 18).padding(.bottom, 24)
          }.refreshable { await model.refresh() }
        }
      }
    }
    .alert("New folder", isPresented: $newFolderPresented) {
      TextField("Folder name", text: $folderName)
      Button("Create") { let name = folderName; folderName = ""; Task { await model.newFolder(name: name) } }
      Button("Cancel", role: .cancel) { folderName = "" }
    }
  }
}

struct FolderContentsPane: View {
  @Bindable var model: CompanionModel
  @State private var search = ""
  private var notes: [CompanionNote] {
    model.notes.filter { (model.selectedFolderID == nil || $0.folderID == model.selectedFolderID)
      && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
  }
  private var conversations: [CompanionConversation] {
    model.conversations.filter { (model.selectedFolderID == nil || $0.folderID == model.selectedFolderID)
      && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button { model.closeFolder() } label: { Label("Folders", glyph: .arrowLeft).frame(minHeight: 44) }
          .accessibilityLabel("Back to Folders").accessibilityIdentifier("back-folders")
        Spacer()
      }.padding(.horizontal, 20)
      PaneHeader(title: model.selectedFolderID.flatMap { model.state.folders[$0]?.name } ?? "All workspace") {
        Menu {
          Button("New chat", glyph: .squarePen) { model.newChat() }
          Button("New note", glyph: .fileText) { Task { await model.newNote() } }
        } label: { DashboardLucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44) }
          .accessibilityLabel("Add to folder")
      }
      DashboardSearchField(text: $search, prompt: "Search notes and conversations")
        .textInputAutocapitalization(.never).padding(.horizontal, 20)
      ScrollView {
        VStack(spacing: 0) {
          if notes.isEmpty && conversations.isEmpty {
            Text(search.isEmpty ? "This folder is empty. Add a note or start a chat." : "No matching notes or chats.")
              .foregroundStyle(DashboardPalette.mutedForeground).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24).padding(.horizontal, 14)
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
              WorkspaceRow(icon: .messageSquare, title: conversation.title, detail: conversation.runtimeKind) { Task { await model.selectConversation(conversation.id) } }
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
          SettingsNavigationRow(title: "Pi Durable", icon: .bot) { DeviceAgentSettingsPane(model: model) }
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
        }.accessibilityLabel("Theme").listRowBackground(Color.clear)
      }
      Section("About") {
        LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
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
          Label(model.deviceWorkspaceName, glyph: .terminal)
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

struct SyncRecoveryPane: View {
  @Bindable var model: CompanionModel
  var body: some View {
    List {
      CompanionInlineError(model: model)
      if (model.synchronizationStatus.lanes[.calendar]?.conflictCount ?? 0) > 0 {
        NavigationLink("Calendar conflicts") { CalendarPane(model: model) }
      }
      ForEach(Array(model.state.conflicts.keys).sorted(), id: \.self) { id in
        Button(model.state.notes[id]?.title ?? "Note conflict") { Task { await model.openNote(id) } }
      }
      ForEach(model.state.launches.filter { !$0.accepted }) { launch in
        VStack(alignment: .leading, spacing: 8) {
          Text(launch.initialSend.text ?? "New conversation").lineLimit(3)
          if let message = launch.sendReceipt?.message ?? launch.createReceipt?.message { Text(message).font(.caption) }
          if !launch.terminalFailure {
            Button("Retry saved request") { Task { await model.continueLaunch(launch) } }
              .disabled(launch.create.workspaceID.map { model.workspaceReachable[$0] != true } ?? !model.online)
          }
        }
      }
      ForEach(model.unresolvedCommands) { record in
        VStack(alignment: .leading, spacing: 8) {
          Text(record.command.text ?? record.command.kind.rawValue).lineLimit(3)
          if let message = record.receipt?.message { Text(message).font(.caption) }
          if record.receipt == nil { Button("Retry saved command") { Task { await model.retry(record) } }.disabled(!model.online) }
        }
      }
    }.listStyle(.plain).scrollContentBackground(.hidden).mobileNavigationPage("Pending changes")
  }
}

import CompanionClient
import WovenMatterCompanion
