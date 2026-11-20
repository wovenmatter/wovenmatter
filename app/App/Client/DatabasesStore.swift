import Foundation
import Observation
import WovenProtocol

/// Databases on every machine, as this Mac's server lists them. Writes for
/// another machine's database are forwarded by this Mac's server to the owner;
/// reads of one come from the owner's latest published copy.
@MainActor
@Observable
final class DatabasesStore {
    /// Every machine that holds databases, this Mac first.
    private(set) var snapshot = DatabasesSnapshot.empty
    private(set) var isRefreshing = false
    /// The last database command that failed, until cleared.
    private(set) var error: String?

    @ObservationIgnored private weak var server: ServerConnection?
    @ObservationIgnored private weak var machines: MachinesStore?

    init() {}

    func attach(_ server: ServerConnection, machines: MachinesStore) {
        self.server = server
        self.machines = machines
    }

    /// Reads every database in the library again.
    func refresh() async {
        // A refresh asked for during one runs once more after it.
        refreshAgain = true
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        while refreshAgain {
            refreshAgain = false
            let known = machines?.machines ?? []
            do {
                guard let server, server.isConnected else { throw ClientError.notConnected }
                snapshot = Self.snapshot(databases: try await server.call(ListDatabases()), machines: known,
                                         thisMachine: server.remote?.machine, error: nil)
            } catch {
                snapshot = Self.snapshot(databases: [], machines: known, thisMachine: server?.remote?.machine,
                                         error: Self.message(error))
            }
        }
    }

    @ObservationIgnored private var refreshAgain = false

    /// One source per machine, this Mac first, then any owner the machine list does not know.
    private static func snapshot(databases: [Database], machines: [Machine], thisMachine: WovenProtocol.Machine?,
                                 error: String?) -> DatabasesSnapshot {
        var sources = machines.map { machine in
            source(id: machine.id, name: machine.name, kind: machine.isThisMachine ? .local : .remote,
                   detail: machine.isThisMachine ? "\(machine.platform.displayName) · This Mac" : machine.platform.displayName,
                   online: machine.isOnline, databases: databases, error: error)
        }
        // This Mac's own server answered, so this Mac is online even before the machine list has loaded.
        if let thisMachine, !machines.contains(where: { $0.id == thisMachine.id }) {
            sources.insert(source(id: thisMachine.id, name: thisMachine.name, kind: .local, detail: "This Mac", online: true,
                                  databases: databases, error: error), at: 0)
        }
        var unknown: [String] = []
        for database in databases where !machines.contains(where: { $0.id == database.machineID })
            && database.machineID != thisMachine?.id && !unknown.contains(database.machineID) {
            unknown.append(database.machineID)
        }
        sources += unknown.map {
            source(id: $0, name: $0, kind: .remote, detail: "", online: false, databases: databases, error: error)
        }
        return DatabasesSnapshot(sources: sources)
    }

    private static func source(id: String, name: String, kind: DatabaseSourceKind, detail: String, online: Bool,
                               databases: [Database], error: String?) -> DatabaseSource {
        let owned = databases.filter { $0.machineID == id }
            .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
            .map { database in
                AgentDatabase(machineID: id, databaseID: database.id, name: database.name, updatedAt: database.copiedAt,
                              offline: !online, hasCopy: database.copyDigest != nil)
            }
        return DatabaseSource(id: id, name: name, kind: kind, detail: detail, databases: owned,
                              error: error ?? (online ? nil : "\(name) is offline."),
                              allowsCreation: error == nil && online)
    }

    /// Creates a database owned by `machineID`. Returns its identifier.
    func create(machineID: String, name: String) async -> String? {
        await make(CreateDatabase(name: name.trimmingCharacters(in: .whitespacesAndNewlines), machineID: machineID))
    }

    /// Creates an independent copy of `database` on `machineID`. Returns the copy's identifier.
    func copy(_ database: AgentDatabase, to machineID: String, name: String) async -> String? {
        await make(CreateDatabase(name: name.trimmingCharacters(in: .whitespacesAndNewlines), machineID: machineID,
                                  copyOf: database.databaseID))
    }

    private func make(_ request: CreateDatabase) async -> String? {
        error = nil
        do {
            guard let server, server.isConnected else { throw ClientError.notConnected }
            let database = try await server.call(request)
            await refresh()
            return AgentDatabase(machineID: database.machineID, databaseID: database.id, name: database.name).id
        } catch {
            self.error = Self.message(error)
            return nil
        }
    }

    /// The rows a database link reads: its query, or with none the whole table
    /// its path names.
    func rows(for link: DatabaseArtifactLink) async throws -> DatabaseTabularData {
        do {
            guard let server, server.isConnected else { throw ClientError.notConnected }
            var sql = link.sqliteQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if sql.isEmpty {
                let table = link.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                let description = try await server.call(DescribeDatabase(databaseID: link.databaseID))
                guard description.tables.contains(where: { $0.name == table }) else {
                    throw DatabaseFailure(message: "This link has no query.")
                }
                sql = "SELECT * FROM \"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            let result = try await server.call(QueryDatabase(databaseID: link.databaseID, sql: sql))
            return DatabaseTabularData(columns: result.columns, rows: result.rows, json: result.json)
        } catch let failure as DatabaseFailure {
            throw failure
        } catch {
            throw DatabaseFailure(message: Self.message(error))
        }
    }

    func clearError() {
        error = nil
    }

    /// The server's own message for a refused request.
    static func message(_ error: Error) -> String {
        (error as? ProtocolError)?.message ?? error.localizedDescription
    }
}
