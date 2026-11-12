import Foundation
import WovenMatterCore
import WovenMatterClient

/// Maps validated app operations directly to note edits. Input is already inline;
/// this service never reads a caller-supplied file or shell environment.
enum NoteToolEdits {
    static func request(_ command: WovenMatterToolCommand) throws -> NoteEditingRequest {
        guard command.group == .notes, command.options["file"] == nil else {
            throw WorkspaceToolError.invalid("Note tools require inline content and an explicit noteID.")
        }
        let noteID = try command.required("note-id", allowPositional: true)
        let revision = command.options["revision"]
        if command.action == "read" { return .init(command: .read, noteID: noteID) }
        let operations: [NoteEditOperation]
        switch command.action {
        case "append":
            operations = [.appendText(try argument(command, "text"), try style(command))]
        case "insert":
            operations = [.insertText(afterBlockID: command.options["after"],
                                      text: try argument(command, "text"), style: try style(command))]
        case "replace-block":
            operations = [.replaceBlock(id: try command.required("id"),
                                        block: try decode(NoteBlock.self, command: command, label: "block"))]
        case "delete-block":
            operations = [.deleteBlock(id: try command.required("id"))]
        case "format":
            operations = [.setParagraphStyle(blockID: try command.required("block-id"),
                                             style: try style(command, required: true))]
        case "set-title":
            operations = [.setTitle(try argument(command, "title"))]
        case "set-html":
            operations = [.setHTML(try argument(command, "html"))]
        case "link":
            let link = DatabaseArtifactLink(sourceID: try command.required("source-id"),
                                            databaseID: try command.required("database-id"),
                                            relativePath: "data.sqlite", sqliteQuery: try command.required("query"))
            if let tableID = command.options["table-id"] { operations = [.setTableDatabaseLink(tableID: tableID, link: link)] }
            else { operations = [.setArtifactDatabaseLink(link)] }
        case "unlink":
            if let tableID = command.options["table-id"] { operations = [.setTableDatabaseLink(tableID: tableID, link: nil)] }
            else { operations = [.setArtifactDatabaseLink(nil)] }
        case "table":
            operations = [try tableOperation(command)]
        case "apply":
            operations = try decode([NoteEditOperation].self, command: command, label: "operations")
            try NoteEditOperation.requireGenericNoteOperations(operations)
        case "artifact-state-edit":
            let edits = try decode([ArtifactStateEdit].self, command: command, label: "state edits")
            guard !edits.isEmpty else { throw WorkspaceToolError.invalid("Supply at least one state edit.") }
            operations = [.artifactState(edits)]
        default:
            throw WorkspaceToolError.invalid("Unsupported note edit operation: \(command.action).")
        }
        return .init(command: .apply, noteID: noteID, expectedRevision: revision, operations: operations)
    }

    /// Maps `woven_pages_*` writes to one revision-checked note mutation. No field
    /// here can carry attribution; the database stamps the caller it authorized.
    static func pageRequest(_ command: WovenMatterToolCommand, requestID: String) throws -> NoteEditingRequest {
        guard command.group == .notes, command.isPageCommand else {
            throw WorkspaceToolError.invalid("Choose a Page operation.")
        }
        let pageID = try command.required("note-id")
        let operations: [NoteEditOperation]
        var revision: String?
        switch command.action {
        case "page-update":
            revision = try command.required("revision")
            var changes: [NoteEditOperation] = [.page(.init(action: .requirePage))]
            if let title = command.options["title"] {
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 1_024 else {
                    throw WorkspaceToolError.invalid("A Page title must contain text and be at most 1,024 bytes.")
                }
                changes.append(.setTitle(title))
            }
            if let purpose = command.options["purpose"] {
                try requirePurpose(purpose)
                changes.append(.page(.init(action: .setPurpose, purpose: purpose)))
            }
            guard changes.count > 1 else { throw WorkspaceToolError.invalid("Supply a title or purpose to change.") }
            operations = changes
        case "page-add-component":
            let kind: PageComponentKind? = try choice(command, "kind")
            let block: NoteBlock? = command.options["json"] == nil ? nil : try decode(NoteBlock.self, command: command, label: "block")
            operations = [.page(.init(action: .add, id: requestID, kind: kind, block: block, patch: try pagePatch(command),
                                      assetID: command.options["asset-id"], position: position(command)))]
        case "page-update-component":
            let patch = try pagePatch(command)
            let block: NoteBlock? = command.options["json"] == nil ? nil : try decode(NoteBlock.self, command: command, label: "block")
            guard patch != BoardItemPatch() || block != nil else { throw WorkspaceToolError.invalid("Supply at least one field to change.") }
            operations = [.page(.init(action: .update, id: try command.required("id"),
                                      expectedRevision: try command.required("component-revision"), block: block, patch: patch))]
        case "page-move-component":
            operations = [.page(.init(action: .move, id: try command.required("id"),
                                      expectedRevision: command.options["component-revision"],
                                      expectedSubtreeRevision: command.options["subtree-revision"], position: position(command)))]
        case "page-remove-component":
            let removal: PageEdit.Removal? = try choice(command, "removal")
            operations = [.page(.init(action: .remove, id: try command.required("id"),
                                      expectedRevision: command.options["component-revision"],
                                      expectedSubtreeRevision: command.options["subtree-revision"], removal: removal))]
        case "page-link-session", "page-unlink-session":
            let sessionID = try command.required("session")
            guard let uuid = UUID(uuidString: sessionID) else { throw WorkspaceToolError.invalid("sessionID must be a conversation UUID.") }
            operations = [.page(.init(action: command.action == "page-link-session" ? .linkSession : .unlinkSession,
                                      id: try command.required("id"), sessionID: uuid.uuidString.lowercased()))]
        default:
            throw WorkspaceToolError.invalid("Unsupported Page operation: \(command.action).")
        }
        return .init(command: .apply, noteID: pageID, expectedRevision: revision, operations: operations)
    }

    static func requirePurpose(_ purpose: String) throws {
        guard purpose.utf8.count <= NoteDocument.maximumBoardPurposeBytes else {
            throw WorkspaceToolError.invalid("A Page purpose must be at most \(NoteDocument.maximumBoardPurposeBytes) bytes.")
        }
    }

    private static func position(_ command: WovenMatterToolCommand) -> PagePosition {
        PagePosition(parentID: command.options["parent-id"], afterID: command.options["after-id"], atStart: command.options["at-start"] != nil)
    }

    private static func choice<T: RawRepresentable>(_ command: WovenMatterToolCommand, _ key: String) throws -> T? where T.RawValue == String {
        guard let raw = command.options[key] else { return nil }
        guard let value = T(rawValue: raw) else { throw WorkspaceToolError.invalid("Unsupported \(key): \(raw).") }
        return value
    }

    private static func pagePatch(_ command: WovenMatterToolCommand) throws -> BoardItemPatch {
        func bounded(_ key: String, _ label: String, _ limit: Int) throws -> String? {
            guard let value = command.options[key] else { return nil }
            guard value.utf8.count <= limit else { throw WorkspaceToolError.invalid("\(label) must be at most \(limit) bytes.") }
            return value
        }
        let role: BoardItemRole? = try choice(command, "role")
        let status: BoardTaskStatus? = try choice(command, "status")
        let review: BoardReviewState? = try choice(command, "review")
        return BoardItemPatch(title: try bounded("title", "A title", 1_024), text: try bounded("text", "Component text", 256 * 1_024),
                              role: role, status: status,
                              assignee: try bounded("assignee", "An assignee", 1_024),
                              outcome: try bounded("outcome", "An outcome", BoardTask.maximumOutcomeBytes),
                              clearTask: command.options["clear-task"] != nil ? true : nil,
                              review: review,
                              clearReview: command.options["clear-review"] != nil ? true : nil,
                              lastChange: try bounded("last-change", "lastChange", BoardItem.maximumLastChangeBytes))
    }

    private static func tableOperation(_ command: WovenMatterToolCommand) throws -> NoteEditOperation {
        switch command.subaction {
        case "create":
            return .createTable(afterBlockID: command.options["after"],
                                rows: try command.integer("rows", default: 3, range: 1...1000),
                                columns: try command.integer("columns", default: 3, range: 1...128),
                                headerRow: command.options["header"] != nil)
        case "set-cell":
            return .setTableCell(tableID: try command.required("table-id"),
                                 row: try integer(command, "row"), column: try integer(command, "column"),
                                 runs: [NoteTextRun(text: try argument(command, "text"))])
        case "add-row":
            return .addTableRow(tableID: try command.required("table-id"), after: try optionalPosition(command))
        case "remove-row":
            return .removeTableRow(tableID: try command.required("table-id"), row: try integer(command, "row"))
        case "add-column":
            return .addTableColumn(tableID: try command.required("table-id"), after: try optionalPosition(command))
        case "remove-column":
            return .removeTableColumn(tableID: try command.required("table-id"), column: try integer(command, "column"))
        default:
            throw WorkspaceToolError.invalid("Choose a supported note table operation.")
        }
    }

    private static func style(_ command: WovenMatterToolCommand, required: Bool = false) throws -> NoteParagraphStyle {
        guard let raw = command.options["style"] else {
            if required { throw WorkspaceToolError.invalid("style is required.") }
            return .paragraph
        }
        guard let value = NoteParagraphStyle(rawValue: raw) else {
            throw WorkspaceToolError.invalid("Unknown paragraph style: \(raw).")
        }
        return value
    }

    private static func argument(_ command: WovenMatterToolCommand, _ key: String) throws -> String {
        guard let value = command.options[key] else { throw WorkspaceToolError.invalid("\(key) is required.") }
        return value
    }

    private static func integer(_ command: WovenMatterToolCommand, _ key: String) throws -> Int {
        guard let value = Int(try command.required(key)), value >= 0 else {
            throw WorkspaceToolError.invalid("\(key) must be a nonnegative integer.")
        }
        return value
    }

    private static func optionalPosition(_ command: WovenMatterToolCommand) throws -> Int? {
        guard command.options["after"] != nil else { return nil }
        return try command.integer("after", default: -1, range: -1...Int.max)
    }

    private static func decode<T: Decodable>(_ type: T.Type, command: WovenMatterToolCommand, label: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(command.required("json").utf8)) }
        catch { throw WorkspaceToolError.invalid("Invalid \(label): \(error.localizedDescription)") }
    }
}
