import Observation
import SwiftUI
import WovenProtocol

/// What the Folders pages do to chats, artifacts and folders, through the
/// shared `WorkspaceStore` as the Mac's sidebar does: renames, pins, moves,
/// Trash, and folder removal. Each page keeps its own, so its prompts show
/// over that page. A folder change goes to its owner; pinning is the person's
/// and works while the owner is away.
@MainActor
@Observable
final class FolderItemActions {
    enum Target: Equatable {
        case chat(String)
        case artifact(String)
        case folder(String)
    }

    /// What the rename prompt renames, and the name being typed.
    var renaming: Target?
    var name = ""
    var removingFolder: WorkspaceFolderRecord?
    /// The last change that failed.
    var error: String?

    func rename(_ target: Target, from current: String) {
        name = current
        renaming = target
    }

    func commitRename(_ app: ApplicationModel) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = renaming, !name.isEmpty else { return }
        renaming = nil
        switch target {
        case .chat(let id): mutate(chat: id, .rename(name), app)
        case .artifact(let id): mutate(artifact: id, .rename(name), app)
        case .folder(let id): folder(app) { await $0.renameFolder(id: id, name: name) }
        }
    }

    func mutate(chat id: String, _ mutation: WorkspaceConversationMutation, _ app: ApplicationModel) {
        Task {
            do { try await app.workspace.mutateConversation(id: id, mutation: mutation) }
            catch { self.error = error.localizedDescription }
        }
    }

    func mutate(artifact id: String, _ mutation: WorkspaceNoteMutation, _ app: ApplicationModel) {
        Task {
            do { try await app.workspace.mutateNote(id: id, mutation: mutation) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Runs a folder change; the store reports a failure in `folderMutationError`.
    func folder(_ app: ApplicationModel, _ change: @escaping (WorkspaceStore) async -> Bool) {
        Task {
            guard await !change(app.workspace) else { return }
            error = app.workspace.folderMutationError ?? "The folder could not be changed."
            app.workspace.clearFolderMutationError()
        }
    }

    /// Makes an artifact, in `folderID` when given, and opens it in the Artifacts tab.
    func createArtifact(_ kind: NoteArtifactKind, folderID: String?, model: MobileModel) {
        Task {
            if let id = await model.app.workspace.createNote(folderID: folderID, kind: kind) {
                model.open(artifactID: id)
            } else {
                error = model.app.workspace.noteMutationError ?? "The artifact could not be made."
                model.app.workspace.clearNoteMutationError()
            }
        }
    }

    /// Starts a chat with `runtime` on its machine in the folder, and opens it in the Chat tab.
    func startChat(_ runtime: RuntimeKind, on machineID: String, folderID: String, model: MobileModel) {
        Task {
            do { model.open(sessionID: try await model.app.workspace.startSession(runtime: runtime, on: machineID, folderID: folderID)) }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// The context menus and swipe actions for chats, artifacts and folders.
@MainActor
struct FolderMenus {
    let model: MobileModel
    let actions: FolderItemActions

    private var app: ApplicationModel { model.app }
    private var places: FolderPlaces { FolderPlaces(model: model) }

    @ViewBuilder
    func chat(_ chat: WorkspaceConversationRecord) -> some View {
        Button(chat.isPinned ? "Unpin" : "Pin") { actions.mutate(chat: chat.id, .setPinned(!chat.isPinned), app) }
        Button("Rename") { actions.rename(.chat(chat.id), from: chat.title) }
        // A chat moves only among its own machine's folders.
        let folders = places.folders(on: chat.machineID)
        if !folders.isEmpty {
            Menu("Move to Folder") {
                moveTargets(current: chat.folderID, groups: [(nil, folders)]) {
                    actions.mutate(chat: chat.id, .moveToFolder($0), app)
                }
            }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { actions.mutate(chat: chat.id, .moveToTrash, app) }
            .disabled(chat.activity == .working)
    }

    @ViewBuilder
    func artifact(_ note: WorkspaceNoteRecord) -> some View {
        Button(note.isPinned ? "Unpin" : "Pin") { actions.mutate(artifact: note.id, .setPinned(!note.isPinned), app) }
        Button("Rename") { actions.rename(.artifact(note.id), from: note.title) }
        let groups = places.folderGroups
        if !groups.isEmpty {
            Menu("Move to Folder") {
                moveTargets(current: note.folderID, groups: groups.map { ($0.owner.name, $0.folders) }) {
                    actions.mutate(artifact: note.id, .moveToFolder($0), app)
                }
            }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { actions.mutate(artifact: note.id, .moveToTrash, app) }
    }

    /// Pinning works whoever owns the folder; renaming and removing need its owner.
    @ViewBuilder
    func folder(_ folder: WorkspaceFolderRecord) -> some View {
        Button(folder.isPinned ? "Unpin" : "Pin") {
            actions.folder(app) { await $0.setFolderPinned(id: folder.id, isPinned: !folder.isPinned) }
        }
        if places.isReachable(folder.machineID) {
            Button("Rename") { actions.rename(.folder(folder.id), from: folder.name) }
            Divider()
            Button("Remove Folder…", role: .destructive) { actions.removingFolder = folder }
        }
    }

    @ViewBuilder
    func chatSwipes(_ chat: WorkspaceConversationRecord) -> some View {
        Button(role: .destructive) { actions.mutate(chat: chat.id, .moveToTrash, app) } label: {
            Label("Trash", glyph: .trash)
        }
        .disabled(chat.activity == .working)
    }

    @ViewBuilder
    func artifactSwipes(_ note: WorkspaceNoteRecord) -> some View {
        Button(role: .destructive) { actions.mutate(artifact: note.id, .moveToTrash, app) } label: {
            Label("Trash", glyph: .trash)
        }
    }

    @ViewBuilder
    func chatPin(_ chat: WorkspaceConversationRecord) -> some View {
        Button { actions.mutate(chat: chat.id, .setPinned(!chat.isPinned), app) } label: {
            Label(chat.isPinned ? "Unpin" : "Pin", glyph: .pin)
        }
        .tint(WovenPalette.primary)
    }

    @ViewBuilder
    func artifactPin(_ note: WorkspaceNoteRecord) -> some View {
        Button { actions.mutate(artifact: note.id, .setPinned(!note.isPinned), app) } label: {
            Label(note.isPinned ? "Unpin" : "Pin", glyph: .pin)
        }
        .tint(WovenPalette.primary)
    }

    @ViewBuilder
    func folderPin(_ folder: WorkspaceFolderRecord) -> some View {
        Button {
            actions.folder(app) { await $0.setFolderPinned(id: folder.id, isPinned: !folder.isPinned) }
        } label: {
            Label(folder.isPinned ? "Unpin" : "Pin", glyph: .pin)
        }
        .tint(WovenPalette.primary)
    }

    /// All Workspaces (no folder), then each group's folders under its workspace's name.
    @ViewBuilder
    private func moveTargets(current: String?, groups: [(String?, [WorkspaceFolderRecord])],
                             move: @escaping (String?) -> Void) -> some View {
        target("All Workspaces", id: nil, current: current, move: move)
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            if let title = group.0 {
                Section(title) {
                    ForEach(group.1) { folder in target(folder.name, id: folder.id, current: current, move: move) }
                }
            } else {
                ForEach(group.1) { folder in target(folder.name, id: folder.id, current: current, move: move) }
            }
        }
    }

    private func target(_ title: String, id: String?, current: String?, move: @escaping (String?) -> Void) -> some View {
        Button { move(id) } label: {
            if current == id { Label(title, glyph: .check) } else { Text(title) }
        }
        .disabled(current == id)
    }
}

/// The rename prompt, the folder removal question and failures, over one page.
private struct FolderItemPrompts: ViewModifier {
    @Bindable var actions: FolderItemActions
    let model: MobileModel

    private var places: FolderPlaces { FolderPlaces(model: model) }

    func body(content: Content) -> some View {
        content
            .alert(renameTitle, isPresented: Binding(get: { actions.renaming != nil },
                                                     set: { if !$0 { actions.renaming = nil } })) {
                TextField("Name", text: $actions.name)
                    .accessibilityIdentifier("folders-rename-field")
                Button("Cancel", role: .cancel) {}
                Button("Rename") { actions.commitRename(model.app) }
                    .disabled(actions.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog(removal.map { "Remove \($0.name)?" } ?? "",
                                isPresented: Binding(get: { actions.removingFolder != nil },
                                                     set: { if !$0 { actions.removingFolder = nil } }),
                                titleVisibility: .visible, presenting: removal) { folder in
                Button("Remove Folder Only", role: .destructive) { remove(folder, deleteRoot: false) }
                if folder.managedRoot {
                    Button("Delete Folder and Directory", role: .destructive) { remove(folder, deleteRoot: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { folder in
                Text(removalMessage(folder))
            }
            .alert(actions.error ?? "", isPresented: Binding(get: { actions.error != nil },
                                                             set: { if !$0 { actions.error = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }

    private var removal: WorkspaceFolderRecord? { actions.removingFolder }

    private var renameTitle: String {
        switch actions.renaming {
        case .chat: "Rename Chat"
        case .artifact: "Rename Artifact"
        case .folder: "Rename Folder"
        case nil: ""
        }
    }

    private func remove(_ folder: WorkspaceFolderRecord, deleteRoot: Bool) {
        actions.folder(model.app) { await $0.deleteFolder(id: folder.id, deleteRoot: deleteRoot) }
    }

    /// As the Mac asks it. A device's own directory is in the app, so it is not named.
    private func removalMessage(_ folder: WorkspaceFolderRecord) -> String {
        guard folder.managedRoot else {
            return "Remove the folder from Woven. Its directory, files, chats and artifacts are kept."
        }
        if !places.isDevice(folder.machineID), let root = folder.rootPath {
            return "Remove the folder from Woven, or also delete its directory and every file in it: \(root). Chats and artifacts stay in Woven."
        }
        return "Remove the folder from Woven, or also delete its directory and every file in it. Chats and artifacts stay in Woven."
    }
}

extension View {
    func folderItemPrompts(_ actions: FolderItemActions, model: MobileModel) -> some View {
        modifier(FolderItemPrompts(actions: actions, model: model))
    }
}
