import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// The same Mac-owned routing, concurrency and note-binding path used by desktop UI.
/// Request tasks only await this service; they never own or cancel provider tasks.
@MainActor
final class CompanionCommandService: CompanionCommandServing {
    enum CommandError: LocalizedError {
        case unavailable, invalidCommand, unknownProvider, unknownConversation
        case noteRevisionChanged, activeNoteBindingUnsupported, interactionResolved
        case creationFailed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "The Mac workspace is not ready."
            case .invalidCommand: "This command is missing a valid ID, target, or response."
            case .unknownProvider: "This agent route is unavailable. Configure it on the Mac."
            case .unknownConversation: "This conversation no longer exists. Refresh the workspace."
            case .noteRevisionChanged: "The note changed on the Mac. Sync and review it before starting this run."
            case .activeNoteBindingUnsupported: "Wait for this run to finish before binding a note on this route."
            case .interactionResolved: "This request was already answered, ended, or the response is invalid."
            case .creationFailed(let message): message
            }
        }
    }
    private struct HistoryCursor: Codable { let createdAt: String; let messageID: String }
    private unowned let model: ApplicationModel
    private var commandDispatcher: CompanionCommandDispatcher?

    init(model: ApplicationModel) { self.model = model }

    func send(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        note: WorkspaceNoteRecord? = nil,
        expectedRunID: String? = nil,
        requiresIdle: Bool = false,
        expectedNoteRevision: String? = nil
    ) async throws -> LocalACPRunIdentifiers {
        try await model.acceptCanonicalAgentMessage(
            conversation: conversation, input: input, note: note,
            expectedRunID: expectedRunID, requiresIdle: requiresIdle,
            expectedNoteRevision: expectedNoteRevision
        )
    }

    func stop(conversationID: String, runID: String) async throws {
        try await model.cancelCanonicalRun(conversationID: conversationID, runID: runID)
    }

    func providers() -> [CompanionProvider] {
        let catalog = (try? HarnessCatalog.loadBundled().harnesses) ?? []
        func provider(_ runtime: AgentRuntimeKind, id: String, name: String, route: String, available: Bool) -> CompanionProvider {
            let definition = catalog.first { $0.id == runtime }
            return CompanionProvider(
                id: id, runtimeKind: runtime.rawValue, displayName: name, routeName: route,
                available: available, canStart: available,
                canResume: definition?.capabilities.contains("resume") == true,
                canSteer: false, canStop: available,
                supportsApprovals: true, supportsQuestions: runtime == .cursor,
                activeInputMode: "notNegotiated",
                unavailableReason: available ? nil : "Enable and configure this agent on the Mac."
            )
        }
        var result = AgentRuntimeKind.allCases.map { runtime in
            provider(runtime, id: "local:\(runtime.rawValue)", name: runtime.displayName,
                     route: "This Mac", available: model.canStartCanonicalLocalSession(runtime))
        }
        for enrollment in model.buzzWorkspaceSnapshot.enrollments {
            guard let runtime = enrollment.runtimeKind else { continue }
            result.append(provider(runtime, id: "buzz:\(enrollment.id.uuidString.lowercased())",
                                   name: enrollment.displayNameSnapshot, route: "Linked workspace",
                                   available: model.launchableBuzzWorkspaceEnrollmentIDs.contains(enrollment.id)))
        }
        for workspace in model.remoteWorkspaces.workspaces {
            for runtime in AgentRuntimeKind.allCases {
                result.append(provider(runtime,
                    id: "remote:\(workspace.id.uuidString.lowercased()):\(runtime.rawValue)",
                    name: runtime.displayName, route: workspace.name,
                    available: model.remoteWorkspaces.isHarnessReady(runtime, in: workspace)))
            }
        }
        let agents = model.localCLIAgents + model.buzzWorkspaceAgents + model.remoteWorkspaceAgents
        for link in model.openClawGatewayLinks {
            let name = agents.first(where: { $0.id == link.agentID })?.displayName ?? "OpenClaw"
            result.append(CompanionProvider(
                id: "gateway:\(link.agentID.uuidString.lowercased())", runtimeKind: AgentRuntimeKind.openclaw.rawValue,
                displayName: name, routeName: "OpenClaw Gateway", available: link.connectionStatus == .ready,
                canStart: link.connectionStatus == .ready, canResume: true, canSteer: false,
                canStop: true, supportsApprovals: true, supportsQuestions: false,
                activeInputMode: "gatewaySend",
                unavailableReason: link.connectionStatus == .ready ? nil : "Reconnect this Gateway on the Mac."
            ))
        }
        return result
    }

    /// Reads already negotiated state; never starts a provider just to display controls.
    func sessionCapabilities(conversationID: String) async throws -> CompanionProvider {
        let conversation = try conversation(conversationID)
        guard let runtime = conversation.localRuntimeKind else { throw CommandError.unknownProvider }
        let routeID: String
        if model.isOpenClawGatewayConversation(conversationID),
           let session = try? model.dashboardStore?.database.openClawGatewaySession(conversationID: conversationID) {
            routeID = "gateway:\(session.agentID.uuidString.lowercased())"
        } else if let workspaceID = conversation.remoteWorkspaceID {
            routeID = "remote:\(workspaceID.uuidString.lowercased()):\(runtime.rawValue)"
        } else if let enrollment = model.buzzWorkspaceSnapshot.enrollments.first(where: {
            $0.id.uuidString.lowercased() == conversation.agentID?.lowercased()
        }) {
            routeID = "buzz:\(enrollment.id.uuidString.lowercased())"
        } else {
            routeID = "local:\(runtime.rawValue)"
        }
        guard var capability = providers().first(where: { $0.id == routeID }) else { throw CommandError.unknownProvider }
        let active = model.canonicalActiveRunID(conversationID: conversationID) != nil
        if model.isOpenClawGatewayConversation(conversationID) {
            capability.activeInputMode = "gatewaySend"
            capability.canSteer = active
        } else if let mode = await model.dashboardStore?.localACPActiveInputCapability(conversationID: conversationID) {
            capability.activeInputMode = mode == .grokInterjection ? "grokInterjectionWithConcurrentFallback" : mode.rawValue
            capability.canSteer = active && mode != .unsupported
        }
        capability.canStop = active
        return capability
    }

    func pendingInteractions() -> [CompanionPendingInteraction] {
        var result = model.pendingLocalACPPermissions.map { pending in
            CompanionPendingInteraction(
                id: pending.id.uuidString.lowercased(), conversationID: pending.conversationID,
                runID: pending.runID, kind: .approval, title: pending.title,
                options: pending.options.map { .init(id: $0.id, label: $0.name, detail: $0.kind) }
            )
        }
        result += model.pendingLocalACPInteractions.map { pending in
            switch pending.request {
            case .questions(let request):
                CompanionPendingInteraction(
                    id: pending.id.uuidString.lowercased(), conversationID: pending.conversationID,
                    runID: pending.runID, kind: .question, title: request.title ?? "Agent question",
                    questions: request.questions.map { question in
                        .init(id: question.id, prompt: question.prompt,
                              options: question.options.map { .init(id: $0.id, label: $0.label) },
                              allowsMultiple: question.allowsMultiple, allowsFreeText: true)
                    }
                )
            case .plan(let request):
                CompanionPendingInteraction(
                    id: pending.id.uuidString.lowercased(), conversationID: pending.conversationID,
                    runID: pending.runID, kind: .approval, title: request.name ?? "Review agent plan",
                    detail: request.markdown, options: [
                        .init(id: "accept", label: "Accept plan"),
                        .init(id: "decline", label: "Decline plan")
                    ]
                )
            }
        }
        return result
    }

    func execute(_ command: CompanionCommand, deviceID: String) async throws -> CompanionCommandReceipt {
        guard command.deviceID == deviceID, UUID(uuidString: command.commandID) != nil,
              (command.text?.utf8.count ?? 0) <= 256 * 1_024 else { throw CommandError.invalidCommand }
        guard let store = model.dashboardStore else { throw CommandError.unavailable }
        return try await dispatcher(for: store).execute(command) { [self] original in
            var receipt = original
            try await dispatch(command, receipt: &receipt)
            return receipt
        }
    }

    func receipt(commandID: String, deviceID: String) throws -> CompanionCommandReceipt? {
        guard let store = model.dashboardStore else { throw CommandError.unavailable }
        return try dispatcher(for: store).receipt(commandID: commandID, deviceID: deviceID)
    }

    private func dispatcher(for store: DashboardStore) -> CompanionCommandDispatcher {
        if let commandDispatcher, commandDispatcher.database === store.database { return commandDispatcher }
        let dispatcher = CompanionCommandDispatcher(database: store.database)
        commandDispatcher = dispatcher
        return dispatcher
    }

    private func dispatch(_ command: CompanionCommand, receipt: inout CompanionCommandReceipt) async throws {
        switch command.kind {
        case .createSession:
            guard command.text == nil, command.noteID == nil, command.noteRevision == nil else {
                throw CommandError.invalidCommand
            }
            guard let requestedID = command.conversationID, UUID(uuidString: requestedID) != nil,
                  let providerID = command.providerID ?? command.routeID,
                  let provider = providers().first(where: { $0.id == providerID }), provider.available,
                  let runtime = AgentRuntimeKind(rawValue: provider.runtimeKind)
            else { throw CommandError.unknownProvider }
            let id: String?
            if providerID.hasPrefix("gateway:"), let agentID = UUID(uuidString: String(providerID.dropFirst(8))) {
                id = try await model.createCanonicalGatewaySession(agentID: agentID, conversationID: requestedID, folderID: command.folderID)
            } else if providerID.hasPrefix("local:") {
                id = await model.createLocalACPSession(runtimeKind: runtime, requestedConversationID: requestedID, folderID: command.folderID)
            } else if providerID.hasPrefix("buzz:"),
                      let enrollmentID = UUID(uuidString: String(providerID.dropFirst(5))),
                      let enrollment = model.buzzWorkspaceSnapshot.enrollments.first(where: { $0.id == enrollmentID }) {
                id = await model.createBuzzWorkspaceLocalACPSession(enrollment: enrollment, requestedConversationID: requestedID, folderID: command.folderID)
            } else if let target = model.remoteWorkspaces.readyChatTargets.first(where: {
                "remote:\($0.configuration.id.uuidString.lowercased()):\($0.harness.id.rawValue)" == providerID
            }) {
                id = await model.createRemoteACPSession(target: target, requestedConversationID: requestedID, folderID: command.folderID)
            } else { throw CommandError.unknownProvider }
            guard let id else { throw CommandError.creationFailed(model.localRunError ?? "The Mac could not create this conversation.") }
            receipt.conversationID = id
        case .send, .steer:
            guard let id = command.conversationID, let text = command.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CommandError.invalidCommand }
            if command.kind == .steer && command.runID == nil { throw CommandError.invalidCommand }
            if command.kind == .send && command.runID != nil { throw CommandError.invalidCommand }
            let conversation = try conversation(id)
            let note: WorkspaceNoteRecord?
            let input: AgentMessageInput
            if let noteID = command.noteID {
                guard let revision = command.noteRevision, model.flushNoteDrafts(),
                      let raw = try model.dashboardStore?.database.companionNote(id: noteID),
                      raw.revision == revision,
                      let canonical = try model.dashboardStore?.database.workspaceOverview().notes.first(where: { $0.id == noteID })
                else { throw CommandError.noteRevisionChanged }
                let reference = AgentMessageReferenceDraft(
                    kind: .note, resourceID: noteID, titleSnapshot: raw.title,
                    contentSnapshot: raw.content, revisionSnapshot: String(raw.revision),
                    folderIDSnapshot: raw.folderID
                )
                input = AgentMessageInput(text: text, attachments: [.reference(reference)])
                // A future document can be referenced losslessly; only known editable
                // documents receive a mediated/CLI editing grant for the current run.
                let supportsEditing = (try? NoteDocument.editableDocument(from: raw.content)) != nil
                let isMediatedSteer = command.kind == .steer &&
                    (model.isOpenClawGatewayConversation(id) || conversation.remoteWorkspaceID != nil)
                note = supportsEditing && !isMediatedSteer ? canonical : nil
            } else {
                guard command.noteRevision == nil else { throw CommandError.invalidCommand }
                note = nil
                input = AgentMessageInput(text: text)
            }
            let ids = try await send(
                conversation: conversation, input: input, note: note,
                expectedRunID: command.kind == .steer ? command.runID : nil,
                requiresIdle: command.kind == .send,
                expectedNoteRevision: command.noteRevision.map(String.init)
            )
            receipt.conversationID = id; receipt.runID = ids.runID
        case .stop:
            guard let id = command.conversationID, let runID = command.runID else { throw CommandError.invalidCommand }
            try await stop(conversationID: id, runID: runID)
            receipt.conversationID = id; receipt.runID = runID
        case .respond:
            try respond(command)
            receipt.conversationID = command.conversationID; receipt.runID = command.runID
        }
    }

    private func respond(_ command: CompanionCommand) throws {
        guard let rawID = command.interactionID, let id = UUID(uuidString: rawID),
              let response = command.response else { throw CommandError.invalidCommand }
        if let pending = model.pendingLocalACPPermissions.first(where: { $0.id == id }) {
            guard pending.conversationID == command.conversationID, pending.runID == command.runID,
                  response.answers.isEmpty,
                  response.cancelled ? response.optionID == nil : response.optionID != nil,
                  model.resolveLocalACPPermission(id: id, optionID: response.cancelled ? nil : response.optionID)
            else { throw CommandError.interactionResolved }
            return
        }
        guard let pending = model.pendingLocalACPInteractions.first(where: { $0.id == id }),
              pending.conversationID == command.conversationID, pending.runID == command.runID
        else { throw CommandError.interactionResolved }
        let resolution: LocalACPInteractionResponse
        if response.cancelled {
            guard response.optionID == nil && response.answers.isEmpty else { throw CommandError.invalidCommand }
            resolution = .cancelled
        } else {
            switch pending.request {
            case .plan:
                guard response.answers.isEmpty, let optionID = response.optionID,
                      ["accept", "decline"].contains(optionID) else { throw CommandError.invalidCommand }
                resolution = .planAccepted(response.optionID == "accept")
            case .questions(let request):
                guard response.optionID == nil, Set(response.answers.keys) == Set(request.questions.map(\.id)) else { throw CommandError.invalidCommand }
                var answers: [String: LocalACPQuestionAnswer] = [:]
                for question in request.questions {
                    let values = response.answers[question.id] ?? []
                    guard !values.isEmpty, question.allowsMultiple || values.count == 1 else { throw CommandError.invalidCommand }
                    // Wire selections are option IDs; providers receive the same labels as desktop.
                    let labels = values.map { value in question.options.first(where: { $0.id == value })?.label ?? value }
                    answers[question.id] = labels.count == 1 ? .single(labels[0]) : .multiple(labels)
                }
                resolution = .answers(answers)
            }
        }
        guard model.resolveLocalACPInteraction(id: id, response: resolution) else { throw CommandError.interactionResolved }
    }

    private func conversation(_ id: String) throws -> WorkspaceConversationRecord {
        guard let store = model.dashboardStore,
              let record = try store.database.workspaceOverview().conversations.first(where: { $0.id == id })
        else { throw CommandError.unknownConversation }
        return record
    }

    func transcript(conversationID: String, before: String? = nil) async throws -> CompanionTranscript {
        _ = try conversation(conversationID)
        guard let store = model.dashboardStore else { throw CommandError.unavailable }
        let cursor: WorkspaceConversationHistoryCursor?
        if let before {
            guard before.utf8.count <= 2_048, let data = Data(base64Encoded: before),
                  let decoded = try? JSONDecoder().decode(HistoryCursor.self, from: data)
            else { throw CommandError.invalidCommand }
            cursor = .init(createdAt: decoded.createdAt, messageID: decoded.messageID)
        } else { cursor = nil }
        let page = try await store.conversationHistoryPage(id: conversationID, before: cursor, limit: 80)
        let olderCursor = try page.hasOlderMessages ? page.oldestMessageCursor.map {
            try JSONEncoder().encode(HistoryCursor(createdAt: $0.createdAt, messageID: $0.messageID)).base64EncodedString()
        } : nil
        return CompanionTranscript(
            conversationID: conversationID,
            messages: page.messages.map { .init(id: $0.id, conversationID: $0.conversationID, runID: $0.runID,
                role: $0.role, content: $0.content, status: $0.status, createdAt: $0.createdAt) },
            activities: page.activities.map { .init(id: $0.id, runID: $0.runID,
                title: $0.activity.title ?? $0.activity.kind.rawValue,
                detail: $0.activity.detail ?? $0.activity.content, status: $0.activity.status ?? "") },
            activeRunID: model.canonicalActiveRunID(conversationID: conversationID), olderCursor: olderCursor
        )
    }
}
