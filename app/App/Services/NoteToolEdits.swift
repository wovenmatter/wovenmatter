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
        case "canvas":
            operations = try decode([CanvasEdit].self, command: command, label: "canvas edits").map(NoteEditOperation.canvas)
        case "apply":
            operations = try decode([NoteEditOperation].self, command: command, label: "operations")
        default:
            throw WorkspaceToolError.invalid("Unsupported note edit operation: \(command.action).")
        }
        return .init(command: .apply, noteID: noteID, expectedRevision: revision, operations: operations)
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
