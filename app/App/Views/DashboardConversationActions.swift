import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterCore

enum DashboardConversationMenuAction {
    case setPinned(Bool)
    case rename
    case export(WorkspaceConversationExportFormat)
    case moveToTrash
}

/// AppKit can retain a context menu across SwiftUI updates. Recreate its host
/// only when an action or target changes, not for new messages, previews or dates.
struct DashboardRowMenuIdentity: Hashable {
    struct Folder: Hashable {
        let id: String
        let name: String
    }

    let id: String
    let title: String
    let isPinned: Bool
    let folderID: String?
    let actionsRestricted: Bool
    let folders: [Folder]

    init(id: String, title: String, isPinned: Bool, folderID: String?, actionsRestricted: Bool,
         folders: [WorkspaceFolderRecord]) {
        self.id = id
        self.title = title
        self.isPinned = isPinned
        self.folderID = folderID
        self.actionsRestricted = actionsRestricted
        self.folders = folders.map { Folder(id: $0.id, name: $0.name) }
    }
}

struct DashboardConversationContextMenu: ViewModifier {
    let conversation: WorkspaceConversationRecord
    let folders: [WorkspaceFolderRecord]
    let isRunning: Bool
    let onMove: (String, String?) -> Void
    let onAction: (WorkspaceConversationRecord, DashboardConversationMenuAction) -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(conversation.isPinned ? "Unpin" : "Pin") {
                    onAction(conversation, .setPinned(!conversation.isPinned))
                }
                Button("Rename") { onAction(conversation, .rename) }
                Menu("Move to Folder") {
                    DashboardMoveToFolderMenu(folderID: conversation.folderID, folders: folders) {
                        onMove(conversation.id, $0)
                    }
                }
                Divider()
                Button("Export messages") { onAction(conversation, .export(.messages)) }
                Button("Export full run") { onAction(conversation, .export(.fullRun)) }
                Divider()
                Button("Move to Trash", role: .destructive) { onAction(conversation, .moveToTrash) }
                    .disabled(isRunning)
                    .help(isRunning ? "Stop this chat before moving it to Trash." : "Move this chat to Trash")
            }
            .id(DashboardRowMenuIdentity(
                id: conversation.id, title: conversation.title, isPinned: conversation.isPinned,
                folderID: conversation.folderID, actionsRestricted: isRunning, folders: folders
            ))
    }
}

struct DashboardMoveToFolderMenu: View {
    let folderID: String?
    let folders: [WorkspaceFolderRecord]
    let onMove: (String?) -> Void

    var body: some View {
        target(title: "Workspace", id: nil)
        ForEach(folders) { folder in
            target(title: folder.name, id: folder.id)
        }
    }

    private func target(title: String, id: String?) -> some View {
        Button { onMove(id) } label: {
            if folderID == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .disabled(folderID == id)
    }
}

struct DashboardRenameConversationSheet: View {
    let conversation: WorkspaceConversationRecord
    let model: ApplicationModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var error: String?
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    init(conversation: WorkspaceConversationRecord, model: ApplicationModel) {
        self.conversation = conversation
        self.model = model
        _title = State(initialValue: conversation.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename chat").font(.headline)
            TextField("Chat name", text: $title)
                .focused($titleFocused)
                .onSubmit(save)
                .disabled(saving)
            if let error { Text(error).font(.callout).foregroundStyle(DashboardPalette.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .interactiveDismissDisabled(saving)
        .onAppear { titleFocused = true }
    }

    private func save() {
        guard !saving, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        error = nil
        Task {
            do {
                try await model.mutateConversation(id: conversation.id, mutation: .rename(title))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

struct DashboardWorkspaceTrashSheet: View {
    let model: ApplicationModel
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [WorkspaceTrashedConversation] = []
    @State private var notes: [WorkspaceTrashedNote] = []
    @State private var error: String?
    @State private var loading = true
    @State private var restoringConversationIDs: Set<String> = []
    @State private var restoringNoteIDs: Set<String> = []
    @State private var reloadGeneration = 0

    private var restoring: Bool {
        !restoringConversationIDs.isEmpty || !restoringNoteIDs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trash").font(.headline)
            if let error {
                HStack {
                    Text(error).font(.callout).foregroundStyle(DashboardPalette.danger)
                    Button("Retry") { Task { await reload() } }.disabled(loading)
                }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if conversations.isEmpty && notes.isEmpty && error == nil {
                Text("No chats or notes in Trash.").foregroundStyle(.secondary)
            } else {
                List {
                    if !conversations.isEmpty {
                        Section("Chats") {
                            ForEach(conversations) { conversation in
                                HStack {
                                    Text(conversation.title).lineLimit(2)
                                    Spacer()
                                    Button("Restore") { restore(conversation) }
                                        .disabled(restoringConversationIDs.contains(conversation.id))
                                        .accessibilityLabel("Restore chat \(conversation.title)")
                                }
                            }
                        }
                    }
                    if !notes.isEmpty {
                        Section("Notes") {
                            ForEach(notes) { note in
                                HStack {
                                    Text(note.title).lineLimit(2)
                                    Spacer()
                                    Button("Restore") { restore(note) }
                                        .disabled(restoringNoteIDs.contains(note.id))
                                        .accessibilityLabel("Restore note \(note.title)")
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                if !conversations.isEmpty {
                    Text("Restored chats keep their messages. Their timers stay paused.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(restoring)
            }
        }
        .padding(24)
        .frame(width: 480, height: 400)
        .interactiveDismissDisabled(restoring)
        .task { await reload() }
        .onDisappear { reloadGeneration += 1 }
    }

    private func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        loading = true
        do {
            async let conversationsRequest = model.trashedConversations()
            async let notesRequest = model.trashedNotes()
            let snapshot = try await (conversationsRequest, notesRequest)
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            conversations = snapshot.0
            notes = snapshot.1
            error = nil
        } catch {
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func restore(_ conversation: WorkspaceTrashedConversation) {
        guard restoringConversationIDs.insert(conversation.id).inserted else { return }
        error = nil
        Task {
            defer { restoringConversationIDs.remove(conversation.id) }
            do {
                try await model.mutateConversation(id: conversation.id, mutation: .restore)
                await reload()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func restore(_ note: WorkspaceTrashedNote) {
        guard restoringNoteIDs.insert(note.id).inserted else { return }
        error = nil
        Task {
            defer { restoringNoteIDs.remove(note.id) }
            do {
                try await model.mutateNote(id: note.id, mutation: .restore)
                await reload()
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
enum DashboardConversationExport {
    static func save(url: URL, title: String, format: WorkspaceConversationExportFormat) async throws -> Bool {
        try await DashboardStagedExport.save(
            url: url,
            panelTitle: format == .messages ? "Export messages" : "Export full run",
            suggestedFilename: format.suggestedFilename(title: title),
            contentType: format == .messages ? UTType(filenameExtension: "md") ?? .plainText : .json
        )
    }
}

@MainActor
enum DashboardStagedExport {
    /// The backend stages the snapshot; only the UI owns the user-selected destination.
    static func save(url stagedURL: URL, panelTitle: String, suggestedFilename: String, contentType: UTType) async throws -> Bool {
        var removeStagedFile = true
        defer { if removeStagedFile { try? FileManager.default.removeItem(at: stagedURL) } }
        try Task.checkCancellation()
        let panel = NSSavePanel()
        panel.title = panelTitle
        panel.nameFieldStringValue = suggestedFilename
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: NSApplication.ModalResponse.cancel); return }
                panel.begin { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
        try Task.checkCancellation()
        guard response == .OK, let destination = panel.url else { return false }
        // The chosen destination owns the file, even if the user selects its staging path.
        if destination.resolvingSymlinksInPath() == stagedURL.resolvingSymlinksInPath() {
            removeStagedFile = false
            return true
        }
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        // Atomic replacement preserves any existing destination on failure. Never
        // delete the user's destination during error or cancellation cleanup.
        try await WorkspaceExportFileIO.perform {
            try Data(contentsOf: stagedURL, options: .mappedIfSafe).write(to: destination, options: .atomic)
        }
        return true
    }
}
