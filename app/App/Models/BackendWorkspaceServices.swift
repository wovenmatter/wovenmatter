import Foundation
import WovenMatterClient
import WovenMatterCore

enum BackendWorkspaceServiceCommand: Codable, Sendable {
    case openCodeSettingsAgent(UUID?), renameOpenCode(UUID, String), remoteOpenClawAgent(UUID)
    case consumePrefill(String, String)
    case buzzEnabled(Bool), refreshBuzz, addBuzz(name: String, workspacePath: String, agentStorePath: String)
    case createBuzzSession(UUID)
    case discoverBuzz(UUID), enrollBuzz(workspaceID: UUID, candidateID: String), removeBuzzEnrollment(UUID), deleteBuzz(UUID)
    case connectHermes(UUID, restart: Bool), unlinkHermes(UUID), renameHermes(UUID, String)
    case connectRemoteHermes(UUID), stopRemoteHermes(UUID)
    case hermesApprovals(agentID: UUID?, workspaceID: UUID?, mode: String?)
    case hermesSessions(UUID), importHermes(UUID, String)
    case renameOpenClaw(UUID, String), linkOpenClaw(UUID), unlinkOpenClaw(UUID)
    case reconnectOpenClaw(UUID), restartOpenClaw(UUID), refreshOpenClaw(UUID)
    case loadHeartbeat(UUID), saveHeartbeat(UUID, OpenClawHeartbeatConfiguration)
    case patchOpenClawSession(String, model: String?, thinking: String?, permission: String?)
    case refreshOpenClawSession(String), openClawSessions(UUID, offset: Int)
    case importOpenClaw(UUID, OpenClawGatewaySession)
    case refreshDatabases, createDatabase(sourceID: String, name: String, preference: AgentDatabasePreference)
    case registerDatabase(URL), databasePreference(id: String, preference: AgentDatabasePreference)
    case databaseData(DatabaseArtifactLink)
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
    var linkedHermesIDs: Set<UUID>
    var connectedHermesIDs: Set<UUID>
    var remoteHermesIDs: Set<UUID>
    var hermesCheckedAt: [UUID: Date]
    var links: [OpenClawGatewayLink]
    var conversationIDs: Set<String>
    var errors: [UUID: String]
    var notices: [UUID: String]
    var operations: Set<UUID>
    var statuses: [UUID: OpenClawGatewayConnectionStatus]
    var heartbeats: [UUID: OpenClawHeartbeatConfiguration]
    var heartbeatMessages: [UUID: String]
    var heartbeatErrors: Set<UUID>
    var heartbeatSaving: Set<UUID>
    var metadata: [String: LocalACPSessionMetadata]
}

struct BackendDatabasesSnapshot: Codable, Sendable {
    var catalog: DashboardDatabasesSnapshot
    var refreshing: Bool
    var updating: Set<String>
    var error: String?
}

struct BackendWorkspaceServiceResponse: Codable, Sendable {
    var gateway: BackendGatewaySettingsSnapshot?
    var databases: BackendDatabasesSnapshot?
    var agent: WorkspaceAgent?
    var success: Bool?
    var entityID: String?
    var approvalMode: String?
    var hermesSessions: [HermesValue]?
    var openClawSessions: [OpenClawGatewaySession]?
    var nextOffset: Int?
    var data: DatabaseTabularData?
}
