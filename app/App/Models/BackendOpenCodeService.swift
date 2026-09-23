import Foundation
import WovenMatterClient
import WovenMatterCore

enum BackendOpenCodeCommand: Codable, Sendable {
    case browserURL
    case restore, resolve, download, stop, restart, suspend, disable
    case connect(Bool)
    case serverPreferences(Bool, Bool)
    case create(URL, UUID?, String?, String?)
    case importable(String?), importSession(OpenCodeValue)
    case sessionCall(String, String, String, OpenCodeValue?)
    case settingsModels(String), calendarMetadata(String, String?), catalog(String)
    case selections(String, SessionSelections), updateSelection(String, String?, String?, String?)
    case send(String, AgentMessageInput, String?)
    case visible(String, Bool)
    case watch(String), older(String), refresh(String), file(String, String)
    case acknowledge(String, OpenCodeValue)
}
struct BackendOpenCodeRequest: Codable, Sendable {
    var workspaceID: UUID?
    var command: BackendOpenCodeCommand
}
struct BackendOpenCodeResponse: Codable, Sendable {
    var snapshot: OpenCodeModel.BackendSnapshot
    var createdID: String?
    var sessions: [OpenCodeValue]?
    var next: String?
    var value: OpenCodeValue?
    var metadata: LocalACPSessionMetadata?
    var data: Data?
    var url: URL?
}
@MainActor
struct BackendOpenCodeService {
    let model: OpenCodeModel
    func execute(_ command: BackendOpenCodeCommand) async throws -> BackendOpenCodeResponse {
        guard !model.isBackendProjection else { throw OpenCodeError.message("This process does not own OpenCode connections.") }
        var result = BackendOpenCodeResponse(snapshot: model.backendSnapshot())
        switch command {
        case .browserURL: result.url = try await model.browserURL()
        case .restore: await model.restore()
        case .resolve: await model.resolveExecutable()
        case .download: try await model.download()
        case .stop: try await model.stopServer()
        case .restart: try await model.restartServer()
        case .suspend: await model.suspendConnection()
        case .disable: await model.disable()
        case .connect(let start): try await model.connectLocal(allowStart: start)
        case .serverPreferences(let start, let stop): model.startServerOnLaunch = start; model.stopServerOnQuit = stop
        case .create(let workspace, let id, let title, let native):
            result.createdID = try await model.create(workspace: workspace, requestedConversationID: id, title: title, nativeWorkspaceID: native)
        case .importable(let cursor):
            let page = try await model.importableSessions(cursor: cursor)
            result.sessions = page.sessions; result.next = page.next
        case .importSession(let session): try await model.importSession(session)
        case .sessionCall(let id, let suffix, let method, let body): result.value = try await model.sessionCall(id, suffix, method: method, body: body)
        case .settingsModels(let workspace): try await model.refreshSettingsModels(workspace: workspace)
        case .calendarMetadata(let directory, let modelID): result.metadata = try await model.calendarTaskMetadata(directory: directory, model: modelID)
        case .catalog(let id): try await model.refreshCatalog(id)
        case .selections(let id, let selections): try await model.applySessionSelections(id, selections: selections)
        case .updateSelection(let id, let selected, let thinking, let permission):
            if let task = model.updateSelection(id, model: selected, thinking: thinking, permission: permission) { try await task.value }
        case .send(let id, let input, let discovery): try await model.send(id, input: input, discovery: discovery)
        case .visible(let key, let visible): model.setModelVisible(key, visible: visible)
        case .watch(let id): if let link = model.links[id] { await model.watch(link) }
        case .older(let id): if let link = model.links[id] { try await model.loadOlder(link) }
        case .refresh(let id): try await model.refreshSession(id)
        case .file(let id, let path): result.data = try await model.readFile(id, path: path)
        case .acknowledge(let id, let submission): try await model.acknowledgeSubmission(id, submission: submission)
        }
        let catalogID: String?
        switch command {
        case .catalog(let id), .selections(let id, _), .updateSelection(let id, _, _, _): catalogID = id
        case .create: catalogID = result.createdID
        default: catalogID = nil
        }
        let includeSettings: Bool
        if case .settingsModels = command { includeSettings = true } else { includeSettings = false }
        result.snapshot = model.backendSnapshot(catalogSessionID: catalogID, includeSettingsCatalog: includeSettings)
        return result
    }
}

struct BackendOpenCodeWorkspaceSnapshot: Codable, Sendable {
    var ownerDeviceID: UUID
    var configuration: RemoteWorkspaceConfiguration?
    var state: OpenCodeModel.BackendSnapshot
}
