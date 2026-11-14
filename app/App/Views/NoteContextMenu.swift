import SwiftUI
import UniformTypeIdentifiers
import WovenMatterCore

enum NoteMenuAction {
    case setPinned(Bool)
    case rename
    case moveToFolder(String?)
    case export(WorkspaceNoteExportFormat)
    case moveToTrash
}

struct NoteContextMenu: ViewModifier {
    @Environment(\.workspaceApplicationModel) private var model
    let note: WorkspaceNoteRecord
    let folders: [WorkspaceFolderRecord]
    let onAction: (WorkspaceNoteRecord, NoteMenuAction) -> Void

    private var isBusy: Bool { model?.noteActionIDs.contains(note.id) == true }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Group {
                    Button(note.isPinned ? "Unpin" : "Pin") { onAction(note, .setPinned(!note.isPinned)) }
                    Button("Rename") { onAction(note, .rename) }
                    Menu("Move to Folder") {
                        MoveToFolderMenu(folderID: note.folderID, folders: folders) {
                            onAction(note, .moveToFolder($0))
                        }
                    }
                    Divider()
                    Button("Export asset") { onAction(note, .export(.standard)) }
                    Button("Export document") { onAction(note, .export(.document)) }
                        .help("Save the complete Note, Sheet, Artifact, or Page as JSON.")
                    Divider()
                    Button("Move to Trash", role: .destructive) { onAction(note, .moveToTrash) }
                }
                .disabled(isBusy)
            }
            .id(RowMenuIdentity(
                id: note.id, title: note.title, isPinned: note.isPinned,
                folderID: note.folderID, actionsRestricted: isBusy, folders: folders
            ))
    }
}

@MainActor
enum NoteExport {
    static func save(_ export: WorkspaceNoteExport) async throws -> Bool {
        try await StagedExport.save(
            url: export.url,
            panelTitle: "Export asset",
            suggestedFilename: export.suggestedFilename,
            contentType: UTType(filenameExtension: export.fileExtension) ?? .data
        )
    }
}
