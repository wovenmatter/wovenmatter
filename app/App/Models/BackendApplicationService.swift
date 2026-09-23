import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// Commands contain identities, never client-owned database or runtime objects.
/// The service resolves each identity against its authoritative state at admission.
struct BackendAttachmentSource: Codable, Sendable {
    let url: URL
    let mimeType: String
}

enum BackendApplicationCommand: Codable, Sendable {
    case stageAttachments(files: [BackendAttachmentSource])
    case toolsMutation(BackendToolsMutation)
    case prepareSelections(conversationID: String, defaults: SessionSelections?)
    case applySelections(conversationID: String)
    case recordSelections(conversationID: String, metadata: LocalACPSessionMetadata)
    case retrySelections(conversationID: String, selections: SessionSelections)
    case workspaceMutation(BackendWorkspaceMutation)
    case sessionMetadata(conversationID: String)
    case createSession(runtime: AgentRuntimeKind, workspaceID: UUID?, conversationID: UUID,
                       workingDirectory: URL?, title: String?, nativeWorkspaceID: String?)
    case sendMessage(conversationID: String, input: AgentMessageInput, noteID: String?)
    case configureSession(conversationID: String, model: String?, thinking: String?, permission: String?)
    case setSessionTools(conversationID: String, tools: WorkspaceSessionTools, confirmedPausingTimers: Bool)
    case cancelSession(conversationID: String)
    case resolveSessionAccess(id: String, allowed: Bool)
    case resolvePermission(id: UUID, optionID: String?)
    case resolveInteraction(id: UUID, response: LocalACPInteractionResponse)
    case saveCalendar(draft: WorkspaceCalendarDraft, eventID: String?, expectedRevision: Int?, occurrence: Int?)
    case deleteCalendar(eventID: String, expectedRevision: Int, occurrence: Int?)
    case calendarMetadata(task: WorkspaceCalendarTask)
}

struct BackendApplicationResult: Codable, Sendable {
    var surfaceProfile: SurfaceProfile?
    var accepted: Bool = true
    var entityID: String?
    var conversationID: String?
    var metadata: LocalACPSessionMetadata?
    var attachments: [AgentMessageAttachmentDraft]?
    var requiresTimerPauseConfirmation: Bool = false
}

struct BackendApplicationReadiness: Codable, Sendable {
    let protocolVersion: Int
    let instanceID: UUID
    let ready: Bool
    /// Core command support is not proof that every frontend mutation is routed.
    let completeClientRouting: Bool
    let capabilities: [String]
}

/// A separate backend owns this dispatcher and the full ApplicationModel. Installing
/// this service alone does not authorize the UI to skip its execution startup: the
/// lifecycle handshake must also verify completeClientRouting.
@MainActor
final class BackendApplicationService {
    let instanceID = UUID()
    let invalidations: BackendInvalidationJournal
    let model: ApplicationModel
    private let completeClientRouting: Bool
    private struct PendingCommand {
        let identity: BackendRPCCommandIdentity
        let task: Task<BackendRPCResponse, Never>
    }
    private var pending: [String: PendingCommand] = [:]
    private var completed: [String: (BackendRPCCommandIdentity, BackendRPCResponse)] = [:]
    private var completionOrder: [String] = []

    init(model: ApplicationModel, completeClientRouting: Bool = false) {
        self.invalidations = BackendInvalidationJournal(instanceID: instanceID)
        self.model = model
        self.completeClientRouting = completeClientRouting
    }

    func handle(_ request: BackendRPCRequest) async -> BackendRPCResponse {
        guard ["application.command", "remoteWorkspaces.command"].contains(request.method) else { return await perform(request) }
        let identity = BackendRPCCommandIdentity(request)
        if let saved = completed[request.id] {
            return saved.0 == identity ? saved.1 : BackendRPCResponse(id: request.id, error: "Request identity was reused for a different command.")
        }
        if let saved = pending[request.id] {
            guard saved.identity == identity else {
                return BackendRPCResponse(id: request.id, error: "Request identity was reused for a different command.")
            }
            return await saved.task.value
        }
        let task = Task { await self.perform(request) }
        pending[request.id] = .init(identity: identity, task: task)
        let result = await task.value
        pending[request.id] = nil
        completed[request.id] = (identity, result)
        completionOrder.append(request.id)
        if completionOrder.count > 128 { completed[completionOrder.removeFirst()] = nil }
        return result
    }

    private func perform(_ request: BackendRPCRequest) async -> BackendRPCResponse {
        do {
            switch request.method {
            case "application.readiness":
                return try response(request, BackendApplicationReadiness(protocolVersion: 1,
                    instanceID: instanceID, ready: model.state == .ready,
                    completeClientRouting: completeClientRouting,
                    capabilities: ["session.create", "session.send", "session.configure", "session.tools",
                                   "session.cancel", "session.permission", "session.interaction", "calendar.write",
                                   "calendar.metadata"]))
            case "application.changes":
                let cursor = try JSONDecoder().decode(BackendInvalidationCursor?.self, from: request.payload)
                return try await response(request, invalidations.waitForChanges(after: cursor))
            case "remoteWorkspaces.command":
                guard model.state == .ready else { throw BackendRPCError.remote("The background service is still starting.") }
                let command = try JSONDecoder().decode(BackendRemoteWorkspaceCommand.self, from: request.payload)
                let result = try await BackendRemoteWorkspaceService(model: model.remoteWorkspaces).execute(command)
                return try response(request, result)
            case "application.command":
                guard model.state == .ready else { throw BackendRPCError.remote("The background service is still starting.") }
                let command = try JSONDecoder().decode(BackendApplicationCommand.self, from: request.payload)
                let result = try await execute(command)
                return try response(request, result)
            default:
                throw BackendRPCError.remote("The background service does not support this request.")
            }
        } catch {
            return BackendRPCResponse(id: request.id, error: error.localizedDescription)
        }
    }

    private func response<T: Encodable>(_ request: BackendRPCRequest, _ result: T) throws -> BackendRPCResponse {
        BackendRPCResponse(id: request.id, result: try JSONEncoder().encode(result))
    }

    private func conversation(_ id: String) throws -> WorkspaceConversationRecord {
        guard let record = try model.dashboardStore?.database.workspaceOverview().conversations.first(where: { $0.id == id }) else {
            throw BackendRPCError.remote("This session is no longer available.")
        }
        return record
    }

    private func calendarEvent(_ id: String, revision: Int?) throws -> WorkspaceCalendarItemRecord {
        guard let record = model.calendarItems.first(where: { $0.id == id }) else {
            throw BackendRPCError.remote("This task or event is no longer available.")
        }
        guard let revision, record.calendar.revision == revision else {
            throw BackendRPCError.remote("This task or event changed. Refresh it before saving.")
        }
        return record
    }

    private func execute(_ command: BackendApplicationCommand) async throws -> BackendApplicationResult {
        switch command {
        case let .stageAttachments(files):
            return try await .init(attachments: model.stageMessageAttachments(files.map { (url: $0.url, mimeType: $0.mimeType) }))
        case let .toolsMutation(mutation):
            return try await executeToolsMutation(mutation)
        case let .prepareSelections(id, defaults):
            try await model.prepareNewSessionSelections(conversationID: id, capturedDefaults: defaults)
        case let .applySelections(id):
            try await model.applyPendingSessionSelections(conversationID: id)
        case let .recordSelections(id, metadata):
            model.recordConfirmedSessionSelections(conversationID: id, metadata: metadata)
        case let .retrySelections(id, selections):
            return .init(accepted: model.retryPendingSessionSelections(conversationID: id, selections: selections))
        case let .sessionMetadata(id):
            await model.refreshLocalACPSession(conversation: try conversation(id))
            return .init(metadata: model.localACPSessionMetadata[id] ?? model.openClawGatewaySessionMetadata[id])
        case let .workspaceMutation(mutation):
            return try await executeWorkspaceMutation(mutation)
        case let .createSession(runtime, workspaceID, conversationID, directory, title, nativeWorkspaceID):
            let id: String?
            if let workspaceID {
                guard let configuration = model.remoteWorkspaces.configuration(id: workspaceID),
                      let harness = model.remoteWorkspaces.currentHarnesses(for: configuration).first(where: { $0.id == runtime }) else {
                    throw BackendRPCError.remote("This workspace or agent is unavailable.")
                }
                id = await model.createRemoteACPSession(target: .init(configuration: configuration, harness: harness),
                    requestedConversationID: conversationID, nativeWorkingDirectory: directory,
                    initialTitle: title, nativeWorkspaceID: nativeWorkspaceID)
            } else {
                id = await model.createLocalACPSession(runtimeKind: runtime, requestedConversationID: conversationID,
                    nativeWorkingDirectory: directory, initialTitle: title, nativeWorkspaceID: nativeWorkspaceID)
            }
            guard let id else { throw BackendRPCError.remote(model.localRunError ?? "The session could not be created.") }
            return .init(conversationID: id)
        case let .sendMessage(id, input, noteID):
            let record = try conversation(id)
            let note = noteID.flatMap { id in model.workspaceOverview?.notes.first { $0.id == id } }
            guard noteID == nil || note != nil else { throw BackendRPCError.remote("The attached note is unavailable.") }
            return try await .init(accepted: model.dispatchAgentMessage(conversation: record, input: input, note: note))
        case let .configureSession(id, selectedModel, thinking, permission):
            model.updateLocalACPSession(conversation: try conversation(id), model: selectedModel,
                thinking: thinking, permission: permission)
        case let .setSessionTools(id, tools, confirmed):
            _ = try conversation(id)
            guard let database = model.dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
            try database.setSessionTools(tools, sessionID: id, confirmedPausingTimers: confirmed)
            try model.agentTools?.reload()
        case let .cancelSession(id):
            _ = try conversation(id)
            if model.isOpenClawGatewayConversation(id) { model.cancelOpenClawGatewayPrompt(conversationID: id) }
            else { model.cancelLocalACPPrompt(conversationID: id) }
        case let .resolveSessionAccess(id, allowed):
            model.resolveSessionToolAccess(id: id, allowed: allowed)
            await invalidations.publish(scopes: [.permissions, .settings])
            return .init()
        case let .resolvePermission(id, optionID):
            guard let pending = model.pendingLocalACPPermissions.first(where: { $0.id == id }),
                  optionID == nil || pending.options.contains(where: { $0.id == optionID }) else {
                throw BackendRPCError.remote("This permission request is no longer available.")
            }
            model.resolveLocalACPPermission(id: id, optionID: optionID)
        case let .resolveInteraction(id, value):
            guard model.pendingLocalACPInteractions.contains(where: { $0.id == id }) else {
                throw BackendRPCError.remote("This input request is no longer available.")
            }
            model.resolveLocalACPInteraction(id: id, response: value)
        case let .saveCalendar(draft, eventID, revision, occurrence):
            let event = try eventID.map { try calendarEvent($0, revision: revision) }
            guard await model.saveCalendarEvent(draft, event: event, detaching: occurrence) else {
                throw BackendRPCError.remote(model.calendarMutationError ?? "The task or event could not be saved.")
            }
        case let .deleteCalendar(id, revision, occurrence):
            let event = try calendarEvent(id, revision: revision)
            guard await model.deleteCalendarEvent(event, occurrence: occurrence) else {
                throw BackendRPCError.remote(model.calendarMutationError ?? "The task or event could not be deleted.")
            }
        case let .calendarMetadata(task):
            return try await .init(metadata: model.calendarTaskMetadata(task))
        }
        return .init()
    }
}
