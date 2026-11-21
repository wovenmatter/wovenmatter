import SwiftUI
import WovenProtocol

/// Chats and artifacts in Trash, most recently trashed first. Each can be
/// restored or deleted for good from every library.
struct FoldersTrashPage: View {
    @Bindable var model: MobileModel
    @State private var chats: [WorkspaceTrashedConversation] = []
    @State private var artifacts: [WorkspaceTrashedNote] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var choosing: Item?
    @State private var deleting: Item?

    private var workspace: WorkspaceStore { model.app.workspace }

    enum Item: Identifiable, Equatable {
        case chat(WorkspaceTrashedConversation)
        case artifact(WorkspaceTrashedNote)

        var id: String {
            switch self {
            case .chat(let chat): "chat:" + chat.id
            case .artifact(let note): "artifact:" + note.id
            }
        }

        var title: String {
            switch self {
            case .chat(let chat): chat.title
            case .artifact(let note): note.title.isEmpty ? note.kind.untitledName : note.title
            }
        }
    }

    var body: some View {
        List {
            if loaded && chats.isEmpty && artifacts.isEmpty {
                FolderCaption("Trash is empty").folderRow().accessibilityIdentifier("folders-trash-empty")
            }
            if !chats.isEmpty {
                label("Chats")
                ForEach(chats) { chat in
                    row(.chat(chat)) {
                        FolderRowLabel(title: chat.title, subtitle: folderRowTime(chat.trashedAt)) {
                            FolderGlyph(glyph: .messageSquare)
                        }
                    }
                }
            }
            if !artifacts.isEmpty {
                label("Artifacts")
                ForEach(artifacts) { note in
                    row(.artifact(note)) {
                        FolderRowLabel(title: Item.artifact(note).title, subtitle: note.kind.displayName) {
                            ArtifactKindIcon(kind: note.kind)
                        }
                    }
                }
            }
        }
        .folderList()
        .refreshable { await load() }
        .mobilePageSurface()
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        // The library changes (a restore elsewhere, a chat trashed on the Mac): read again.
        .task(id: workspace.workspaceOverview) { await load() }
        .confirmationDialog(choosing?.title ?? "", isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                            titleVisibility: .visible, presenting: choosing) { item in
            Button("Restore") { restore(item) }
            Button("Delete Forever", role: .destructive) { deleting = item }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleting.map { "Delete “\($0.title)” forever?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Delete Forever", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is deleted from every machine and device. This can’t be undone.")
        }
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            .folderRow()
    }

    private func row<RowLabel: View>(_ item: Item, @ViewBuilder label: () -> RowLabel) -> some View {
        Button { choosing = item } label: { label() }
            .buttonStyle(FolderRowButtonStyle())
            .swipeActions(edge: .leading) {
                Button { restore(item) } label: { Label("Restore", glyph: .rotate) }
                    .tint(WovenPalette.primary)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { deleting = item } label: { Label("Delete", glyph: .trash) }
            }
            .accessibilityHint("Shows Restore and Delete Forever")
            .accessibilityIdentifier("folders-trash-\(item.id)")
            .folderRow()
    }

    private func load() async {
        do {
            async let chats = workspace.trashedConversations()
            async let artifacts = workspace.trashedNotes()
            (self.chats, self.artifacts) = try await (chats, artifacts)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func restore(_ item: Item) {
        change(item) {
            switch item {
            case .chat(let chat): try await workspace.mutateConversation(id: chat.id, mutation: .restore)
            case .artifact(let note): try await workspace.mutateNote(id: note.id, mutation: .restore)
            }
        }
    }

    private func delete(_ item: Item) {
        change(item) {
            switch item {
            case .chat(let chat): try await workspace.mutateConversation(id: chat.id, mutation: .delete)
            case .artifact(let note): try await workspace.mutateNote(id: note.id, mutation: .delete)
            }
        }
    }

    private func change(_ item: Item, _ body: @escaping @MainActor () async throws -> Void) {
        // Gone from the list at once; a failure brings it back.
        switch item {
        case .chat(let chat): chats.removeAll { $0.id == chat.id }
        case .artifact(let note): artifacts.removeAll { $0.id == note.id }
        }
        Task {
            do { try await body() } catch { self.error = error.localizedDescription }
            await load()
        }
    }
}
