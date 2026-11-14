import Foundation
import WovenMatterClient
import WovenMatterCore

enum BackendWorkspaceServiceCommand: Codable, Sendable {
    case authorizeSavedConnections
    case openCodeSettingsAgent(UUID?), renameOpenCode(UUID, String)
    case consumePrefill(String, String)
    case refreshDatabases, createDatabase(sourceID: String, name: String)
    case databaseData(DatabaseArtifactLink)
    case copyDatabase(database: AgentDatabase, destinationSourceID: String, name: String)
}

struct BackendDatabasesSnapshot: Codable, Sendable {
    var catalog: DatabasesSnapshot
    var refreshing: Bool
    var error: String?
}

struct BackendWorkspaceServiceResponse: Codable, Sendable {
    var databases: BackendDatabasesSnapshot?
    var agent: WorkspaceAgent?
    var success: Bool?
    var entityID: String?
    var data: DatabaseTabularData?
}
