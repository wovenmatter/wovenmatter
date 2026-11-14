import Foundation
import WovenMatterCore

enum DatabaseSourceKind: String, CaseIterable, Codable, Sendable {
    case local
    case remote

    var displayName: String {
        switch self {
        case .local: "Local workspace"
        case .remote: "Remote workspaces"
        }
    }
}

struct AgentDatabase: Equatable, Identifiable, Codable, Sendable {
    let sourceID: String
    let databaseID: String
    let name: String
    let localURL: URL?
    var revision: Int64 = 0
    var updatedAt: String? = nil
    var offline: Bool = false

    var id: String { "\(sourceID):\(databaseID)" }
}

struct DatabaseSource: Equatable, Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let kind: DatabaseSourceKind
    let detail: String
    let databases: [AgentDatabase]
    let error: String?
    let allowsCreation: Bool
}

struct DatabasesSnapshot: Equatable, Codable, Sendable {
    static let empty = DatabasesSnapshot(sources: [])

    let sources: [DatabaseSource]

    var databases: [AgentDatabase] {
        sources.flatMap(\.databases)
    }

    func database(sourceID: String, databaseID: String) -> AgentDatabase? {
        sources.first { $0.id == sourceID }?.databases.first {
            $0.databaseID == databaseID
        }
    }
}

enum DatabaseLinkError: LocalizedError {
    case databaseUnavailable
    case remoteDataUnavailable
    case sqliteQueryRequired

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            "The linked database is no longer available."
        case .sqliteQueryRequired:
            "Add a read-only SQLite query to this artifact link."
        case .remoteDataUnavailable:
            "This remote database is not reachable from this Mac."
        }
    }
}
