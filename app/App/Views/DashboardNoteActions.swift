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
                    Button("Export asset") { onAction(note, .export(.standard)) }
                    Button("Export document") { onAction(note, .export(.document)) }
                        .help("Save the complete Note, Sheet, Artifact, or Page as JSON.")
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

@MainActor
enum DashboardNoteExport {
    static func save(_ export: WorkspaceNoteExport) async throws -> Bool {
        try await DashboardStagedExport.save(
            url: export.url,
            panelTitle: "Export asset",
            suggestedFilename: export.suggestedFilename,
            contentType: UTType(filenameExtension: export.fileExtension) ?? .data
        )
    }
}
