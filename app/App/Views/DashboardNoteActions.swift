import SwiftUI
import UniformTypeIdentifiers
import WovenMatterCore

enum DashboardNoteMenuAction {
    case setPinned(Bool)
    case rename
    case moveToFolder(String?)
    case export(WorkspaceNoteExportFormat)
    case moveToTrash
}

struct DashboardNoteContextMenu: ViewModifier {
    @Environment(\.workspaceApplicationModel) private var model
    let note: WorkspaceNoteRecord
    let folders: [WorkspaceFolderRecord]
    let onAction: (WorkspaceNoteRecord, DashboardNoteMenuAction) -> Void

    private var isBusy: Bool { model?.noteActionIDs.contains(note.id) == true }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Group {
                    Button(note.isPinned ? "Unpin" : "Pin") { onAction(note, .setPinned(!note.isPinned)) }
                    Button("Rename") { onAction(note, .rename) }
                    Menu("Move to Folder") {
                        DashboardMoveToFolderMenu(folderID: note.folderID, folders: folders) {
                            onAction(note, .moveToFolder($0))
                        }
                    }
                    Divider()
                    Button("Export note") { onAction(note, .export(.standard)) }
                    Button("Export document") { onAction(note, .export(.document)) }
                        .help("Save the complete note, spreadsheet or HTML document as JSON.")
                    Divider()
                    Button("Move to Trash", role: .destructive) { onAction(note, .moveToTrash) }
                }
                .disabled(isBusy)
            }
            .id(DashboardRowMenuIdentity(
                id: note.id, title: note.title, isPinned: note.isPinned,
                folderID: note.folderID, actionsRestricted: isBusy, folders: folders
            ))
    }
}

struct DashboardRenameNoteSheet: View {
    let note: WorkspaceNoteRecord
    let model: ApplicationModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var error: String?
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    init(note: WorkspaceNoteRecord, model: ApplicationModel) {
        self.note = note
        self.model = model
        _title = State(initialValue: model.noteDraft(for: note).title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename note").font(.headline)
            TextField("Note name", text: $title)
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
                try await model.mutateNote(id: note.id, mutation: .rename(title))
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

@MainActor
enum DashboardNoteExport {
    static func save(_ export: WorkspaceNoteExport) async throws -> Bool {
        try await DashboardStagedExport.save(
            url: export.url,
            panelTitle: "Export note",
            suggestedFilename: export.suggestedFilename,
            contentType: UTType(filenameExtension: export.fileExtension) ?? .data
        )
    }
}
