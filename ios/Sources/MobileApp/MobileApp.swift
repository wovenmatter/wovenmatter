import LibraryClient
import SwiftUI
import WovenMatterShared

@main struct MobileApp: App {
  @State private var model = MobileModel()
  @AppStorage(WovenTheme.storageKey) private var storedTheme = WovenTheme.green.rawValue
  private var theme: WovenTheme { WovenTheme(rawValue: storedTheme) ?? .green }
  @Environment(\.scenePhase) private var scenePhase

  init() {
    // v0.4.2 saved the theme as "wovenmatter.dashboard.theme". It moves once.
    let defaults = UserDefaults.standard, legacy = "wovenmatter.dashboard.theme"
    if let theme = defaults.object(forKey: legacy) {
      if defaults.object(forKey: WovenTheme.storageKey) == nil { defaults.set(theme, forKey: WovenTheme.storageKey) }
      defaults.removeObject(forKey: legacy)
    }
    // v0.4.2 saved the all-devices usage view as "host". It reads "library" once.
    if defaults.string(forKey: UsagePreferences.sourceKey) == "central" { defaults.set("library", forKey: UsagePreferences.sourceKey) }
  }

  var body: some Scene {
    WindowGroup {
      ZStack {
        if model.initialized { MobileShell(model: model) }
        else { ProgressView("Opening your library…") }
      }
        .preferredColorScheme(theme.colorScheme)
        .environment(\.wovenTheme, theme)
        .background(theme.palette.workspace)
        .task {
          #if DEBUG
          if DeviceRuntimeSmoke.enabled { await DeviceRuntimeSmoke.run(); return }
          #endif
          if !model.fixture && !model.isolatedTestHost {
            QuickChatNotifications.shared.open = { id in Task { await model.openTimerNotification(conversationID: id) } }
            QuickChatNotifications.shared.install()
          }
          await model.run()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
          model.sceneChanged(phase)
          if phase == .background { MobileDictation.shared.stop() }
          if phase == .active { Task { await model.analytics.openInterface() } }
        }
        .onOpenURL { url in
          // The Dev app registers wovenmatter-dev://; pairing links are always wovenmatter://.
          guard ["wovenmatter", "wovenmatter-dev"].contains(url.scheme ?? ""), url.host == "pair",
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
          components.scheme = "wovenmatter"
          guard let pairing = components.url else { return }
          model.tab = .settings; model.pairingPresented = true
          Task { await model.pair(url: pairing) }
        }
    }
  }
}

struct MobileShell: View {
  @Bindable var model: MobileModel
  @Environment(\.wovenTheme) private var theme
  @State private var keyboardVisible = false
  @State private var hoveredTab: MobileModel.Tab?
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
              ForEach(Array(MobileModel.Tab.allCases.prefix(5)), id: \.self) { tab in sidebarRow(tab) }
              Divider().padding(.vertical, 12)
              ForEach(Array(MobileModel.Tab.allCases.dropFirst(5).filter { $0 != .trash }), id: \.self) { tab in sidebarRow(tab) }
            }.padding(.horizontal, 12)
          }
        }.frame(width: WovenMetrics.railWidth).background(theme == .dark ? theme.palette.railFill : theme.palette.themeWhisper)
        Divider()
      }
      VStack(spacing: 0) {
        NavigationStack {
          VStack(spacing: 0) {
            pane
            if MobileModel.Tab.allCases.prefix(5).contains(model.tab) { MobileInlineError(model: model).padding(.horizontal, 20) }
          }
            .mobilePageSurface()
            .toolbar(MobileModel.Tab.allCases.prefix(5).contains(model.tab) ? .hidden : .visible, for: .navigationBar)
            .toolbar {
              if !MobileModel.Tab.allCases.prefix(5).contains(model.tab) {
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
            ForEach(Array(MobileModel.Tab.allCases.prefix(5)), id: \.self) { tab in
              Button { selectTab(tab) } label: {
                VStack(spacing: 5) {
                  LucideIcon(glyph: tab.icon, size: 22).frame(height: 26)
                  ZStack {
                    // Every highlight uses the widest tab label, including its
                    // selected weight, without hard-coding a Dynamic Type width.
                    ForEach(Array(MobileModel.Tab.allCases.prefix(5)), id: \.self) { label in
                      Text(label.rawValue).font(.caption2.weight(.semibold)).hidden().accessibilityHidden(true)
                    }
                    Text(tab.rawValue).font(.caption2.weight(isSelected(tab) ? .semibold : .regular))
                  }
                }.padding(9)
                  .foregroundStyle(isSelected(tab) ? WovenPalette.foreground : WovenPalette.mutedForeground)
                  .background(isSelected(tab) || hoveredTab == tab ? theme.palette.themeSoft : .clear,
                    in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
                  .contentShape(.interaction, RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
                  .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
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
    .sheet(isPresented: $model.chatChooserPresented, onDismiss: { model.newChatNoteID = nil }) { NewChatChooser(model: model).environment(\.wovenTheme, theme) }
    .scrollIndicators(.never)
    .foregroundStyle(WovenPalette.foreground).tint(theme.palette.themeAccent)
    .background(theme.palette.workspace)
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    .environment(\.wovenTheme, theme)
    .toggleStyle(SwitchToggleStyle(tint: WovenPalette.primary))
  }
  private func selectTab(_ tab: MobileModel.Tab) {
    guard !model.startingChat else { return }
    model.executionSettingsPresented = false; model.pairingPresented = false
    // Reselecting a tab returns to its root, as with a native tab bar.
    if model.tab == tab { navigationReset = UUID() }
    model.tab = tab
  }
  private func isSelected(_ tab: MobileModel.Tab) -> Bool {
    model.tab == tab || (tab == .home && !MobileModel.Tab.allCases.prefix(5).contains(model.tab))
  }
  private func sidebarRow(_ tab: MobileModel.Tab) -> some View {
    WorkspaceRow(icon: tab.icon, title: tab.rawValue, selected: model.tab == tab) { selectTab(tab) }
      .accessibilityIdentifier("tab-\(tab.rawValue.lowercased())")
  }
  @ViewBuilder private var pane: some View {
    switch model.tab {
    case .home: HomePane(model: model)
    case .folders: FoldersPane(model: model)
    case .settings: MobileSettingsPane(model: model)
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

struct MobileInlineError: View {
  @Bindable var model: MobileModel
  var body: some View {
    if let message = model.errorMessage {
      HStack(alignment: .top, spacing: 8) {
        Text(message).font(.caption).foregroundStyle(WovenPalette.danger).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("workspace-action-error")
        Button { model.errorMessage = nil } label: { LucideIcon(glyph: .close, size: 14).frame(width: 44, height: 44) }
          .buttonStyle(.plain).accessibilityLabel("Dismiss error")
      }.padding(.vertical, 8)
    }
  }
}

struct PaneHeader<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing
  var body: some View { HStack(alignment: .center) { Text(title).font(.title.weight(.semibold)).accessibilityIdentifier("pane-heading-" + title.lowercased()); Spacer(); trailing.buttonStyle(WovenIconButtonStyle()) }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14) }
}
struct WorkspaceRow<Icon: View>: View {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.wovenTheme) private var theme
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
        if let detail { Text(detail).font(.caption).foregroundStyle(WovenPalette.foreground).lineLimit(2) }
      }.padding(.horizontal, 14).padding(.vertical, 13).frame(minHeight: 48)
        .background(selected ? theme.palette.themeSoft : Color.clear, in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
        .contentShape(Rectangle())
    }.buttonStyle(.plain).opacity(isEnabled ? 1 : 0.4).accessibilityAddTraits(selected ? .isSelected : [])
  }
}
extension WorkspaceRow where Icon == LucideIcon {
  init(icon: LucideGlyph, title: String, detail: String? = nil, selected: Bool = false, action: @escaping () -> Void) {
    self.init(icon: LucideIcon(glyph: icon, size: 22), title: title, detail: detail, selected: selected, action: action)
  }
}

struct GroupLabel: View {
  var text: String
  var body: some View { Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(WovenPalette.foreground).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 22).padding(.bottom, 6) }
}

struct HomePane: View {
  @Environment(\.wovenTheme) private var theme
  @Bindable var model: MobileModel
  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Woven Matter") { EmptyView() }
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { quickActions }
            VStack(spacing: 12) { quickActions }
          }.padding(.vertical, 12)
          // Quick Chat leads; Workspaces lists only paired Macs and Linux
          // workspaces that are reachable now.
          let groups = model.launcherGroups
          GroupLabel(text: "Quick Chat").accessibilityIdentifier("home-quick-chat")
          ForEach(groups.first(where: { $0.id == "local" })?.agents ?? []) { agent in agentRow(agent) }
          GroupLabel(text: "Workspaces").accessibilityIdentifier("home-workspaces")
          ForEach(groups.filter { $0.id != "local" }) { group in
            GroupLabel(text: group.name)
            workspaceAgents(group)
          }
          if groups.allSatisfy({ $0.id == "local" }) { noConnectedWorkspaces }
          Divider().padding(.horizontal, 14).padding(.vertical, 18)
          // Scheduled tasks and databases live on a Mac or Linux workspace.
          ForEach(model.isStandalone ? [MobileModel.Tab.calendar, .library, .usage] : [MobileModel.Tab.calendar, .scheduledTasks, .library, .databases, .usage], id: \.self) { tab in
            SettingsNavigationRow(title: tab.rawValue, icon: tab.icon) { destination(tab) }
              .accessibilityIdentifier("open-" + tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))
          }
        }.padding(.horizontal, 18).padding(.bottom, 24)
      }.refreshable { await model.refresh() }
    }
  }
  @ViewBuilder private var noConnectedWorkspaces: some View {
    if model.credential == nil {
      SettingsNavigationRow(title: "Connect your Mac", icon: .monitor) { PairingPane(model: model) }
        .accessibilityIdentifier("home-connect-mac")
      homeCaption("Pair with Woven Matter on your Mac to use its workspaces and agents here and sync your notes and chats. Everything on \(model.deviceWorkspaceInSentence) is kept.")
        .accessibilityIdentifier("home-connect-mac-caption")
    } else {
      if model.needsMemberPairing {
        SettingsNavigationRow(title: "Pair again", icon: .monitor) { PairingPane(model: model) }
      }
      homeCaption("No paired Mac or Linux workspace is reachable right now. Each one appears here when it reconnects.")
        .accessibilityIdentifier("home-no-workspaces")
    }
  }
  private func homeCaption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
  }
  @ViewBuilder private func workspaceAgents(_ group: AgentGroup) -> some View {
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
  private func quickAction(_ title: String, icon: LucideGlyph, detail: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        LucideIcon(glyph: icon, size: 24).foregroundStyle(theme.palette.themeAccent)
        Text(title).font(.headline)
        Text(detail).font(.caption).foregroundStyle(WovenPalette.foreground)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: WovenMetrics.cardRadius, style: .continuous))
    }.buttonStyle(.plain)
  }
  private func agentRow(_ agent: LaunchableAgent) -> some View {
    WorkspaceRow(icon: MobileAgentIcon(runtimeKind: agent.runtimeKind, size: 24), title: agent.name, detail: agent.workspaceName) {
      Task { await model.launchAgent(agent) }
    }.disabled(!agent.isAvailable).accessibilityIdentifier("launch-agent-" + agent.id)
  }
  @ViewBuilder private func destination(_ tab: MobileModel.Tab) -> some View {
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
  @Bindable var model: MobileModel
  @State private var newFolderWorkspace: MobileFolderWorkspace?
  @State private var folderName = ""
  @State private var collapsedSections: Set<String> = []
  @State private var initializedSections = false
  @State private var managedRecent: MobileFolderRecentItem?
  @State private var recentDetailsPresented = false
  private let workspaceID: String?
  init(model: MobileModel, workspaceID: String? = nil) { self.model = model; self.workspaceID = workspaceID }
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
              WorkspaceRow(icon: .squarePen, title: "New Chat") {
                model.closeFolder(); model.newChat()
              }.accessibilityIdentifier("action-new-chat")
              Menu {
                Section("New Asset") { MobileNewAssetItems { kind in model.closeFolder(); Task { await model.newAsset(kind) } } }
              } label: {
                // The same row as New Chat; its choices are the New Asset kinds.
                HStack(spacing: 14) {
                  LucideIcon(glyph: .fileText, size: 22).frame(width: 26)
                  Text("New Asset").font(.body).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 14).padding(.vertical, 13).frame(minHeight: 48).contentShape(Rectangle())
                  .foregroundStyle(WovenPalette.foreground)
              }.accessibilityIdentifier("action-new-asset")
              WorkspaceRow(icon: .folder, title: "All Workspaces") { model.openFolder(nil) }
                .accessibilityIdentifier("folder-all")
              ForEach(groups.filter(\.isLocal)) { workspace in
                sectionHeading("Local Agent Workspace", key: "local", identifier: "folders-local")
                  .padding(.top, 12)
                if isExpanded("local") { workspaceContents(workspace) }
              }
              if workspaceID == nil || groups.contains(where: { !$0.isLocal }) {
                sectionHeading("Remote Workspaces", key: "remote", identifier: "folders-remote")
                  .padding(.top, 12)
                if isExpanded("remote") {
                  if !groups.contains(where: { !$0.isLocal }) {
                    Text(model.isStandalone ? "Pair with your Mac in Settings → Device Connections to see its workspaces and folders here."
                      : "No paired Mac or Linux workspace is reachable right now. Its folders stay in All Workspaces.").font(.caption)
                      .foregroundStyle(WovenPalette.mutedForeground)
                      .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                      .accessibilityIdentifier("folders-remote-empty")
                  }
                  ForEach(groups.filter { !$0.isLocal }) { workspace in
                    sectionHeading(workspace.name, key: workspace.id, identifier: "folder-workspace-" + workspace.id)
                    if isExpanded(workspace.id) { workspaceContents(workspace) }
                  }
                }
              }
              SettingsNavigationRow(title: "Trash", icon: .trash) { TrashPane(model: model).mobileNavigationPage("Trash") }
                .padding(.top, 18).accessibilityIdentifier("folders-trash")
              sectionHeading("Recents", key: "recents", identifier: "folders-recents").padding(.top, 8)
              if isExpanded("recents") {
                if model.folderRecentItems.isEmpty {
                  Text("No recent items.").font(.caption).foregroundStyle(WovenPalette.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                ForEach(model.folderRecentItems) { item in
                  WorkspaceRow(icon: item.isNote ? .fileText : .messageSquare, title: item.title) {
                    Task {
                      if item.isNote { await model.openNote(item.resourceID) }
                      else { await model.selectConversation(item.resourceID) }
                    }
                  }.accessibilityIdentifier("recent-" + item.id)
                    .contextMenu {
                      Button(item.isNote ? "Note details" : "Conversation details") {
                        managedRecent = item; recentDetailsPresented = true
                      }
                    }
                }
              }
            }.padding(.horizontal, 18).padding(.bottom, 24)
          }.refreshable { await model.refresh() }
        }
      }
    }
    .onAppear {
      guard !initializedSections else { return }
      collapsedSections.formUnion(groups.filter { !$0.isLocal }.map(\.id))
      // UI fixture: open the Linux workspace, whose folder list is empty, without scrolling.
      if MobileModel.uiScenario == "remote-folders-empty" {
        collapsedSections = Set(["local"] + groups.filter { !$0.isLocal && $0.kind != .linux }.map(\.id))
      }
      initializedSections = true
    }
    .navigationDestination(isPresented: $recentDetailsPresented) {
      if let item = managedRecent {
        ItemManagementSheet(model: model, id: item.resourceID, isNote: item.isNote, title: item.title, folderID: item.folderID ?? "")
      }
    }
    .alert("New folder", isPresented: Binding(get: { newFolderWorkspace != nil }, set: { if !$0 { newFolderWorkspace = nil } })) {
      TextField("Folder name", text: $folderName)
      Button("Create") {
        guard let workspace = newFolderWorkspace else { return }
        let name = folderName; folderName = ""; newFolderWorkspace = nil
        guard workspace.canCreateFolder else { return }
        Task { await model.newFolder(name: name) }
      }.disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folderName.utf8.count > 4096)
      Button("Cancel", role: .cancel) { folderName = ""; newFolderWorkspace = nil }
    } message: { Text("Create in " + (newFolderWorkspace?.name ?? "this workspace") + ".") }
  }
  private func isExpanded(_ key: String) -> Bool { !collapsedSections.contains(key) }
  private func sectionHeading(_ title: String, key: String, identifier: String) -> some View {
    Button {
      if isExpanded(key) { collapsedSections.insert(key) } else { collapsedSections.remove(key) }
    } label: {
      HStack {
        Text(title).font(.subheadline.weight(.semibold))
        Spacer()
        Image(systemName: isExpanded(key) ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
      }.foregroundStyle(WovenPalette.foreground).padding(.horizontal, 14)
        .frame(minHeight: 44).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityIdentifier(identifier).accessibilityLabel(title)
      .accessibilityValue(isExpanded(key) ? "Expanded" : "Collapsed")
  }
  private func workspaceContents(_ workspace: MobileFolderWorkspace) -> some View {
    VStack(spacing: 0) {
      if workspace.canCreate {
        ForEach(model.folderAgents(in: workspace)) { agent in
          WorkspaceRow(icon: MobileAgentIcon(runtimeKind: agent.runtimeKind, size: 24), title: agent.name) {
            model.selectedFolderID = nil; model.selectedFolderWorkspaceID = workspace.id
            model.newChatNoteID = nil
            Task { await model.startNewChat(with: agent) }
          }.accessibilityIdentifier("folder-agent-" + agent.id)
        }
      } else if workspace.kind == .ios {
        WorkspaceRow(icon: .messageSquare, title: "Quick Chat", detail: "Saved history") {
          model.openFolder(nil, workspaceID: workspace.id)
        }.accessibilityIdentifier("workspace-history-" + workspace.id)
      }
      sectionHeading("Folders", key: workspace.id + ":folders", identifier: "workspace-folders-" + workspace.id)
      if isExpanded(workspace.id + ":folders") {
        if workspace.canCreateFolder {
          WorkspaceRow(icon: .plus, title: "New Folder") {
            newFolderWorkspace = workspace; folderName = ""
          }.accessibilityIdentifier("action-new-folder-" + workspace.id)
        }
        let folders = model.folders.filter { model.folderOwner($0) == workspace.id }
        // Remote workspaces create folders where their files live, so explain the empty list.
        if folders.isEmpty && !workspace.canCreateFolder {
          Text("No folders yet. Create folders on " + workspace.name + ".").font(.caption)
            .foregroundStyle(WovenPalette.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .accessibilityIdentifier("workspace-folders-empty-" + workspace.id)
        }
        ForEach(folders) { folder in
          WorkspaceRow(icon: .folder, title: folder.name,
            detail: String(model.notes.filter { $0.folderID == folder.id }.count + model.conversations.filter { $0.folderID == folder.id }.count)) { model.openFolder(folder.id) }
            .accessibilityIdentifier("folder-" + folder.id)
        }
      }
    }
  }
}

struct FolderContentsPane: View {
  @Bindable var model: MobileModel
  @State private var search = ""
  private var notes: [LibraryNote] {
    model.notes.filter { model.folderScopeIncludes(owner: model.noteOwner($0), folderID: $0.folderID)
      && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
  }
  private var conversations: [LibraryConversation] {
    model.conversations.filter { model.folderScopeIncludes(owner: model.conversationOwner($0), folderID: $0.folderID)
      && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
  }
  private var folders: [LibraryFolder] {
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
          Menu("New Asset") { MobileNewAssetItems { kind in Task { await model.newAsset(kind) } } }
        } label: { LucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44) }
          .accessibilityLabel("Add to folder") }
      }
      WovenSearchField(text: $search, prompt: "Search notes and conversations")
        .textInputAutocapitalization(.never).padding(.horizontal, 20)
      ScrollView {
        VStack(spacing: 0) {
          if folders.isEmpty && notes.isEmpty && conversations.isEmpty {
            Text(search.isEmpty ? "This folder is empty. Add a note or start a chat." : "No matching notes or chats.")
              .foregroundStyle(WovenPalette.mutedForeground).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24).padding(.horizontal, 14)
          }
          if !folders.isEmpty {
            GroupLabel(text: "Folders")
            ForEach(folders) { folder in
              WorkspaceRow(icon: .folder, title: folder.name) { model.openFolder(folder.id) }
                .accessibilityIdentifier("folder-" + folder.id)
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

struct MobileSettingsPane: View {
  @Bindable var model: MobileModel
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
  let icon: LucideGlyph
  @ViewBuilder let destination: () -> Destination
  var body: some View {
    NavigationLink(destination: destination) {
      HStack(spacing: 14) {
        LucideIcon(glyph: icon, size: 22).frame(width: 26)
        Text(title).frame(maxWidth: .infinity, alignment: .leading)
        LucideIcon(glyph: .chevronDown, size: 16).rotationEffect(.degrees(-90)).foregroundStyle(WovenPalette.mutedForeground)
      }.padding(.horizontal, 14).padding(.vertical, 13).frame(minHeight: 48).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}

private struct MobilePageSurface: ViewModifier {
  @Environment(\.wovenTheme) private var theme
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
  @Bindable var model: MobileModel
  @AppStorage(WovenTheme.storageKey) private var storedTheme = WovenTheme.green.rawValue
  var body: some View {
    Form {
      Section("Appearance") {
        WovenSegmentedSelector(options: WovenTheme.allCases.map(\.rawValue), selection: $storedTheme) {
          WovenTheme(rawValue: $0)?.title ?? $0
        }.accessibilityElement(children: .contain)
          .accessibilityLabel("Theme").listRowBackground(Color.clear)
      }
      Section("About") {
        LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
      }
      Section("Product analytics") {
        Toggle("Share product analytics",isOn:Binding(get:{model.analytics.enabled},set:{value in Task { await model.analytics.setEnabled(value) } }))
        Text(model.credential == nil
          ? "Nothing is sent while \(model.deviceWorkspaceInSentence) isn’t paired. Once paired, app opens and active use are sampled at most once every six hours and sent through your Mac. No content or action details are sent."
          : "App opens and active use are sampled at most once every six hours and sent through your Mac. No content or action details are sent. This choice applies to all your devices; offline devices receive it when they reconnect.")
          .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("analytics-explanation")
        if model.analytics.state.pendingEnabled != nil { Text("Preference waiting to sync.").font(.caption).foregroundStyle(.secondary) }
        Link("Privacy policy",destination:ProductAnalyticsPolicy.url).foregroundStyle(WovenPalette.success)
        if let error=model.analytics.errorMessage { Text(error).foregroundStyle(.red) }
      }
    }.scrollIndicators(.never).mobileNavigationPage("General")
  }
}

struct WorkspacesSettingsPane: View {
  @Bindable var model: MobileModel
  var body: some View {
    List {
      Section {
        NavigationLink { DeviceAgentSettingsPane(model: model) } label: {
          Label("Quick Chat", glyph: .messageSquare)
        }
        // Every saved workspace stays here with its connection state, so a
        // disconnected one can be checked or refreshed. The Mac this device
        // syncs its library with is listed like every other one.
        ForEach(model.executionWorkspaces) { workspace in
          NavigationLink { WorkspaceSettingsPane(model: model, workspace: workspace) } label: {
            Label(workspace.name, glyph: workspace.kind == .mac ? .monitor : .container)
              .opacity(model.workspaceIsActive(workspace) ? 1 : 0.5)
          }
        }
      }
    }.listStyle(.insetGrouped).mobileNavigationPage("Workspaces")
      .task { await model.refreshExecutionWorkspaces(force: true) }
  }
}

private struct WorkspaceSettingsPane: View {
  @Bindable var model: MobileModel
  let workspace: ExecutionWorkspace
  private var active: Bool { model.workspaceIsActive(workspace) }
  /// The library host's own agents are listed in its group under the host route.
  private var agents: [LaunchableAgent] { model.launcherGroups.first { $0.workspace?.id == workspace.id }?.agents ?? [] }
  var body: some View {
    List {
      Section {
        LabeledContent("Connection", value: active ? "Connected" : "Disconnected")
        if model.online, model.hostExecutionWorkspace?.id == workspace.id {
          Text("\(model.deviceWorkspaceName) syncs its library with this Mac now. Any other Mac or Linux machine that is online takes over when it isn’t.")
            .font(.caption).foregroundStyle(WovenPalette.mutedForeground).accessibilityIdentifier("workspace-library-host")
        }
        if let endpoint = workspace.endpoint { Text(endpoint.host ?? endpoint.absoluteString).textSelection(.enabled) }
        if !active {
          Text("Its agents and folders appear when this workspace is reachable again.").font(.caption)
            .foregroundStyle(WovenPalette.mutedForeground)
        }
      }
      if active {
        Section { NavigationLink("Folders") { FoldersPane(model: model, workspaceID: workspace.id) } }
        Section("Agents") {
          ForEach(agents) { agent in
            Button { Task { await model.launchAgent(agent) } } label: {
              Label { Text(agent.name) } icon: { MobileAgentIcon(runtimeKind: agent.runtimeKind, size: 22) }
            }.disabled(!agent.isAvailable)
          }
        }
      }
      Section {
        if let problem = model.workspaceProblems[workspace.id] { Text(problem).font(.caption).foregroundStyle(WovenPalette.mutedForeground) }
      }
    }.listStyle(.insetGrouped).mobileNavigationPage(workspace.name)
  }
}
