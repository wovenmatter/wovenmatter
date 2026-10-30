import Foundation
import WovenMatterCompanion
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// Commands contain identities, never client-owned database or runtime objects.
/// The service resolves each identity against its authoritative state at admission.
struct BackendAttachmentSource: Codable, Sendable {
    let url: URL
    let mimeType: String
}

struct BuiltInSubagentArchiveRequest: Codable, Sendable {
    let conversationID: String
    let sourceID: String
    let nativeSessionID: String
    let nativeConversationID: String
    var after: Int64 = 0
    var eventID: String?
    var offset: Int = 0
}

enum BackendApplicationCommand: Codable, Sendable {
    case saveDictation(DictationRecord)
    case companion(CompanionHostAction)
    case federatedExecution(FederatedExecutionAction)
    case setIdleSleepPolicy(WorkPowerPolicy)
    case setClosedLidPolicy(WorkPowerPolicy)
    case stageAttachments(files: [BackendAttachmentSource])
    case toolsMutation(BackendToolsMutation)
    case mcpAccess(WovenMCPAccessAction)
    case loadAgentDefaults(runtime: AgentRuntimeKind, workspace: String?)
    case saveAgentDefault(runtime: AgentRuntimeKind, workspace: String?, field: SessionSelectionField, selections: SessionSelections)
    case setAgentDefaultsSharing(runtime: AgentRuntimeKind, workspace: String, shared: Bool)
    case recordSelections(conversationID: String, metadata: LocalACPSessionMetadata)
    case workspaceMutation(BackendWorkspaceMutation)
    case exportConversation(id: String, format: WorkspaceConversationExportFormat)
    case trashedConversations
    case trashedNotes
    case exportNote(id: String, format: WorkspaceNoteExportFormat, expectedRevision: String)
    case sessionMetadata(conversationID: String)
    case createSession(runtime: AgentRuntimeKind, workspaceID: UUID?, conversationID: UUID,
                       workingDirectory: URL?, title: String?, nativeWorkspaceID: String?, folderID: String?)
    case sendMessage(conversationID: String, input: AgentMessageInput, noteID: String?)
    case sendMessageFenced(conversationID: String, input: AgentMessageInput, noteID: String?, admission: AgentDispatchAdmission)
    case cancelSessionFenced(conversationID: String, admission: AgentDispatchAdmission)
    case goalMutationFenced(conversationID: String, mutation: WorkspaceGoalMutation, admission: AgentDispatchAdmission)
    case configureSession(conversationID: String, model: String?, thinking: String?, permission: String?)
    case subagentHistory(BuiltInSubagentArchiveRequest)
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
    var companion: CompanionHostSnapshot?
    var federatedExecution: FederatedExecutionSnapshot?
    var exportURL: URL?
    var trashedConversations: [WorkspaceTrashedConversation]?
    var trashedNotes: [WorkspaceTrashedNote]?
    var noteExport: WorkspaceNoteExport?
    var surfaceProfile: SurfaceProfile?
    var accepted: Bool = true
    var entityID: String?
    var noteResponse: NoteEditingResponse?
    var conversationID: String?
    var metadata: LocalACPSessionMetadata?
    var selections: SessionSelections?
    var resolvedSelections: SessionSelections?
    var usesSharedDefaults: Bool?
    var attachments: [AgentMessageAttachmentDraft]?
    var requiresTimerPauseConfirmation: Bool = false
    var history: GatewayJSONValue?
    var mcpAccess: WovenMCPAccessSnapshot?
}

struct BackendApplicationReadiness: Codable, Sendable {
    let protocolVersion: Int
    let instanceID: UUID
    let ready: Bool
    /// Core command support is not proof that every frontend mutation is routed.
    let completeClientRouting: Bool
    let capabilities: [String]
    var startupError: String? = nil
    var executionDirectory: URL? = nil
    var startupMessage: String? = nil
}

/// Dispatches frontend commands to the backend-owned application model.
@MainActor
final class BackendApplicationService {
    let instanceID = UUID()
    let invalidations: BackendInvalidationJournal
    let model: ApplicationModel
    private struct PendingCommand {
        let identity: BackendRPCCommandIdentity
        let task: Task<BackendRPCResponse, Never>
    }
    private var pending: [String: PendingCommand] = [:]
    private var completed: [String: (BackendRPCCommandIdentity, BackendRPCResponse)] = [:]
    private var completionOrder: [String] = []
    private var dispatchAdmissions: AgentDispatchAdmissionLedger
    var dispatchStopRevisions: [String: UInt64] { dispatchAdmissions.stopRevisions }

    init(model: ApplicationModel) {
        self.invalidations = BackendInvalidationJournal(instanceID: instanceID)
        self.dispatchAdmissions = AgentDispatchAdmissionLedger(instanceID: instanceID)
        self.model = model
    }

    func handle(_ request: BackendRPCRequest) async -> BackendRPCResponse {
        // Browser frames and input are ephemeral. Do not retain images or typed
        // text in RPC replay storage; the workspace deduplicates input IDs.
        if request.method == "remoteWorkspaces.command",
           let command = try? JSONDecoder().decode(BackendRemoteWorkspaceCommand.self, from: request.payload),
           command.isBrowserOperation { return await perform(request) }
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

    func recordCompanionStop(conversationID: String) {
        do { try dispatchAdmissions.prepareLegacyStop(conversationID: conversationID) }
        catch { dispatchAdmissions.refuseFurtherSends(conversationID: conversationID) }
    }

    private func perform(_ request: BackendRPCRequest) async -> BackendRPCResponse {
        do {
            switch request.method {
            case "application.readiness":
                let startupError: String?
                if case .failed(let message) = model.state { startupError = message }
                else { startupError = nil }
                return try response(request, BackendApplicationReadiness(protocolVersion: 1,
                    instanceID: instanceID, ready: model.readyForBackendClients,
                    completeClientRouting: true,
                    capabilities: ["session.create", "session.send", "session.configure", "session.tools",
                                   "session.cancel", "session.permission", "session.interaction", "calendar.write",
                                   "calendar.metadata", "session.dispatch-epochs"], startupError: startupError,
                    executionDirectory: model.clientExecutionDirectory, startupMessage: model.backendStartupMessage))
            case "application.changes":
                let cursor = try JSONDecoder().decode(BackendInvalidationCursor?.self, from: request.payload)
                return try await response(request, invalidations.waitForChanges(after: cursor))
            case "remoteWorkspaces.command":
                guard model.readyForBackendClients else { throw BackendRPCError.remote("The background service is still starting.") }
                let command = try JSONDecoder().decode(BackendRemoteWorkspaceCommand.self, from: request.payload)
                let result = try await BackendRemoteWorkspaceService(model: model.remoteWorkspaces).execute(command)
                return try response(request, result)
            case "application.command":
                guard model.readyForBackendClients else { throw BackendRPCError.remote("The background service is still starting.") }
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

    private func conversation(_ id: String) async throws -> WorkspaceConversationRecord {
        guard let record = try await model.dashboardStore?.database.workspaceOverview().conversations.first(where: { $0.id == id }) else {
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
        if model.libraryTransferPaused {
            if case .companion(let action) = command {
                switch action {
                case .status, .retryLibraryTransfer, .cancelLibraryTransfer, .approveLibraryTransfer, .declineLibraryTransfer: break
                default: throw BackendRPCError.remote("Finish the database transfer before changing device membership or access.")
                }
            } else { throw BackendRPCError.remote("The database is transferring. Continue or cancel the transfer in Apple Devices settings.") }
        }
        switch command {
        case .federatedExecution(let action):
            return try await .init(federatedExecution: model.performFederatedExecution(action))
        case .companion(let action):
            let host = model.companionHost
            switch action {
            case .status: await host.refreshStatus()
            case .discover: await host.refreshDiscovery()
            case .approvePairing(let id): await host.approvePairing(id: id)
            case .denyPairing(let id): await host.denyPairing(id: id)
            case .invitePairing(let peer): await host.invitePairing(peer: peer)
            case .beginLibraryTransfer(let peer): await host.beginLibraryTransfer(peer)
            case .approveLibraryTransfer(let id): await host.approveLibraryTransfer(id)
            case .declineLibraryTransfer(let id): await host.declineLibraryTransfer(id)
            case .retryLibraryTransfer: await host.retryLibraryTransfer()
            case .cancelLibraryTransfer: await host.cancelLibraryTransfer()
            case .requestCentralLibraryRole: await host.requestCentralLibraryRole()
            case let .setExecutionAccess(deviceID, workspaceID, enabled):
                await host.setExecutionAccess(deviceID: deviceID, workspaceID: workspaceID, enabled: enabled)
            case .start: await host.start()
            case .stop: host.stopSharing()
            case .createCode: await host.createPairingCode()
            case .revoke(let id): await host.revoke(id)
            }
            return .init(companion: host.snapshot)
        case .setIdleSleepPolicy(let policy):
            model.activeWorkSleepPrevention.setPolicy(policy)
            return .init()
        case .setClosedLidPolicy(let policy):
            model.applyClosedLidPolicy(policy)
            return .init()
        case let .stageAttachments(files):
            return try await .init(attachments: model.stageMessageAttachments(files.map { (url: $0.url, mimeType: $0.mimeType) }))
        case let .toolsMutation(mutation):
            return try await executeToolsMutation(mutation)
        case let .mcpAccess(action):
            return try await executeMCPAccess(action)
        case let .loadAgentDefaults(runtime, workspace):
            let values = try await model.agentSelectionDefaults(runtime: runtime, workspace: workspace)
            return .init(selections: values.stored, resolvedSelections: values.resolved, usesSharedDefaults: values.usesShared)
        case let .saveAgentDefault(runtime, workspace, field, selections):
            let values = try await model.saveAgentSelectionDefault(runtime: runtime, workspace: workspace,
                field: field, selections: selections)
            return .init(selections: values.stored, resolvedSelections: values.resolved, usesSharedDefaults: values.usesShared)
        case let .setAgentDefaultsSharing(runtime, workspace, shared):
            let values = try await model.setAgentDefaultsSharing(runtime: runtime, workspace: workspace, shared: shared)
            return .init(selections: values.stored, resolvedSelections: values.resolved, usesSharedDefaults: values.usesShared)
        case let .recordSelections(id, metadata):
            await model.recordConfirmedSessionSelections(conversationID: id, metadata: metadata)
        case let .exportConversation(id, format):
            return try await .init(exportURL: model.exportConversation(id: id, format: format))
        case .trashedConversations:
            return try await .init(trashedConversations: model.trashedConversations())
        case .trashedNotes:
            guard let store = model.dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
            return try await .init(trashedNotes: store.trashedNotes())
        case let .exportNote(id, format, revision):
            guard let store = model.dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
            return try await .init(noteExport: store.exportNote(id: id, format: format, expectedRevision: revision))
        case let .sessionMetadata(id):
            await model.refreshLocalACPSession(conversation: try conversation(id))
            return .init(metadata: model.localACPSessionMetadata[id])
        case let .workspaceMutation(mutation):
            return try await executeWorkspaceMutation(mutation)
        case let .createSession(runtime, workspaceID, conversationID, directory, title, nativeWorkspaceID, folderID):
            let id: String?
            if let workspaceID {
                guard let configuration = model.remoteWorkspaces.configuration(id: workspaceID),
                      let harness = model.remoteWorkspaces.currentHarnesses(for: configuration).first(where: { $0.id == runtime }) else {
                    throw BackendRPCError.remote("This workspace or agent is unavailable.")
                }
                id = await model.createRemoteACPSession(target: .init(configuration: configuration, harness: harness),
                    requestedConversationID: conversationID, nativeWorkingDirectory: directory,
                    initialTitle: title, nativeWorkspaceID: nativeWorkspaceID, folderID: folderID)
            } else {
                id = await model.createLocalACPSession(runtimeKind: runtime, requestedConversationID: conversationID,
                    nativeWorkingDirectory: directory, initialTitle: title, nativeWorkspaceID: nativeWorkspaceID, folderID: folderID)
            }
            guard let id else { throw BackendRPCError.remote(model.localRunError ?? "The session could not be created.") }
            return .init(conversationID: id)
        case let .goalMutationFenced(id, mutation, admission):
            let stops: Bool
            switch mutation { case .pause, .clear, .edit: stops = true; default: stops = false }
            if stops {
                guard try dispatchAdmissions.prepareStop(admission, conversationID: id) else { return .init() }
            } else {
                if try dispatchAdmissions.prepareSend(admission, conversationID: id) { model.beginAgentStop(conversationID: id) }
                try await model.waitForAgentStop(conversationID: id)
                try dispatchAdmissions.validateSend(admission, conversationID: id)
            }
            _ = try await model.mutateConversationGoal(id: id, mutation: mutation)
            await invalidations.publish(scopes: [.settings, .runtime], conversationIDs: [id])
            return .init()
        case .sendMessage:
            // An unversioned request cannot prove that it predates or follows Stop.
            throw AgentDispatchAdmissionError.invalid
        case let .sendMessageFenced(id, input, noteID, admission):
            if try dispatchAdmissions.prepareSend(admission, conversationID: id) {
                model.beginAgentStop(conversationID: id)
                await invalidations.publish(scopes: [.runtime])
            }
            try await model.waitForAgentStop(conversationID: id)
            try dispatchAdmissions.validateSend(admission, conversationID: id)
            let dispatchFence = model.beginAgentDispatch(conversationID: id)
            defer { model.finishAgentDispatch(conversationID: id, fence: dispatchFence) }
            let foreign = model.liveLibraryClient?.conversations.first { $0.id == id && model.liveLibraryClient?.isForeignConversation(id) == true }
            let record: WorkspaceConversationRecord
            if let foreign { record = try DevelopmentLibraryProjection.conversation(foreign) }
            else { record = try await conversation(id) }
            try dispatchFence.check()
            try dispatchAdmissions.validateSend(admission, conversationID: id)
            let note = noteID.flatMap { id in model.workspaceOverview?.notes.first { $0.id == id } }
            guard noteID == nil || note != nil else { throw BackendRPCError.remote("The attached note is unavailable.") }
            if foreign != nil, let client = model.liveLibraryClient {
                guard input.files.isEmpty else { throw BackendRPCError.remote("Attach files through the owning workspace.") }
                var text = input.text
                for reference in input.references { text += "\n\n" + reference.titleSnapshot + "\n" + reference.contentSnapshot }
                if let note { text += "\n\n" + note.title + "\n" + note.content }
                try await client.desktopSend(id: id, text: text, beforeDispatch: { try dispatchFence.claimDispatch() })
                return .init(accepted: true)
            }
            return try await .init(accepted: model.dispatchAgentMessage(conversation: record, input: input, note: note, dispatchFence: dispatchFence))
        case let .configureSession(id, selectedModel, thinking, permission):
            await model.updateLocalACPSession(conversation: try conversation(id), model: selectedModel,
                thinking: thinking, permission: permission)
        case let .subagentHistory(request):
            _ = try await conversation(request.conversationID)
            return .init(history: try await model.builtInSubagentHistory(request))
        case let .setSessionTools(id, tools, confirmed):
            _ = try await conversation(id)
            guard let database = model.dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
            let previous = try await database.sessionTools(id)
            try await database.setSessionTools(tools, sessionID: id, confirmedPausingTimers: confirmed)
            if !previous.enabled.subtracting(tools.enabled).isDisjoint(with: [.browser, .computer]) { await model.cancelAutomation(callerID: id) }
            try await model.agentTools?.reload()
        case let .cancelSession(id):
            // Keep legacy Stop useful for an older client and scheduled work.
            // At capacity Stop still reaches native work; future unknown sends fail closed.
            do { try dispatchAdmissions.prepareLegacyStop(conversationID: id) }
            catch {
                dispatchAdmissions.refuseFurtherSends(conversationID: id)
                let barrier = model.beginAgentStop(conversationID: id)
                try await barrier.value
                throw error
            }
            let barrier = model.beginAgentStop(conversationID: id)
            await invalidations.publish(scopes: [.runtime])
            try await barrier.value
        case let .cancelSessionFenced(id, admission):
            let advances: Bool
            do { advances = try dispatchAdmissions.prepareStop(admission, conversationID: id) }
            catch AgentDispatchAdmissionError.capacity {
                dispatchAdmissions.refuseFurtherSends(conversationID: id)
                let barrier = model.beginAgentStop(conversationID: id)
                try await barrier.value
                throw AgentDispatchAdmissionError.capacity
            }
            if advances {
                let barrier = model.beginAgentStop(conversationID: id)
                await invalidations.publish(scopes: [.runtime])
                try await barrier.value
            }
        case let .resolveSessionAccess(id, allowed):
            await model.resolveSessionToolAccess(id: id, allowed: allowed)
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
        case let .saveDictation(record):
            guard let database = model.dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
            try await database.saveDictation(record)
        case let .saveCalendar(draft, eventID, revision, occurrence):
            let event: WorkspaceCalendarItemRecord?
            if let eventID { event = try calendarEvent(eventID, revision: revision) }
            else { event = nil }
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
