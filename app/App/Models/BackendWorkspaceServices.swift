import Foundation
import WovenMatterClient
import WovenMatterCore

enum BackendWorkspaceServiceCommand: Codable, Sendable {
    case authorizeSavedConnections
    case openCodeSettingsAgent(UUID?), renameOpenCode(UUID, String)
    case consumePrefill(String, String)
    case buzzEnabled(Bool), refreshBuzz, addBuzz(name: String, workspacePath: String, agentStorePath: String)
    case createBuzzSession(UUID, folderID: String?)
    case discoverBuzz(UUID), enrollBuzz(workspaceID: UUID, candidateID: String), removeBuzzEnrollment(UUID), deleteBuzz(UUID)
    case refreshDatabases, createDatabase(sourceID: String, name: String, preference: AgentDatabasePreference)
    case databaseData(DatabaseArtifactLink)
    case copyDatabase(database: DashboardAgentDatabase, destinationSourceID: String, name: String)
}

struct BackendGatewaySettingsSnapshot: Codable, Sendable {
    var buzzEnabled: Bool
    var buzzLinks: [BuzzWorkspaceLink]
    var buzzEnrollments: [BuzzWorkspaceAgentEnrollment]
    var buzzCandidates: [UUID: [BuzzWorkspaceAgentCandidate]]
    var buzzLaunchable: Set<UUID>
    var buzzChecking: Set<UUID>
    var buzzMutating: Set<UUID>
    var buzzBoundConversations: Set<String>
    var buzzAgents: [WorkspaceAgent]
    var buzzError: String?
    var metadata: [String: LocalACPSessionMetadata]
}

struct BackendDatabasesSnapshot: Codable, Sendable {
    var catalog: DashboardDatabasesSnapshot
    var refreshing: Bool
    var error: String?
}

struct BackendWorkspaceServiceResponse: Codable, Sendable {
    var gateway: BackendGatewaySettingsSnapshot?
    var databases: BackendDatabasesSnapshot?
    var agent: WorkspaceAgent?
    var success: Bool?
    var entityID: String?
    var data: DatabaseTabularData?
}
