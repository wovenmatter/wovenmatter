import Foundation
import WovenMatterClient
import WovenMatterCore

/// Commands resolve existing workspace and harness identities on the execution owner.
enum BackendRemoteWorkspaceCommand: Codable {
    case enableCredentialAccess, disableCredentialAccess, refreshAll, discoverMachines
    case synchronizeDefaultAgent(UUID)
    case reconnect(UUID), refresh(UUID), refreshSignIn(UUID), refreshTaskGateway(UUID)
    case checkRuntimeUpdates(UUID, AgentRuntimeKind)
    case setRuntimePreferences(UUID, AgentRuntimeKind, enabled: Bool?, visible: Bool?)
    case workspaceInstance(UUID, AgentRuntimeKind, action: String?)
    case backgroundExecution(UUID, Bool)
    case checkHost(hostName: String, userName: String)
    case create(name: String, workspaceID: String, hostName: String, userName: String, port: Int, memoryLimit: String, swapLimit: String)
    case authorizeHostPreparation, cancelHostPreparation
    case lifecycle(UUID, String), updateContainer(UUID)
    case resources(UUID, memoryLimit: String, swapLimit: String)
    case delete(UUID, removePersistentData: Bool)
    case performHarness(UUID, AgentRuntimeKind, String), prepareHarness(UUID, AgentRuntimeKind, String)
    case confirmHarness(UUID?, AgentRuntimeKind?, String?), cancelHarness(UUID?, AgentRuntimeKind?, String?)
    case signIn(UUID, AgentRuntimeKind, String), authorizationCode(UUID, String), cancelSignIn(UUID)
    case databases(UUID), createDatabase(UUID, name: String, preference: AgentDatabasePreference)
    case databasePreference(UUID, String, AgentDatabasePreference), databaseData(UUID, DatabaseArtifactLink)
}

struct BackendRemoteWorkspaceResponse: Codable {
    var snapshot: RemoteWorkspacesModel.BackendSnapshot
    var databases: [RemoteAgentDatabase]?
    var database: RemoteAgentDatabase?
    var databaseData: RemoteDatabaseData?
}

@MainActor
struct BackendRemoteWorkspaceService {
    let model: RemoteWorkspacesModel

    func execute(_ command: BackendRemoteWorkspaceCommand) async throws -> BackendRemoteWorkspaceResponse {
        guard !model.isBackendProjection else { throw BackendRPCError.remote("This process does not own remote connections.") }
        var databases: [RemoteAgentDatabase]?
        var database: RemoteAgentDatabase?
        var data: RemoteDatabaseData?
        switch command {
        case .synchronizeDefaultAgent(let id): try await model.synchronizeDefaultAgent(workspace(id))
        case .enableCredentialAccess: model.enableCredentialAccess()
        case .disableCredentialAccess: model.disableCredentialAccess()
        case .refreshAll: model.refreshAll()
        case .discoverMachines: model.discoverMachines()
        case .reconnect(let id): model.reconnect(try workspace(id))
        case .refresh(let id): model.refresh(try workspace(id))
        case .refreshSignIn(let id): await model.refreshSignInStatus(try workspace(id))
        case .refreshTaskGateway(let id): await model.refreshTaskGateway(try workspace(id))
        case .checkRuntimeUpdates(let id, let kind): model.checkRuntimeUpdates(kind, configuration: try workspace(id))
        case .setRuntimePreferences(let id, let kind, let enabled, let visible):
            guard let runtime = model.runtimeMaintenance[id]?.first(where: { $0.id == kind }) else {
                throw BackendRPCError.remote("This runtime is no longer available.")
            }
            model.setRuntimePreferences(runtime, configuration: try workspace(id), enabled: enabled, visible: visible)
        case .workspaceInstance(let id, let kind, let action): model.refreshWorkspaceInstance(kind, configuration: try workspace(id), action: action)
        case .backgroundExecution(let id, let enabled): model.setBackgroundExecution(enabled, for: try workspace(id))
        case .checkHost(let host, let user): model.checkHost(hostName: host, userName: user)
        case .create(let name, let id, let host, let user, let port, let memory, let swap):
            model.create(name: name, workspaceID: id, hostName: host, userName: user, port: port, memoryLimit: memory, swapLimit: swap)
        case .authorizeHostPreparation: model.authorizeHostPreparation()
        case .cancelHostPreparation: model.cancelHostPreparation()
        case .lifecycle(let id, let value):
            guard let action = RemoteWorkspaceLifecycleAction(rawValue: value) else { throw BackendRPCError.remote("Unknown workspace action.") }
            model.lifecycle(action, configuration: try workspace(id))
        case .updateContainer(let id): model.updateContainer(try workspace(id))
        case .resources(let id, let memory, let swap): model.applyResources(try workspace(id), memoryLimit: memory, swapLimit: swap)
        case .delete(let id, let removeData): model.delete(try workspace(id), removePersistentData: removeData)
        case .performHarness(let id, let kind, let action):
            model.performHarnessAction(action, harness: try harness(kind, workspaceID: id), configuration: try workspace(id))
        case .prepareHarness(let id, let kind, let action):
            model.prepareHarnessAction(action, harness: try harness(kind, workspaceID: id), configuration: try workspace(id))
        case .confirmHarness(let id, let kind, let action): model.confirmPreparedHarnessAction(workspaceID: id, harnessID: kind, action: action)
        case .cancelHarness(let id, let kind, let action): model.cancelPreparedHarnessAction(workspaceID: id, harnessID: kind, action: action)
        case .signIn(let id, let kind, let methodID):
            let harness = try harness(kind, workspaceID: id)
            guard let method = harness.setupMethods.first(where: { $0.id == methodID }) else { throw BackendRPCError.remote("This sign-in method is no longer available.") }
            model.startHarnessSignIn(harness: harness, method: method, configuration: try workspace(id))
        case .authorizationCode(let id, let code): model.submitAuthorizationCode(code, configuration: try workspace(id))
        case .cancelSignIn(let id): model.cancelHarnessSignIn(configuration: try workspace(id))
        case .databases(let id): databases = try await model.databases(for: workspace(id))
        case .createDatabase(let id, let name, let preference): database = try await model.createDatabase(name: name, preference: preference, in: workspace(id))
        case .databasePreference(let id, let databaseID, let preference): try await model.setDatabasePreference(preference, databaseID: databaseID, in: workspace(id))
        case .databaseData(let id, let link): data = try await model.databaseData(for: link, in: workspace(id))
        }
        return .init(snapshot: model.backendSnapshot(), databases: databases, database: database, databaseData: data)
    }

    private func workspace(_ id: UUID) throws -> RemoteWorkspaceConfiguration {
        guard let value = model.configuration(id: id) else { throw BackendRPCError.remote("This workspace is no longer configured.") }
        return value
    }
    private func harness(_ kind: AgentRuntimeKind, workspaceID: UUID) throws -> RemoteHarnessStatus {
        guard let value = model.currentHarnesses(for: try workspace(workspaceID)).first(where: { $0.id == kind }) else {
            throw BackendRPCError.remote("This harness is no longer available.")
        }
        return value
    }
}
