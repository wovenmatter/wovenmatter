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

struct DashboardConversationTrashSheet: View {
    let model: ApplicationModel
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [WorkspaceTrashedConversation] = []
    @State private var error: String?
    @State private var loading = true
    @State private var restoringIDs: Set<String> = []
    @State private var reloadGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chats in Trash").font(.headline)
            if let error { Text(error).font(.callout).foregroundStyle(DashboardPalette.danger) }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if conversations.isEmpty {
                Text("No chats in Trash.").foregroundStyle(.secondary)
            } else {
                List(conversations) { conversation in
                    HStack {
                        Text(conversation.title).lineLimit(2)
                        Spacer()
                        Button("Restore") { restore(conversation) }
                            .disabled(restoringIDs.contains(conversation.id))
                            .accessibilityLabel("Restore \(conversation.title)")
                    }
                }
                .scrollIndicators(.never)
                Text("Restored chats keep their messages. Their timers stay paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 360)
        .task { await reload() }
    }

    private func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let snapshot = try await model.trashedConversations()
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            conversations = snapshot
            error = nil
        } catch {
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func restore(_ conversation: WorkspaceTrashedConversation) {
        guard restoringIDs.insert(conversation.id).inserted else { return }
        error = nil
        Task {
            defer { restoringIDs.remove(conversation.id) }
            do {
                try await model.mutateConversation(id: conversation.id, mutation: .restore)
                await reload()
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
enum DashboardConversationExport {
    /// The backend stages the snapshot; only the UI owns the user-selected destination.
    static func save(url: URL, title: String, format: WorkspaceConversationExportFormat) async throws -> Bool {
        var removeStagedFile = true
        defer { if removeStagedFile { try? FileManager.default.removeItem(at: url) } }
        let panel = NSSavePanel()
        panel.title = format == .messages ? "Export messages" : "Export full run"
        panel.nameFieldStringValue = format.suggestedFilename(title: title)
        panel.allowedContentTypes = [format == .messages ? UTType(filenameExtension: "md") ?? .plainText : .json]
        panel.canCreateDirectories = true
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let destination = panel.url else { return false }
        // The chosen destination owns the file, even if the user selects its staging path.
        if destination.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() {
            removeStagedFile = false
            return true
        }
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Data(contentsOf: url, options: .mappedIfSafe).write(to: destination, options: .atomic)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        return true
    }
}
