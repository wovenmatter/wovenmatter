import Foundation
import WovenMatterCore

enum DashboardDatabaseSourceKind: String, CaseIterable, Sendable {
    case local
    case buzz

    var displayName: String {
        switch self {
        case .local: "Local workspace"
        case .buzz: "Buzz workspaces"
        }
    }
}

struct DashboardAgentDatabase: Equatable, Identifiable, Sendable {
    let sourceID: String
    let databaseID: String
    let name: String
    let preference: AgentDatabasePreference
    let localURL: URL?
    let isExternal: Bool

    var id: String { "\(sourceID):\(databaseID)" }
}

struct DashboardDatabaseSource: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: DashboardDatabaseSourceKind
    let detail: String
    let databases: [DashboardAgentDatabase]
    let error: String?
    let allowsCreation: Bool
    let allowsExternalLinks: Bool
}

struct DashboardDatabasesSnapshot: Equatable, Sendable {
    static let empty = DashboardDatabasesSnapshot(sources: [])

    let sources: [DashboardDatabaseSource]

    var databases: [DashboardAgentDatabase] {
        sources.flatMap(\.databases)
    }

    func database(sourceID: String, databaseID: String) -> DashboardAgentDatabase? {
        sources.first { $0.id == sourceID }?.databases.first {
            $0.databaseID == databaseID
        }
    }
}

enum DashboardDatabaseLinkError: LocalizedError {
    case databaseUnavailable
    case remoteDataUnavailable

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            "The linked database is no longer available."
        case .remoteDataUnavailable:
            "This remote database is not reachable from this Mac."
        }
    }
}
