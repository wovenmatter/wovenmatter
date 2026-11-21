import SwiftUI
import WovenProtocol

/// The Folders tab, where you find your way around: New Chat and New
/// Artifact, All Workspaces, this device with Quick Chat and its own folders,
/// then each machine's workspace, online or offline, with its agents and
/// folders, then Trash, and Recents across everything.
struct FoldersTab: View {
    @Bindable var model: MobileModel
    @Environment(\.wovenTheme) private var theme
    @State private var actions = FolderItemActions()
    @State private var chooserPresented = false
    @State private var newFolderOwner: FolderOwner?
    /// Headings folded away, kept between launches.
    @AppStorage("wovenmatter.mobile.folders.collapsed") private var collapsedRaw = ""
    @ScaledMetric(relativeTo: .body) private var logo: CGFloat = 22

    private var app: ApplicationModel { model.app }
    private var places: FolderPlaces { FolderPlaces(model: model) }
    private var menus: FolderMenus { FolderMenus(model: model, actions: actions) }

    var body: some View {
        VStack(spacing: 0) {
            TabRootHeader(title: "Folders")
            List {
                topRows
                deviceSection
                if app.machines.machines.isEmpty {
                    connectRows
                } else {
                    ForEach(app.machines.machines) { machineSection($0) }
                }
                row(glyph: .trash, title: "Trash", identifier: "folders-trash") { push(.trash) }
                    .padding(.top, 8)
                recents
            }
            .folderList()
            .refreshable { await app.workspace.refresh() }
        }
        .navigationDestination(for: FoldersRoute.self) { route in
            switch route {
            case .all: AllWorkspacesPage(model: model)
            case .folder(let id): FolderPage(model: model, folderID: id)
            case .trash: FoldersTrashPage(model: model)
            }
        }
        .sheet(isPresented: $chooserPresented) {
            ChatChooser(model: model).folderSheetTheme(theme)
        }
        .sheet(item: $newFolderOwner) { owner in
            NewFolderSheet(model: model, owner: owner).folderSheetTheme(theme)
        }
        .folderItemPrompts(actions, model: model)
    }

    // MARK: Top

    @ViewBuilder private var topRows: some View {
        row(glyph: .squarePen, title: "New Chat", identifier: "folders-new-chat") { chooserPresented = true }
        Menu {
            NewArtifactMenuItems { actions.createArtifact($0, folderID: nil, model: model) }
        } label: {
            FolderRowLabel(title: "New Artifact") { FolderGlyph(glyph: .fileText) }
        }
        .buttonStyle(FolderRowButtonStyle())
        .accessibilityIdentifier("folders-new-artifact")
        .folderRow()
        row(glyph: .folderOpen, title: "All Workspaces", identifier: "folders-all") { push(.all) }
            .padding(.bottom, 4)
    }

    // MARK: This device

    @ViewBuilder private var deviceSection: some View {
        let key = "device"
        FolderHeading(title: FolderPlaces.deviceTitle, expanded: isExpanded(key)) { toggle(key) }
            .folderRow()
            .accessibilityIdentifier("folders-device")
        if isExpanded(key) {
            subheading("Agents", key: key + ":agents")
            if isExpanded(key + ":agents") {
                Button {
                    model.chat.newChat(.quickChat)
                    model.tab = .chat
                } label: {
                    FolderRowLabel(title: "Quick Chat") { AgentIcon(runtime: .defaultAgent, size: logo) }
                }
                .buttonStyle(FolderRowButtonStyle())
                .accessibilityIdentifier("folders-quick-chat")
                .folderRow(indent: 8)
            }
            if let deviceID = places.deviceID {
                foldersGroup(machineID: deviceID, key: key)
            }
        }
    }

    // MARK: Machines

    @ViewBuilder private func machineSection(_ machine: Machine) -> some View {
        let key = "machine:" + machine.id
        FolderHeading(title: machine.name, detail: machine.isOnline ? nil : "Offline", expanded: isExpanded(key)) { toggle(key) }
            .folderRow()
            .padding(.top, 4)
            .accessibilityIdentifier("folders-machine-\(machine.id)")
        if isExpanded(key) {
            let agents = app.workspace.agents(on: machine.id)
            if !agents.isEmpty || machine.isOnline {
                subheading("Agents", key: key + ":agents")
                if isExpanded(key + ":agents") {
                    if agents.isEmpty { FolderCaption("No agents").folderRow(indent: 8) }
                    ForEach(agents) { agent in
                        Button {
                            model.chat.newChat(ChatTarget(runtime: agent.runtimeKind.runtime, machineID: machine.id))
                            model.tab = .chat
                        } label: {
                            FolderRowLabel(title: agent.displayName) { AgentIcon(runtime: agent.runtimeKind, size: logo) }
                        }
                        .buttonStyle(FolderRowButtonStyle())
                        .disabled(!machine.isOnline)
                        .accessibilityLabel("New chat with \(agent.displayName) on \(machine.name)")
                        .accessibilityIdentifier("folders-agent-\(agent.id)")
                        .folderRow(indent: 8)
                    }
                }
            }
            foldersGroup(machineID: machine.id, key: key)
        }
    }

    /// A workspace's Folders: New folder first, then its folders, pinned first.
    @ViewBuilder private func foldersGroup(machineID: String, key: String) -> some View {
        subheading("Folders", key: key + ":folders")
        if isExpanded(key + ":folders") {
            if places.isReachable(machineID) {
                row(glyph: .plus, title: "New folder", identifier: "folders-new-folder-\(machineID)", indent: 8) {
                    newFolderOwner = places.owner(machineID)
                }
            }
            let counts = places.counts
            ForEach(places.folders(on: machineID)) { folder in
                let count = counts[folder.id].map { $0.chats + $0.artifacts } ?? 0
                Button { push(.folder(folder.id)) } label: {
                    FolderRowLabel(title: folder.name) { FolderGlyph(glyph: .folder) } trailing: {
                        HStack(spacing: 6) {
                            if folder.isPinned { LucideIcon(glyph: .pin, size: 12) }
                            Text("\(count)").monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(WovenPalette.mutedForeground)
                    }
                }
                .buttonStyle(FolderRowButtonStyle())
                .contextMenu { menus.folder(folder) }
                .swipeActions(edge: .leading) { menus.folderPin(folder) }
                .accessibilityValue(folder.isPinned ? "Pinned, \(count) items" : "\(count) items")
                .accessibilityIdentifier("folders-folder-\(folder.id)")
                .folderRow(indent: 8)
            }
        }
    }

    // MARK: No machine yet

    @ViewBuilder private var connectRows: some View {
        row(glyph: .monitor, title: "Connect your Mac", identifier: "folders-connect-mac") {
            model.openSettings(.connectMachine)
        }
        .padding(.top, 8)
        FolderCaption("Use your Mac’s agents and folders here, with your chats and artifacts on both.")
            .folderRow()
            .accessibilityIdentifier("folders-connect-mac-caption")
    }

    // MARK: Recents

    @ViewBuilder private var recents: some View {
        let key = "recents"
        FolderHeading(title: "Recents", expanded: isExpanded(key)) { toggle(key) }
            .folderRow()
            .padding(.top, 8)
            .accessibilityIdentifier("folders-recents")
        if isExpanded(key) {
            let items = places.recents
            if items.isEmpty { FolderCaption("No recent items").folderRow() }
            ForEach(items) { item in
                switch item {
                case .chat(let chat):
                    FolderChatRow(conversation: chat, subtitle: places.place(of: chat)) { model.open(sessionID: chat.id) }
                        .contextMenu { menus.chat(chat) }
                        .swipeActions(edge: .trailing) { menus.chatSwipes(chat) }
                        .swipeActions(edge: .leading) { menus.chatPin(chat) }
                        .folderRow()
                case .artifact(let note):
                    FolderArtifactRow(note: note, subtitle: note.kind.displayName) { model.open(artifactID: note.id) }
                        .contextMenu { menus.artifact(note) }
                        .swipeActions(edge: .trailing) { menus.artifactSwipes(note) }
                        .swipeActions(edge: .leading) { menus.artifactPin(note) }
                        .folderRow()
                }
            }
        }
    }

    // MARK: Parts

    private func row(glyph: LucideGlyph, title: String, identifier: String, indent: CGFloat = 0,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FolderRowLabel(title: title) { FolderGlyph(glyph: glyph) }
        }
        .buttonStyle(FolderRowButtonStyle())
        .accessibilityIdentifier(identifier)
        .folderRow(indent: indent)
    }

    private func subheading(_ title: String, key: String) -> some View {
        FolderHeading(title: title, level: 2, expanded: isExpanded(key)) { toggle(key) }
            .folderRow(indent: 8)
            .accessibilityIdentifier("folders-heading-\(key)")
    }

    private func push(_ route: FoldersRoute) {
        model.paths[.folders, default: NavigationPath()].append(route)
    }

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }

    private func isExpanded(_ key: String) -> Bool { !collapsed.contains(key) }

    private func toggle(_ key: String) {
        var keys = collapsed
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        collapsedRaw = keys.sorted().joined(separator: "\n")
    }
}
