import SwiftUI
import WovenProtocol

/// One folder: its details as the Mac's hover card shows them, then its chats
/// and artifacts. New chat here starts with an agent of the folder's own
/// workspace; New Artifact here files the artifact in it.
struct FolderPage: View {
    @Bindable var model: MobileModel
    let folderID: String
    @State private var actions = FolderItemActions()
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var app: ApplicationModel { model.app }
    private var places: FolderPlaces { FolderPlaces(model: model) }
    private var menus: FolderMenus { FolderMenus(model: model, actions: actions) }
    private var folder: WorkspaceFolderRecord? { app.workspace.folder(id: folderID) }

    var body: some View {
        List {
            if let folder {
                FolderDetails(folder: folder, places: places).folderRow()
                FolderContentsList(model: model, actions: actions, search: $search, placeLabels: false) {
                    $0.folderID == folderID
                } artifacts: {
                    $0.folderID == folderID
                }
            }
        }
        .folderList()
        .refreshable { await app.workspace.refresh() }
        .mobilePageSurface()
        .navigationTitle(folder?.name ?? "")
        .navigationSubtitle(folder.map { places.title(of: $0.machineID) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let folder {
                ToolbarItem(placement: .topBarTrailing) { addMenu(folder) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu { menus.folder(folder) } label: {
                        Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Folder actions")
                    .accessibilityIdentifier("folders-folder-actions")
                }
            }
        }
        .folderItemPrompts(actions, model: model)
        // Removed here or on another machine: back to where it was opened from.
        .onChange(of: folder == nil) { _, gone in if gone { dismiss() } }
    }

    /// New chat with one of the folder's workspace's agents, or a new artifact in it.
    private func addMenu(_ folder: WorkspaceFolderRecord) -> some View {
        let machineID = folder.machineID
        let reachable = places.isReachable(machineID)
        return Menu {
            Section("New Chat") {
                if places.isDevice(machineID) {
                    Button { actions.startChat(.piDurable, on: machineID, folderID: folder.id, model: model) } label: {
                        Label { Text("Quick Chat") } icon: { harnessImage(.defaultAgent) }
                    }
                } else {
                    ForEach(app.workspace.agents(on: machineID)) { agent in
                        Button { actions.startChat(agent.runtimeKind.runtime, on: machineID, folderID: folder.id, model: model) } label: {
                            Label { Text(agent.displayName) } icon: { harnessImage(agent.runtimeKind) }
                        }
                        .accessibilityIdentifier("folders-new-chat-\(agent.id)")
                    }
                }
            }
            .disabled(!reachable)
            Menu {
                NewArtifactMenuItems { actions.createArtifact($0, folderID: folder.id, model: model) }
            } label: {
                Label("New Artifact", glyph: .fileText)
            }
        } label: {
            Image(LucideGlyph.plus.rawValue).renderingMode(.template).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("New in \(folder.name)")
        .accessibilityIdentifier("folders-folder-add")
    }

    private func harnessImage(_ runtime: AgentRuntimeKind) -> Image {
        Image(HarnessLogo(runtimeKind: runtime).assetName)
    }
}

/// The folder's workspace, what it holds, and its directories, quietly above its contents.
private struct FolderDetails: View {
    let folder: WorkspaceFolderRecord
    let places: FolderPlaces

    var body: some View {
        let count = places.counts[folder.id] ?? (0, 0)
        VStack(alignment: .leading, spacing: 6) {
            Text("\(count.chats) \(count.chats == 1 ? "chat" : "chats") · \(count.artifacts) \(count.artifacts == 1 ? "artifact" : "artifacts")")
                .font(.caption)
                .foregroundStyle(WovenPalette.mutedForeground)
            // A device's own directory is inside the app, so only a machine's is shown.
            if !places.isDevice(folder.machineID) {
                if let root = folder.rootPath { path("Root folder", root) }
                ForEach(Array(folder.referencePaths.enumerated()), id: \.offset) { index, reference in
                    path(index == 0 ? (folder.referencePaths.count == 1 ? "Additional folder" : "Additional folders") : nil, reference)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("folders-folder-details")
    }

    private func path(_ label: String?, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let label { Text(label).font(.caption.weight(.medium)).foregroundStyle(WovenPalette.foreground) }
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(WovenPalette.mutedForeground)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// A search field, then the chats and then the artifacts that `chats` and
/// `artifacts` pick, each pinned first and then newest, with their menus.
struct FolderContentsList: View {
    @Bindable var model: MobileModel
    let actions: FolderItemActions
    @Binding var search: String
    /// Whether each chat says where it runs, for lists that mix workspaces.
    let placeLabels: Bool
    let chats: (WorkspaceConversationRecord) -> Bool
    let artifacts: (WorkspaceNoteRecord) -> Bool

    private var places: FolderPlaces { FolderPlaces(model: model) }
    private var menus: FolderMenus { FolderMenus(model: model, actions: actions) }

    var body: some View {
        let overview = places.overview
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = { (title: String) in query.isEmpty || title.localizedCaseInsensitiveContains(query) }
        let chatRows = places.sorted(overview.conversations.filter { chats($0) && matches($0.title) })
        let artifactRows = places.sorted(overview.notes.filter { artifacts($0) && matches($0.title) })
        WovenSearchField(text: $search, prompt: "Search chats and artifacts")
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .folderRow()
            .accessibilityIdentifier("folders-search")
        if chatRows.isEmpty && artifactRows.isEmpty {
            FolderCaption(query.isEmpty ? "No chats or artifacts" : "No matches").folderRow()
        }
        if !chatRows.isEmpty {
            groupLabel("Chats")
            ForEach(chatRows) { chat in
                FolderChatRow(conversation: chat,
                              subtitle: placeLabels ? places.place(of: chat) : chat.lastMessagePreview.flatMap(Self.line)) {
                    model.open(sessionID: chat.id)
                }
                .contextMenu { menus.chat(chat) }
                .swipeActions(edge: .trailing) { menus.chatSwipes(chat) }
                .swipeActions(edge: .leading) { menus.chatPin(chat) }
                .folderRow()
            }
        }
        if !artifactRows.isEmpty {
            groupLabel("Artifacts")
            ForEach(artifactRows) { note in
                FolderArtifactRow(note: note, subtitle: Self.line(note.preview) ?? note.kind.displayName) {
                    model.open(artifactID: note.id)
                }
                .contextMenu { menus.artifact(note) }
                .swipeActions(edge: .trailing) { menus.artifactSwipes(note) }
                .swipeActions(edge: .leading) { menus.artifactPin(note) }
                .folderRow()
            }
        }
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            .folderRow()
    }

    /// The first line of a preview, or nil for none.
    private static func line(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }
}

/// Every chat and artifact across every workspace, folderless ones included.
struct AllWorkspacesPage: View {
    @Bindable var model: MobileModel
    @State private var actions = FolderItemActions()
    @State private var search = ""
    @State private var chooserPresented = false
    @Environment(\.wovenTheme) private var theme

    var body: some View {
        List {
            FolderContentsList(model: model, actions: actions, search: $search, placeLabels: true) { _ in true } artifacts: { _ in true }
        }
        .folderList()
        .refreshable { await model.app.workspace.refresh() }
        .mobilePageSurface()
        .navigationTitle("All Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { chooserPresented = true } label: { Label("New Chat", glyph: .squarePen) }
                    Menu {
                        NewArtifactMenuItems { actions.createArtifact($0, folderID: nil, model: model) }
                    } label: {
                        Label("New Artifact", glyph: .fileText)
                    }
                } label: {
                    Image(LucideGlyph.plus.rawValue).renderingMode(.template).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("New")
                .accessibilityIdentifier("folders-all-add")
            }
        }
        .sheet(isPresented: $chooserPresented) { ChatChooser(model: model).folderSheetTheme(theme) }
        .folderItemPrompts(actions, model: model)
    }
}
