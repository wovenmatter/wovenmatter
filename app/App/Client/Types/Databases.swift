import Foundation

/// Whether a machine holding databases is this Mac or another machine.
enum DatabaseSourceKind: String, CaseIterable, Sendable {
    case local
    case remote

    var displayName: String {
        switch self {
        case .local: "Local workspace"
        case .remote: "Remote workspaces"
        }
    }
}

/// A named SQLite database. Its owning machine is its only writer; every other
/// machine reads the latest copy it published.
struct AgentDatabase: Equatable, Identifiable, Sendable {
    /// The owning machine.
    let machineID: String
    let databaseID: String
    let name: String
    /// When its data last changed, as the owner published it.
    var updatedAt: Date?
    /// The owner is unreachable, so this is its last published copy.
    var offline = false
    /// This machine holds a published copy, so it can be read and copied while the owner is away.
    var hasCopy = false

    var id: String { "\(machineID):\(databaseID)" }
}

/// One machine and the databases it owns.
struct DatabaseSource: Equatable, Identifiable, Sendable {
    /// The machine's identifier.
    let id: String
    let name: String
    let kind: DatabaseSourceKind
    let detail: String
    let databases: [AgentDatabase]
    /// Why the machine could not be reached.
    let error: String?
    /// The machine is online, so it can create a database.
    let allowsCreation: Bool
}

/// Databases on every machine.
struct DatabasesSnapshot: Equatable, Sendable {
    static let empty = DatabasesSnapshot(sources: [])

    let sources: [DatabaseSource]

    var databases: [AgentDatabase] { sources.flatMap(\.databases) }

    /// `sourceID` is the owning machine's identifier, as a database link records it.
    func database(sourceID: String, databaseID: String) -> AgentDatabase? {
        sources.first { $0.id == sourceID }?.databases.first { $0.databaseID == databaseID }
    }
}

/// Rows and columns a database link reads, with the same result as JSON for an App.
struct DatabaseTabularData: Equatable, Sendable {
    let columns: [String]
    let rows: [[String]]
    let json: String

    func applying(to existing: NoteTableBlock? = nil) -> NoteTableBlock {
        let columnCount = max(1, columns.count)
        var table = existing ?? NoteTableBlock(rows: max(1, rows.count + 1), columns: columnCount)
        while table.columns.count < columnCount { table.columns.append(NoteTableColumn()) }
        table.columns = Array(table.columns.prefix(columnCount))
        let values = [columns.isEmpty ? ["Value"] : columns] + rows
        while table.rows.count < values.count {
            table.rows.append(NoteTableRow(cellCount: columnCount))
        }
        table.rows = Array(table.rows.prefix(max(1, values.count)))
        for rowIndex in table.rows.indices {
            while table.rows[rowIndex].cells.count < columnCount {
                table.rows[rowIndex].cells.append(NoteTableCell())
            }
            table.rows[rowIndex].cells = Array(table.rows[rowIndex].cells.prefix(columnCount))
            for columnIndex in 0..<columnCount {
                let value = values.indices.contains(rowIndex) && values[rowIndex].indices.contains(columnIndex)
                    ? values[rowIndex][columnIndex] : ""
                table.rows[rowIndex].cells[columnIndex].runs = value.isEmpty ? [] : [NoteTextRun(text: value)]
            }
        }
        table.headerRowCount = columns.isEmpty ? 0 : 1
        return table.normalized()
    }
}
