import Foundation
import Observation

/// Databases on every machine and their tables.
@MainActor
@Observable
final class DatabasesStore {
    /// Every machine that holds databases, this Mac first.
    private(set) var snapshot = DatabasesSnapshot.empty
    private(set) var isRefreshing = false
    /// The last database command that failed, until cleared.
    private(set) var error: String?

    init() {}

    /// Asks every machine for its current databases.
    func refresh() async {}

    /// Creates a database owned by `machineID`. Returns its identifier.
    func create(machineID: String, name: String) async -> String? {
        error = ClientError.notConnected.localizedDescription
        return nil
    }

    /// Creates an independent copy of `database` on `machineID`. Returns the copy's identifier.
    func copy(_ database: AgentDatabase, to machineID: String, name: String) async -> String? {
        error = ClientError.notConnected.localizedDescription
        return nil
    }

    func clearError() {
        error = nil
    }
}
