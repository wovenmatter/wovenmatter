import Foundation
import WovenMatterClient
import WovenMatterCore

struct LocalACPSessionDriver: Sendable {
    let initializeSession: @Sendable (
        _ workingDirectory: URL,
        _ existingSessionID: String?,
        _ title: String?,
        _ systemPrompt: String?
    ) async throws -> LocalACPInitializedSession
    let prompt: @Sendable (
        _ input: AgentMessageInput,
        _ onEvent: LocalACPClient.EventHandler?,
        _ onPermission: LocalACPClient.PermissionHandler?,
        _ onInteraction: LocalACPClient.InteractionHandler?
    ) async throws -> LocalACPStopReason
    let configuration: @Sendable () async -> LocalACPSessionConfiguration
    let observeConfiguration: (@Sendable (@escaping @Sendable (LocalACPSessionConfiguration) async -> Void) async -> Void)?
    let setConfiguration: @Sendable (
        _ model: String?,
        _ thinking: String?
    ) async throws -> LocalACPSessionConfiguration
    let setPermission: (@Sendable (String) async throws -> LocalACPSessionConfiguration)?
    let activeInput: (@Sendable (
        _ input: AgentMessageInput
    ) async throws -> LocalACPActiveInputReceipt)?
    let cancel: @Sendable () async throws -> Void
    let setRunID: (@Sendable (String) async throws -> Void)?
    let setResumePermissionHandler: (@Sendable (@escaping LocalACPClient.PermissionHandler) async -> Void)?
    let shutdown: @Sendable () async -> Void
    let fencedPrompt: (@Sendable (AgentMessageInput, LocalACPClient.EventHandler?, LocalACPClient.PermissionHandler?, LocalACPClient.InteractionHandler?, AgentDispatchFence) async throws -> LocalACPStopReason)?
    let fencedActiveInput: (@Sendable (AgentMessageInput, AgentDispatchFence) async throws -> LocalACPActiveInputReceipt)?

    init(
        initializeSession: @escaping @Sendable (
            _ workingDirectory: URL,
            _ existingSessionID: String?,
            _ title: String?,
            _ systemPrompt: String?
        ) async throws -> LocalACPInitializedSession,
        prompt: @escaping @Sendable (
            _ input: AgentMessageInput,
            _ onEvent: LocalACPClient.EventHandler?,
            _ onPermission: LocalACPClient.PermissionHandler?,
            _ onInteraction: LocalACPClient.InteractionHandler?
        ) async throws -> LocalACPStopReason,
        configuration: @escaping @Sendable () async -> LocalACPSessionConfiguration,
        observeConfiguration: (@Sendable (@escaping @Sendable (LocalACPSessionConfiguration) async -> Void) async -> Void)? = nil,
        setConfiguration: @escaping @Sendable (
            _ model: String?,
            _ thinking: String?
        ) async throws -> LocalACPSessionConfiguration,
        setPermission: (@Sendable (String) async throws -> LocalACPSessionConfiguration)? = nil,
        activeInput: (@Sendable (
            _ input: AgentMessageInput
        ) async throws -> LocalACPActiveInputReceipt)? = nil,
        cancel: @escaping @Sendable () async throws -> Void,
        shutdown: @escaping @Sendable () async -> Void,
        setRunID: (@Sendable (String) async throws -> Void)? = nil,
        setResumePermissionHandler: (@Sendable (@escaping LocalACPClient.PermissionHandler) async -> Void)? = nil,
        fencedPrompt: (@Sendable (AgentMessageInput, LocalACPClient.EventHandler?, LocalACPClient.PermissionHandler?, LocalACPClient.InteractionHandler?, AgentDispatchFence) async throws -> LocalACPStopReason)? = nil,
        fencedActiveInput: (@Sendable (AgentMessageInput, AgentDispatchFence) async throws -> LocalACPActiveInputReceipt)? = nil
    ) {
        self.initializeSession = initializeSession
        self.prompt = prompt
        self.configuration = configuration
        self.observeConfiguration = observeConfiguration
        self.setConfiguration = setConfiguration
        self.setPermission = setPermission
        self.activeInput = activeInput
        self.cancel = cancel
        self.setRunID = setRunID
        self.setResumePermissionHandler = setResumePermissionHandler
        self.shutdown = shutdown
        self.fencedPrompt = fencedPrompt
        self.fencedActiveInput = fencedActiveInput
    }

    func sendPrompt(
        _ input: AgentMessageInput,
        onEvent: LocalACPClient.EventHandler?,
        onPermission: LocalACPClient.PermissionHandler?,
        onInteraction: LocalACPClient.InteractionHandler?,
        dispatchFence: AgentDispatchFence?
    ) async throws -> LocalACPStopReason {
        if let dispatchFence, let fencedPrompt {
            do {
                return try await fencedPrompt(input, onEvent, onPermission, onInteraction, dispatchFence)
            } catch {
                // A native adapter may describe a fenced-out input as unsupported.
                // Preserve errors after dispatch, where receipt can be uncertain.
                if !dispatchFence.hasDispatched { try dispatchFence.check() }
                throw error
            }
        }
        // Test drivers without a native transport claim at the invocation boundary.
        try dispatchFence?.claimDispatch()
        return try await prompt(input, onEvent, onPermission, onInteraction)
    }

    static func start(
        launch: LocalACPRuntimeLaunchConfiguration,
        workingDirectory: URL
    ) throws -> Self {
        if launch.runtimeKind == .hermes {
            let client = HermesGatewayClient(launch: launch)
            return Self(
                initializeSession: { cwd, existing, title, context in
                    try await client.initializeSession(workingDirectory: cwd, existingSessionID: existing, title: title, systemPrompt: context)
                },
                prompt: { input, event, permission, interaction in
                    try await client.prompt(input, onEvent: event, onPermission: permission, onInteraction: interaction)
                },
                configuration: { await client.sessionConfiguration() },
                setConfiguration: { model, thinking in try await client.setSessionConfiguration(model: model, thinking: thinking) },
                setPermission: { try await client.setSessionPermission($0) },
                activeInput: { input in
                    try await client.steer(input)
                    return LocalACPActiveInputReceipt(completion: Task { nil })
                },
                cancel: { try await client.cancel() },
                shutdown: { await client.shutdown() },
                fencedPrompt: { input, event, permission, interaction, fence in
                    try await client.prompt(input, onEvent: event, onPermission: permission,
                        onInteraction: interaction, dispatchFence: fence)
                },
                fencedActiveInput: { input, fence in
                    try await client.steer(input, dispatchFence: fence)
                    return LocalACPActiveInputReceipt(completion: Task { nil })
                }
            )
        }
        if launch.runtimeKind == .pi {
            let client = PiRPCClient.start(
                launch: launch,
                workingDirectory: workingDirectory
            )
            return Self(
                initializeSession: { workingDirectory, existingSessionID, title, systemPrompt in
                    try await client.initializeSession(
                        workingDirectory: workingDirectory,
                        existingSessionID: existingSessionID,
                        title: title,
                        systemPrompt: systemPrompt
                    )
                },
                prompt: { input, onEvent, onPermission, _ in
                    try await client.prompt(
                        input,
                        onEvent: onEvent,
                        onPermission: onPermission
                    )
                },
                configuration: {
                    await client.sessionConfiguration()
                },
                setConfiguration: { model, thinking in
                    try await client.setSessionConfiguration(
                        model: model,
                        thinking: thinking
                    )
                },
                activeInput: { input in
                    try await client.steer(input)
                    return LocalACPActiveInputReceipt(
                        completion: Task { nil }
                    )
                },
                cancel: {
                    await client.cancel()
                },
                shutdown: {
                    await client.shutdown()
                },
                setRunID: { await client.setRunID($0) },
                fencedPrompt: { input, event, permission, _, fence in
                    try await client.prompt(input, onEvent: event, onPermission: permission,
                        dispatchFence: fence)
                },
                fencedActiveInput: { input, fence in
                    try await client.steer(input, dispatchFence: fence)
                    return LocalACPActiveInputReceipt(completion: Task { nil })
                }
            )
        }
        let client = try LocalACPClient.start(
            launch: launch,
            workingDirectory: workingDirectory
        )
        return Self(
            initializeSession: { workingDirectory, existingSessionID, title, systemPrompt in
                try await client.initializeSession(
                    workingDirectory: workingDirectory,
                    existingSessionID: existingSessionID,
                    title: title,
                    systemPrompt: systemPrompt
                )
            },
            prompt: { input, onEvent, onPermission, onInteraction in
                try await client.prompt(
                    input,
                    onEvent: onEvent,
                    onPermission: onPermission,
                    onInteraction: onInteraction
                )
            },
            configuration: {
                await client.sessionConfiguration()
            },
            observeConfiguration: { handler in
                await client.setConfigurationHandler(handler)
            },
            setConfiguration: { model, thinking in
                try await client.setSessionConfiguration(
                    model: model,
                    thinking: thinking
                )
            },
            setPermission: { try await client.setSessionPermission($0) },
            activeInput: { input in
                do {
                    return try await client.beginActiveInput(input)
                } catch LocalACPClientError.activeInputUnsupported {
                    throw LocalACPSessionDatabaseError.steeringUnsupported
                }
            },
            cancel: {
                try await client.cancel()
            },
            shutdown: {
                await client.shutdown()
            },
            setRunID: { value in try await client.setDefaultAgentRunID(value) },
            setResumePermissionHandler: { handler in
                await client.setResumePermissionHandler(handler)
            },
            fencedPrompt: { input, event, permission, interaction, fence in
                try await client.prompt(input, onEvent: event, onPermission: permission,
                    onInteraction: interaction, dispatchFence: fence)
            },
            fencedActiveInput: { input, fence in
                do {
                    return try await client.beginActiveInput(input, dispatchFence: fence)
                } catch LocalACPClientError.activeInputUnsupported {
                    if !fence.hasDispatched { try fence.check() }
                    throw LocalACPSessionDatabaseError.steeringUnsupported
                }
            }
        )
    }
}

public actor LocalACPSessionCoordinator {
    public typealias PermissionHandler = @Sendable (
        LocalACPPermissionRequest
    ) async -> String?
    public typealias ResumePermissionHandler = @Sendable (
        _ conversationID: String,
        _ request: LocalACPPermissionRequest
    ) async -> String?
    public typealias InteractionHandler = LocalACPClient.InteractionHandler
    public typealias ChangeHandler = @Sendable (DashboardConversationChange) -> Void
    typealias ClientFactory = @Sendable (
        _ launch: LocalACPRuntimeLaunchConfiguration,
        _ workingDirectory: URL
    ) throws -> LocalACPSessionDriver

    private struct ActiveSession {
        let client: LocalACPSessionDriver
        let configurationObservationID: UUID
        let runtimeKind: AgentRuntimeKind
        // Cursor returns a session ID before it has created the durable
        // store.db needed by session/load. Keep a newly created Cursor ID
        // attached to this live process until its first prompt succeeds.
        var pendingDurableSessionID: String?
        // Actor methods reenter while an adapter call is awaiting a response.
        // Only sessions with no such caller may be evicted.
        var activeUseCount: Int
        var lastUsedSequence: UInt64
    }

    private struct PendingSessionStart {
        let id: UInt64
        let task: Task<LocalACPSessionDriver, any Error>
        var waiters: Set<UUID>
    }

    private struct PendingSessionShutdown {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private enum LifecycleError: LocalizedError {
        case shutDown
        case sessionBusy
        case sessionIdentityChanged

        var errorDescription: String? {
            switch self {
            case .shutDown: "The local ACP session coordinator has shut down."
            case .sessionBusy: "Wait for the current session operation to finish before changing permissions."
            case .sessionIdentityChanged: "The harness could not reconnect the existing session to change permissions."
            }
        }
    }

    private static let defaultClientFactory: ClientFactory = { launch, workingDirectory in
        try LocalACPSessionDriver.start(
            launch: launch,
            workingDirectory: workingDirectory
        )
    }

    private let database: WorkspaceDatabase
    private let processLease: (any LocalACPProcessLeasing)?
    private let clientFactory: ClientFactory
    private let maximumRetainedSessionCount: Int
    private let onChange: ChangeHandler?
    private let onUsage: (@Sendable (UsageRunRecorder.Observation) async -> Void)?
    private var resumePermissionHandler: ResumePermissionHandler?
    private var activeSessions: [String: ActiveSession] = [:]
    private var runTasks: [String: Task<Void, any Error>] = [:]
    private var runIDsByConversation: [String: String] = [:]
    private var admissionDispatchFences: [String: AgentDispatchFence] = [:]
    private var runDispatchFences: [String: [AgentDispatchFence]] = [:]
    private var admittingConversations: Set<String> = []
    private var cancelledAdmissions: Set<String> = []
    private var cancellationRequestedRunIDs: Set<String> = []
    private var streamWritersByRunID: [String: LocalACPAssistantStreamWriter] = [:]
    private var acceptingActiveInputRunIDs: Set<String> = []
    private struct ActiveInputTask {
        let assistantMessageID: String
        let task: Task<LocalACPStopReason?, any Error>
    }
    private var activeInputTasksByRunID: [
        String: [ActiveInputTask]
    ] = [:]
    private var streamWriterWaiters: [
        String: [CheckedContinuation<LocalACPAssistantStreamWriter?, Never>]
    ] = [:]
    private var steeringLocks: Set<String> = []
    private var steeringWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var pendingSessionStarts: [String: PendingSessionStart] = [:]
    private var pendingSessionShutdowns: [String: PendingSessionShutdown] = [:]
    private var permissionMutationConversationIDs: Set<String> = []
    private var isShutDown = false
    private var sessionStartSequence: UInt64 = 0
    private var sessionShutdownSequence: UInt64 = 0
    private var useSequence: UInt64 = 0

    public init(database: WorkspaceDatabase) {
        self.init(
            database: database,
            clientFactory: Self.defaultClientFactory
        )
    }

    init(
        database: WorkspaceDatabase,
        processLease: (any LocalACPProcessLeasing)? = nil,
        maximumRetainedSessionCount: Int = 3,
        onChange: ChangeHandler? = nil,
        onUsage: (@Sendable (UsageRunRecorder.Observation) async -> Void)? = nil,
        clientFactory: @escaping ClientFactory
    ) {
        precondition(maximumRetainedSessionCount > 0)
        self.database = database
        self.processLease = processLease
        self.maximumRetainedSessionCount = maximumRetainedSessionCount
        self.onChange = onChange
        self.onUsage = onUsage
        self.clientFactory = clientFactory
    }

    init(
        database: WorkspaceDatabase,
        processLease: any LocalACPProcessLeasing,
        onChange: ChangeHandler? = nil,
        onUsage: (@Sendable (UsageRunRecorder.Observation) async -> Void)? = nil
    ) {
        self.init(
            database: database,
            processLease: processLease,
            onChange: onChange,
            onUsage: onUsage,
            clientFactory: Self.defaultClientFactory
        )
    }

    public func setResumePermissionHandler(_ handler: @escaping ResumePermissionHandler) {
        resumePermissionHandler = handler
    }

    @discardableResult
    public func accept(
        conversationID: String,
        content: String,
        deliveryContent: String? = nil,
        noteContext: AgentNoteContext? = nil,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String? = nil,
        onPermission: PermissionHandler? = nil,
        onInteraction: InteractionHandler? = nil,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> LocalACPRunIdentifiers {
        try await accept(
            conversationID: conversationID,
            input: AgentMessageInput(text: content),
            deliveryContent: deliveryContent,
            noteContext: noteContext,
            launch: launch,
            workspace: workspace,
            systemPrompt: systemPrompt,
            onPermission: onPermission,
            onInteraction: onInteraction,
            dispatchFence: dispatchFence
        )
    }

    @discardableResult
    public func accept(
        conversationID: String,
        input: AgentMessageInput,
        deliveryContent: String? = nil,
        noteContext: AgentNoteContext? = nil,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String? = nil,
        onPermission: PermissionHandler? = nil,
        onInteraction: InteractionHandler? = nil,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> LocalACPRunIdentifiers {
        let (run, _) = try await beginAcceptedRun(
            conversationID: conversationID,
            input: input,
            deliveryContent: deliveryContent,
            noteContext: noteContext,
            launch: launch,
            workspace: workspace,
            systemPrompt: systemPrompt,
            onPermission: onPermission,
            onInteraction: onInteraction,
            dispatchFence: dispatchFence
        )
        return run
    }

    private func beginAcceptedRun(
        conversationID: String,
        input: AgentMessageInput,
        deliveryContent: String? = nil,
        noteContext: AgentNoteContext? = nil,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String?,
        onPermission: PermissionHandler?,
        onInteraction: InteractionHandler?,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> (LocalACPRunIdentifiers, Task<Void, any Error>) {
        let operationFence = dispatchFence ?? AgentDispatchFence()
        try Task.checkCancellation()
        try operationFence.check()
        guard !isShutDown else { throw LifecycleError.shutDown }
        guard admittingConversations.insert(conversationID).inserted else {
            throw LocalACPSessionDatabaseError.runAlreadyActive
        }
        admissionDispatchFences[conversationID] = operationFence
        defer {
            admissionDispatchFences.removeValue(forKey: conversationID)
            admittingConversations.remove(conversationID)
            cancelledAdmissions.remove(conversationID)
        }
        try ensureNoPermissionMutation(conversationID: conversationID)
        let leaseAcquisition = try await acquireOperationLease(
            recoveringInterruptedRuns: true
        )
        do {
            try Task.checkCancellation()
            try operationFence.check()
            guard !cancelledAdmissions.contains(conversationID) else { throw CancellationError() }
            let descriptor = try await database.localACPSession(
                conversationID: conversationID
            )
            guard descriptor.runtimeKind == launch.runtimeKind else {
                throw LocalACPSessionDatabaseError.runtimeUnavailable
            }
            try Task.checkCancellation()
            try operationFence.check()
            guard !isShutDown else { throw LifecycleError.shutDown }
            guard !cancelledAdmissions.contains(conversationID) else { throw CancellationError() }
            let run = try await database.beginLocalACPRun(
                conversationID: conversationID,
                input: input,
                noteContext: noteContext
            )
            do {
                try Task.checkCancellation()
                try operationFence.check()
                guard !isShutDown, !cancelledAdmissions.contains(conversationID) else { throw CancellationError() }
            } catch {
                // Admission is durable; its terminal write must survive caller cancellation.
                try await database.cancelLocalACPRun(runID: run.runID)
                publishChange(conversationID: conversationID, runID: run.runID, phase: .terminal)
                throw error
            }
            let deliveryInput = AgentMessageInput(
                text: deliveryContent ?? input.text,
                attachments: input.attachments
            )
            publishChange(
                conversationID: conversationID,
                runID: run.runID,
                phase: .content
            )
            acceptingActiveInputRunIDs.insert(run.runID)
            runDispatchFences[run.runID] = [operationFence]
            let task = Task { [self] in
                try await driveAcceptedRun(
                    descriptor: descriptor,
                    run: run,
                    input: deliveryInput,
                    launch: launch,
                    workspace: workspace,
                    systemPrompt: systemPrompt,
                    onPermission: onPermission,
                    onInteraction: onInteraction,
                    leaseAcquisition: leaseAcquisition,
                    dispatchFence: operationFence
                )
            }
            runTasks[run.runID] = task
            runIDsByConversation[conversationID] = run.runID
            return (run, task)
        } catch {
            releaseOperationLease(leaseAcquisition)
            throw error
        }
    }

    private func driveAcceptedRun(
        descriptor: LocalACPSessionDescriptor,
        run: LocalACPRunIdentifiers,
        input: AgentMessageInput,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String?,
        onPermission: PermissionHandler?,
        onInteraction: InteractionHandler?,
        leaseAcquisition: LocalACPProcessLeaseAcquisition?,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws {
        defer {
            releaseOperationLease(leaseAcquisition)
            finishAcceptedRun(
                conversationID: descriptor.conversationID,
                runID: run.runID
            )
        }
        do {
            try Task.checkCancellation()
            try dispatchFence?.check()
            guard !cancellationRequestedRunIDs.contains(run.runID) else { throw CancellationError() }
            let client = try await acquireSession(
                descriptor: descriptor,
                launch: launch,
                workspace: workspace,
                systemPrompt: systemPrompt,
                runID: run.runID
            )
            if cancellationRequestedRunIDs.contains(run.runID) {
                try await database.cancelLocalACPRun(runID: run.runID)
                publishChange(
                    conversationID: descriptor.conversationID,
                    runID: run.runID,
                    phase: .terminal
                )
                await releaseSession(conversationID: descriptor.conversationID)
                return
            }

            let streamWriter = LocalACPAssistantStreamWriter(
                database: database,
                runID: run.runID,
                assistantMessageID: run.assistantMessageID,
                conversationID: descriptor.conversationID,
                onChange: onChange
            )
            streamWritersByRunID[run.runID] = streamWriter
            resumeStreamWriterWaiters(runID: run.runID, writer: streamWriter)
            let permissionHandler: LocalACPClient.PermissionHandler?
            if let onPermission {
                permissionHandler = { request in
                    try? await streamWriter.finishSegment()
                    return await onPermission(request)
                }
            } else {
                permissionHandler = nil
            }
            let interactionHandler: LocalACPClient.InteractionHandler?
            if let onInteraction {
                interactionHandler = { request in
                    try? await streamWriter.finishSegment()
                    return await onInteraction(request)
                }
            } else {
                interactionHandler = nil
            }
            try await client.setRunID?(run.runID)
            try Task.checkCancellation()
            try dispatchFence?.check()
            guard !cancellationRequestedRunIDs.contains(run.runID) else { throw CancellationError() }
            var stopReason = try await client.sendPrompt(
                input,
                onEvent: { event in
                    switch event {
                    case .assistantAsset(let asset):
                        try await streamWriter.finishSegment()
                        try await self.database.recordLibraryOutput(runID: run.runID, asset: asset)
                        let label = asset.title.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                        if !asset.source.isEmpty {
                            try await streamWriter.append("\n[" + label + "](" + asset.source + ")\n")
                        } else {
                            try await streamWriter.append("\nAttached " + label + " — open in Library.\n")
                        }
                    case .assistantChunk(let chunk):
                        try await streamWriter.append(chunk)
                    case .sessionIdentity(let sessionID):
                        try await self.persistSessionIdentity(sessionID, conversationID: descriptor.conversationID, runID: run.runID)
                    case .assistantSnapshot(let content):
                        try await streamWriter.replace(content)
                    case .assistantBoundary:
                        try await streamWriter.finishSegment()
                    case .activity(let activity, let appendsContent):
                        try await streamWriter.finishSegment(for: activity)
                        try await self.database.upsertDeviceOwnedRunActivity(
                            runID: run.runID,
                            activity: activity,
                            appendingContent: appendsContent
                        )
                        await self.publishChange(
                            conversationID: descriptor.conversationID,
                            runID: run.runID,
                            phase: .content
                        )
                    case .composerPrefill(let text):
                        await self.publishChange(
                            conversationID: descriptor.conversationID,
                            runID: run.runID,
                            phase: .composerPrefill(text)
                        )
                    case .usage(let tokens):
                        let configuration = await client.configuration()
                        let sessionID = await self.usageSessionID(
                            descriptor: descriptor
                        )
                        await self.onUsage?(UsageRunRecorder.Observation(
                            runID: run.runID,
                            timestamp: Date(),
                            runtimeKind: descriptor.runtimeKind,
                            sessionID: sessionID,
                            model: configuration.model ?? descriptor.model,
                            reasoningLevel: configuration.thinking ?? descriptor.thinking,
                            agent: descriptor.buzzAgentID,
                            workspace: workspace.rootURL.path,
                            tokens: tokens,
                            costUSD: nil
                        ))
                    }
                },
                onPermission: permissionHandler,
                onInteraction: interactionHandler,
                dispatchFence: dispatchFence
            )
            stopReason = try await drainActiveInputs(
                runID: run.runID,
                conversationID: descriptor.conversationID,
                initialStopReason: stopReason
            )
            // Hermes slash commands need not create a durable native row. Its
            // client publishes the identity immediately before a provider submit.
            if descriptor.runtimeKind != .hermes {
                try await persistPendingDurableSessionID(
                    conversationID: descriptor.conversationID,
                    runID: run.runID
                )
            }
            try await persistConfiguration(
                await client.configuration(),
                conversationID: descriptor.conversationID
            )
            try await streamWriter.finish()
            switch stopReason {
            case .endTurn, .maxTokens, .maxTurnRequests:
                try await database.completeLocalACPRun(runID: run.runID)
            case .cancelled:
                try await database.cancelLocalACPRun(runID: run.runID)
            case .refusal:
                try await database.completeLocalACPRun(
                    runID: run.runID,
                    error: "The local ACP agent refused this prompt."
                )
            }
            publishChange(
                conversationID: descriptor.conversationID,
                runID: run.runID,
                phase: .terminal
            )
            await releaseSession(conversationID: descriptor.conversationID)
        } catch {
            // Terminalize only after the coalesced tail is durable. Once the
            // run is completed the database correctly rejects later chunks.
            if let writer = streamWritersByRunID[run.runID] {
                try? await writer.finish()
            }
            if cancellationRequestedRunIDs.contains(run.runID) || error is CancellationError {
                try? await database.cancelLocalACPRun(runID: run.runID)
            } else {
                try? await database.completeLocalACPRun(
                    runID: run.runID,
                    error: error.localizedDescription
                )
            }
            publishChange(
                conversationID: descriptor.conversationID,
                runID: run.runID,
                phase: .terminal
            )
            if let active = activeSessions.removeValue(
                forKey: descriptor.conversationID
            ) {
                await shutDownSession(active, conversationID: descriptor.conversationID)
            }
            throw error
        }
    }

    private func finishAcceptedRun(conversationID: String, runID: String) {
        runTasks.removeValue(forKey: runID)
        for fence in runDispatchFences.removeValue(forKey: runID) ?? [] { fence.cancel() }
        streamWritersByRunID.removeValue(forKey: runID)
        acceptingActiveInputRunIDs.remove(runID)
        let activeInputs = activeInputTasksByRunID.removeValue(forKey: runID) ?? []
        for input in activeInputs { input.task.cancel() }
        resumeStreamWriterWaiters(runID: runID, writer: nil)
        cancellationRequestedRunIDs.remove(runID)
        if runIDsByConversation[conversationID] == runID {
            runIDsByConversation.removeValue(forKey: conversationID)
        }
    }

    public func configuration(
        conversationID: String,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String? = nil
    ) async throws -> LocalACPSessionConfiguration {
        try ensureNoPermissionMutation(conversationID: conversationID)
        let leaseAcquisition = try await acquireOperationLease()
        defer {
            releaseOperationLease(leaseAcquisition)
        }
        let descriptor = try await database.localACPSession(
            conversationID: conversationID
        )
        guard descriptor.runtimeKind == launch.runtimeKind else {
            throw LocalACPSessionDatabaseError.runtimeUnavailable
        }
        let client = try await acquireSession(
            descriptor: descriptor,
            launch: launch,
            workspace: workspace,
            systemPrompt: systemPrompt
        )
        do {
            let configuration = await client.configuration()
            try await persistConfiguration(
                configuration,
                conversationID: conversationID
            )
            await releaseSession(conversationID: conversationID)
            return configuration
        } catch {
            await releaseSession(conversationID: conversationID)
            throw error
        }
    }

    public func updateConfiguration(
        conversationID: String,
        model: String? = nil,
        thinking: String? = nil,
        permission: String? = nil,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String? = nil
    ) async throws -> LocalACPSessionConfiguration {
        guard model != nil || thinking != nil || permission != nil else {
            return try await configuration(
                conversationID: conversationID,
                launch: launch,
                workspace: workspace,
                systemPrompt: systemPrompt
            )
        }
        try ensureNoPermissionMutation(conversationID: conversationID)
        if permission != nil {
            guard runIDsByConversation[conversationID] == nil, !admittingConversations.contains(conversationID) else {
                throw LocalACPSessionDatabaseError.runAlreadyActive
            }
            guard (activeSessions[conversationID]?.activeUseCount ?? 0) == 0,
                  pendingSessionStarts[conversationID] == nil else {
                throw LifecycleError.sessionBusy
            }
            permissionMutationConversationIDs.insert(conversationID)
        }
        defer {
            if permission != nil { permissionMutationConversationIDs.remove(conversationID) }
        }
        let leaseAcquisition = try await acquireOperationLease()
        defer {
            releaseOperationLease(leaseAcquisition)
        }
        let stored = try await database.localACPSession(
            conversationID: conversationID
        )
        // A replacement must be able to recover from an obsolete saved choice.
        // Keep it in memory until the native session confirms it.
        let descriptor = selecting(
            stored,
            model: model ?? stored.model,
            thinking: thinking ?? (model != nil && model != stored.model ? nil : stored.thinking),
            permission: permission ?? stored.permission
        )
        guard descriptor.runtimeKind == launch.runtimeKind else {
            throw LocalACPSessionDatabaseError.runtimeUnavailable
        }

        var client = try await acquireSession(
            descriptor: descriptor,
            launch: launch,
            workspace: workspace,
            systemPrompt: systemPrompt,
            requiredSessionID: permission == nil ? nil : stored.acpSessionID
        )
        do {
            var configuration = await client.configuration()
            if (model != nil && model != configuration.model)
                || (thinking != nil && thinking != configuration.thinking) {
                configuration = try await client.setConfiguration(model, thinking)
            }
            if let model, configuration.model != model {
                throw LocalACPClientError.configurationNotConfirmed("model")
            }
            if let thinking, configuration.thinking != thinking {
                throw LocalACPClientError.configurationNotConfirmed("thinking")
            }
            if let permission {
                guard let setPermission = client.setPermission else {
                    throw LocalACPClientError.unsupportedConfiguration("permissions")
                }
                do {
                    configuration = try await setPermission(permission)
                } catch LocalACPClientError.permissionChangeRequiresRestart {
                    let latest = try await database.localACPSession(conversationID: conversationID)
                    guard let sessionID = latest.acpSessionID,
                          let active = activeSessions[conversationID],
                          active.activeUseCount == 1 else {
                        throw LifecycleError.sessionBusy
                    }
                    activeSessions.removeValue(forKey: conversationID)
                    await shutDownSession(active, conversationID: conversationID)
                    let replacement = selecting(latest, model: configuration.model,
                        thinking: configuration.thinking, permission: permission)
                    client = try await acquireSession(
                        descriptor: replacement, launch: launch, workspace: workspace,
                        systemPrompt: systemPrompt, requiredSessionID: sessionID
                    )
                    configuration = await client.configuration()
                }
                guard configuration.permission == permission else {
                    throw LocalACPClientError.configurationNotConfirmed("permission")
                }
            }
            try await persistConfiguration(
                configuration,
                conversationID: conversationID
            )
            await releaseSession(conversationID: conversationID)
            return configuration
        } catch {
            // A rejected or unconfirmed policy must not leave a partly changed
            // process serving later prompts under an unrecorded permission mode.
            if permission != nil,
               let active = activeSessions[conversationID], active.activeUseCount == 1 {
                activeSessions.removeValue(forKey: conversationID)
                await shutDownSession(active, conversationID: conversationID)
            }
            await releaseSession(conversationID: conversationID)
            throw error
        }
    }

    private func ensureNoPermissionMutation(conversationID: String) throws {
        guard !permissionMutationConversationIDs.contains(conversationID) else {
            throw LifecycleError.sessionBusy
        }
    }

    private func selecting(
        _ descriptor: LocalACPSessionDescriptor,
        model: String?, thinking: String?, permission: String?
    ) -> LocalACPSessionDescriptor {
        LocalACPSessionDescriptor(
            conversationID: descriptor.conversationID, runtimeKind: descriptor.runtimeKind,
            title: descriptor.title, acpSessionID: descriptor.acpSessionID,
            model: model, thinking: thinking, permission: permission,
            buzzWorkspaceLinkID: descriptor.buzzWorkspaceLinkID,
            buzzAgentID: descriptor.buzzAgentID, remoteWorkspaceID: descriptor.remoteWorkspaceID
        )
    }

    public func cancel(conversationID: String) async {
        admissionDispatchFences[conversationID]?.cancel()
        if admittingConversations.contains(conversationID) { cancelledAdmissions.insert(conversationID) }
        if let runID = runIDsByConversation[conversationID] {
            cancellationRequestedRunIDs.insert(runID)
            for fence in runDispatchFences[runID] ?? [] { fence.cancel() }
        }
        guard let active = activeSessions[conversationID] else {
            if let pending = pendingSessionStarts[conversationID], pending.waiters.count == 1 {
                pending.task.cancel()
            }
            return
        }
        try? await active.client.cancel()
    }

    @discardableResult
    public func sendActiveInput(
        conversationID: String,
        content: String,
        deliveryContent: String? = nil,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> LocalACPSteeringIdentifiers {
        try await sendActiveInput(
            conversationID: conversationID,
            input: AgentMessageInput(text: content),
            deliveryContent: deliveryContent,
            dispatchFence: dispatchFence
        )
    }

    @discardableResult
    public func sendActiveInput(
        conversationID: String,
        input: AgentMessageInput,
        deliveryContent: String? = nil,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> LocalACPSteeringIdentifiers {
        let operationFence = dispatchFence ?? AgentDispatchFence()
        try Task.checkCancellation()
        try operationFence.check()
        guard let runID = runIDsByConversation[conversationID] else {
            throw LocalACPSessionDatabaseError.steeringUnsupported
        }
        // Own the fence while queued too; a stopped run must not pass this input
        // to a later run that starts before the steering lock becomes available.
        runDispatchFences[runID, default: []].append(operationFence)
        var transfersFenceToTask = false
        defer {
            if !transfersFenceToTask { releaseDispatchFence(operationFence, runID: runID) }
        }
        await acquireSteeringLock(conversationID: conversationID)
        defer { releaseSteeringLock(conversationID: conversationID) }
        try Task.checkCancellation()
        try operationFence.check()
        guard runIDsByConversation[conversationID] == runID,
              acceptingActiveInputRunIDs.contains(runID),
              let streamWriter = await streamWriter(runID: runID),
              let active = activeSessions[conversationID],
              let activeInput = active.client.activeInput else {
            throw LocalACPSessionDatabaseError.steeringUnsupported
        }
        try checkActiveInputAdmission(conversationID: conversationID, runID: runID,
            sessionID: active.configurationObservationID, dispatchFence: operationFence)
        let identifiers: LocalACPSteeringIdentifiers
        do {
            try await streamWriter.finishSegmentAndPause()
            try checkActiveInputAdmission(conversationID: conversationID, runID: runID,
                sessionID: active.configurationObservationID, dispatchFence: operationFence)
            identifiers = try await database.beginLocalACPSteeringTurn(
                runID: runID,
                input: input
            )
        } catch {
            await streamWriter.resumeAfterSegmentBoundary()
            throw error
        }
        do {
            try checkActiveInputAdmission(conversationID: conversationID, runID: runID,
                sessionID: active.configurationObservationID, dispatchFence: operationFence)
        } catch {
            // Stop can win while the steering row is being committed. Never submit
            // that row afterward, and do not leave its durable run active forever.
            if error is CancellationError {
                try? await database.cancelLocalACPRun(runID: runID)
                try? await active.client.cancel()
            } else {
                try? await database.completeLocalACPAssistantMessage(runID: runID,
                    assistantMessageID: identifiers.assistantMessageID, error: error.localizedDescription)
            }
            await streamWriter.resumeAfterSegmentBoundary(assistantMessageID: identifiers.assistantMessageID)
            publishChange(conversationID: conversationID, runID: runID, phase: .content)
            throw error
        }
        let deliveryInput = AgentMessageInput(
            text: deliveryContent ?? input.text,
            attachments: input.attachments
        )
        let task = Task {
            defer { releaseDispatchFence(operationFence, runID: runID) }
            try checkActiveInputAdmission(conversationID: conversationID, runID: runID,
                sessionID: active.configurationObservationID, dispatchFence: operationFence)
            let receipt: LocalACPActiveInputReceipt
            if let fencedInput = active.client.fencedActiveInput {
                receipt = try await fencedInput(deliveryInput, operationFence)
            } else {
                try operationFence.claimDispatch()
                receipt = try await activeInput(deliveryInput)
            }
            return try await receipt.completion.value
        }
        transfersFenceToTask = true
        activeInputTasksByRunID[runID, default: []].append(
            ActiveInputTask(
                assistantMessageID: identifiers.assistantMessageID,
                task: task
            )
        )
        publishChange(
            conversationID: conversationID,
            runID: runID,
            phase: .content
        )
        await streamWriter.resumeAfterSegmentBoundary(
            assistantMessageID: identifiers.assistantMessageID
        )
        return identifiers
    }

    private func releaseDispatchFence(_ fence: AgentDispatchFence, runID: String) {
        runDispatchFences[runID]?.removeAll { $0 === fence }
    }

    private func checkActiveInputAdmission(
        conversationID: String,
        runID: String,
        sessionID: UUID,
        dispatchFence: AgentDispatchFence?
    ) throws {
        try Task.checkCancellation()
        try dispatchFence?.check()
        guard !isShutDown, !cancellationRequestedRunIDs.contains(runID) else { throw CancellationError() }
        guard runIDsByConversation[conversationID] == runID,
              acceptingActiveInputRunIDs.contains(runID),
              activeSessions[conversationID]?.configurationObservationID == sessionID else {
            throw LocalACPSessionDatabaseError.steeringUnsupported
        }
    }

    private func drainActiveInputs(
        runID: String,
        conversationID: String,
        initialStopReason: LocalACPStopReason
    ) async throws -> LocalACPStopReason {
        var stopReason = initialStopReason
        var latestCompletionFailed = false
        var latestError: (any Error)?
        while true {
            await acquireSteeringLock(conversationID: conversationID)
            let tasks = activeInputTasksByRunID.removeValue(forKey: runID) ?? []
            if tasks.isEmpty {
                acceptingActiveInputRunIDs.remove(runID)
                releaseSteeringLock(conversationID: conversationID)
                if latestCompletionFailed, let latestError {
                    throw latestError
                }
                return stopReason
            }
            releaseSteeringLock(conversationID: conversationID)
            for input in tasks {
                do {
                    if let activeStopReason = try await input.task.value {
                        stopReason = activeStopReason
                        await completeAssistantSegment(
                            runID: runID,
                            assistantMessageID: input.assistantMessageID,
                            stopReason: activeStopReason
                        )
                    }
                    latestCompletionFailed = false
                    latestError = nil
                } catch {
                    try? await database.completeLocalACPAssistantMessage(
                        runID: runID,
                        assistantMessageID: input.assistantMessageID,
                        error: error.localizedDescription
                    )
                    latestCompletionFailed = true
                    latestError = error
                }
            }
        }
    }

    private func completeAssistantSegment(
        runID: String,
        assistantMessageID: String,
        stopReason: LocalACPStopReason
    ) async {
        let error: String? = switch stopReason {
        case .endTurn, .maxTokens, .maxTurnRequests: nil
        case .cancelled: "The local ACP run was cancelled."
        case .refusal: "The local ACP agent refused this prompt."
        }
        try? await database.completeLocalACPAssistantMessage(
            runID: runID,
            assistantMessageID: assistantMessageID,
            error: error
        )
    }

    private func streamWriter(
        runID: String
    ) async -> LocalACPAssistantStreamWriter? {
        if let writer = streamWritersByRunID[runID] { return writer }
        guard runTasks[runID] != nil else { return nil }
        return await withCheckedContinuation { continuation in
            streamWriterWaiters[runID, default: []].append(continuation)
        }
    }

    private func resumeStreamWriterWaiters(
        runID: String,
        writer: LocalACPAssistantStreamWriter?
    ) {
        let waiters = streamWriterWaiters.removeValue(forKey: runID) ?? []
        for waiter in waiters { waiter.resume(returning: writer) }
    }

    private func acquireSteeringLock(conversationID: String) async {
        guard steeringLocks.insert(conversationID).inserted == false else {
            return
        }
        await withCheckedContinuation { continuation in
            steeringWaiters[conversationID, default: []].append(continuation)
        }
    }

    private func releaseSteeringLock(conversationID: String) {
        guard var waiters = steeringWaiters[conversationID],
              !waiters.isEmpty else {
            steeringLocks.remove(conversationID)
            return
        }
        let continuation = waiters.removeFirst()
        if waiters.isEmpty {
            steeringWaiters.removeValue(forKey: conversationID)
        } else {
            steeringWaiters[conversationID] = waiters
        }
        continuation.resume()
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        for fence in admissionDispatchFences.values { fence.cancel() }
        for fences in runDispatchFences.values {
            for fence in fences { fence.cancel() }
        }
        let runs = runTasks.values
        for run in runs {
            run.cancel()
        }
        let pendingStarts = pendingSessionStarts.values
        pendingSessionStarts.removeAll()
        let pendingShutdowns = pendingSessionShutdowns.values
        pendingSessionShutdowns.removeAll()
        for pending in pendingStarts {
            pending.task.cancel()
        }
        let sessions = activeSessions.values
        activeSessions.removeAll()
        for session in sessions {
            await session.client.shutdown()
        }
        for pending in pendingStarts {
            _ = try? await pending.task.value
        }
        for pending in pendingShutdowns {
            await pending.task.value
        }
        for run in runs {
            _ = try? await run.value
        }
    }

    private func acquireOperationLease(
        recoveringInterruptedRuns: Bool = false
    ) async throws -> LocalACPProcessLeaseAcquisition? {
        let acquisition = try processLease?.acquire()
        if acquisition == .unavailable {
            throw LocalACPSessionDatabaseError.anotherApplicationIsRunningPrompt
        }
        do {
            if recoveringInterruptedRuns, acquisition == .acquired {
                try await database.recoverInterruptedLocalACPRuns()
            }
            return acquisition
        } catch {
            releaseOperationLease(acquisition)
            throw error
        }
    }

    private func releaseOperationLease(
        _ acquisition: LocalACPProcessLeaseAcquisition?
    ) {
        if acquisition != nil {
            processLease?.release()
        }
    }

    private func acquireSession(
        descriptor: LocalACPSessionDescriptor,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String?,
        runID: String? = nil,
        requiredSessionID: String? = nil
    ) async throws -> LocalACPSessionDriver {
        guard !isShutDown else {
            throw LifecycleError.shutDown
        }
        try Task.checkCancellation()
        await awaitPendingSessionShutdown(
            conversationID: descriptor.conversationID
        )
        guard !isShutDown else {
            throw LifecycleError.shutDown
        }
        try Task.checkCancellation()
        let client: LocalACPSessionDriver
        if let active = activeSessions[descriptor.conversationID] {
            guard active.runtimeKind == descriptor.runtimeKind else {
                throw LocalACPSessionDatabaseError.runtimeUnavailable
            }
            client = active.client
        } else {
            client = try await awaitSharedSessionStart(
                descriptor: descriptor,
                launch: launch,
                workspace: workspace,
                systemPrompt: systemPrompt,
                runID: runID,
                requiredSessionID: requiredSessionID
            )
        }
        guard !isShutDown else {
            throw LifecycleError.shutDown
        }
        do {
            try Task.checkCancellation()
        } catch {
            // A cancelled sole waiter can leave the successfully started
            // client idle. Cross-process coordinators cannot retain that
            // client after releasing their operation lease because another
            // app may advance the shared session before its next use.
            await releaseIdleSessionIfNeeded(
                conversationID: descriptor.conversationID
            )
            throw error
        }
        useSequence &+= 1
        activeSessions[descriptor.conversationID]?.activeUseCount += 1
        activeSessions[descriptor.conversationID]?.lastUsedSequence = useSequence
        return client
    }

    private func awaitSharedSessionStart(
        descriptor: LocalACPSessionDescriptor,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String?,
        runID: String?,
        requiredSessionID: String? = nil
    ) async throws -> LocalACPSessionDriver {
        let waiterID = UUID()
        let pending: PendingSessionStart
        if var existing = pendingSessionStarts[descriptor.conversationID] {
            existing.waiters.insert(waiterID)
            pendingSessionStarts[descriptor.conversationID] = existing
            pending = existing
        } else {
            sessionStartSequence &+= 1
            let id = sessionStartSequence
            let task = Task { [self] in
                try await startSession(
                    descriptor: descriptor,
                    launch: launch,
                    workspace: workspace,
                    systemPrompt: systemPrompt,
                    runID: runID,
                    requiredSessionID: requiredSessionID
                )
            }
            pending = PendingSessionStart(
                id: id,
                task: task,
                waiters: [waiterID]
            )
            pendingSessionStarts[descriptor.conversationID] = pending
        }

        return try await withTaskCancellationHandler {
            defer {
                finishWaitingForSessionStart(conversationID: descriptor.conversationID,
                                             id: pending.id, waiterID: waiterID)
            }
            return try await pending.task.value
        } onCancel: {
            Task {
                await self.finishWaitingForSessionStart(conversationID: descriptor.conversationID,
                                                        id: pending.id, waiterID: waiterID,
                                                        cancelling: true)
            }
        }
    }

    private func finishWaitingForSessionStart(
        conversationID: String, id: UInt64, waiterID: UUID, cancelling: Bool = false
    ) {
        guard var pending = pendingSessionStarts[conversationID], pending.id == id else { return }
        let removed = pending.waiters.remove(waiterID) != nil
        if cancelling {
            guard removed else { return }
            if pending.waiters.isEmpty { pending.task.cancel() }
            // Keep ownership until the startup task has finished shutting down.
            pendingSessionStarts[conversationID] = pending
        } else if pending.waiters.isEmpty {
            pendingSessionStarts.removeValue(forKey: conversationID)
        } else {
            pendingSessionStarts[conversationID] = pending
        }
    }

    private func releaseSession(conversationID: String) async {
        if let count = activeSessions[conversationID]?.activeUseCount {
            let remainingUseCount = max(0, count - 1)
            activeSessions[conversationID]?.activeUseCount = remainingUseCount
            useSequence &+= 1
            activeSessions[conversationID]?.lastUsedSequence = useSequence
            if remainingUseCount == 0 {
                await releaseIdleSessionIfNeeded(
                    conversationID: conversationID
                )
                return
            }
        }
        await evictIdleSessionsIfNeeded()
    }

    private func releaseIdleSessionIfNeeded(
        conversationID: String
    ) async {
        guard processLease != nil,
              pendingSessionStarts[conversationID] == nil,
              activeSessions[conversationID]?.activeUseCount == 0,
              let session = activeSessions.removeValue(
                  forKey: conversationID
              ) else {
            await evictIdleSessionsIfNeeded()
            return
        }
        await shutDownSession(session, conversationID: conversationID)
    }

    private func shutDownSession(_ session: ActiveSession, conversationID: String) async {
        sessionShutdownSequence &+= 1
        let id = sessionShutdownSequence
        let task = Task {
            await session.client.shutdown()
        }
        pendingSessionShutdowns[conversationID] = PendingSessionShutdown(
            id: id,
            task: task
        )
        await task.value
        finishPendingSessionShutdown(
            conversationID: conversationID,
            id: id
        )
    }

    private func awaitPendingSessionShutdown(
        conversationID: String
    ) async {
        guard let pending = pendingSessionShutdowns[conversationID] else {
            return
        }
        await pending.task.value
        finishPendingSessionShutdown(
            conversationID: conversationID,
            id: pending.id
        )
    }

    private func finishPendingSessionShutdown(
        conversationID: String,
        id: UInt64
    ) {
        guard pendingSessionShutdowns[conversationID]?.id == id else {
            return
        }
        pendingSessionShutdowns.removeValue(forKey: conversationID)
    }

    private func evictIdleSessionsIfNeeded() async {
        while activeSessions.count > maximumRetainedSessionCount {
            guard let conversationID = activeSessions
                .filter({
                    $0.value.activeUseCount == 0
                        && !permissionMutationConversationIDs.contains($0.key)
                        && pendingSessionStarts[$0.key] == nil
                })
                .min(by: {
                    $0.value.lastUsedSequence < $1.value.lastUsedSequence
                })?
                .key,
                let session = activeSessions.removeValue(
                    forKey: conversationID
                ) else {
                return
            }
            await shutDownSession(session, conversationID: conversationID)
        }
    }

    private func startSession(
        descriptor: LocalACPSessionDescriptor,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String?,
        runID: String? = nil,
        requiredSessionID: String? = nil
    ) async throws -> LocalACPSessionDriver {
        let model = descriptor.model
        let thinking = descriptor.thinking
        let (started, initialized) = try await startInitializedSession(
            descriptor: descriptor,
            launch: launch,
            workspace: workspace,
            systemPrompt: systemPrompt
        )
        do {
            try Task.checkCancellation()
            guard !isShutDown else {
                throw LifecycleError.shutDown
            }
            if let requiredSessionID,
               initialized.sessionID != requiredSessionID || !initialized.loadedExistingSession {
                throw LifecycleError.sessionIdentityChanged
            }
            if initialized.sessionID != descriptor.acpSessionID {
                // Cursor, Pi and Hermes allocate IDs before their session stores
                // are durable. Configuration-only drafts must remain recreatable.
                if !Self.defersNewSessionPersistence(descriptor.runtimeKind)
                    || initialized.loadedExistingSession {
                    try await database.updateLocalACPSessionID(
                        conversationID: descriptor.conversationID,
                        runID: runID,
                        sessionID: initialized.sessionID
                    )
                }
            }
            if !initialized.recoveredDefaultAgentRuns.isEmpty {
                try await database.recoverRemoteAgentRuns(conversationID: descriptor.conversationID, snapshots: initialized.recoveredDefaultAgentRuns)
                publishChange(conversationID: descriptor.conversationID, runID: "", phase: .terminal)
            }
            var configuration = initialized.configuration
            if let permission = descriptor.permission, permission != configuration.permission {
                do {
                    guard let setPermission = started.setPermission else {
                        throw LocalACPClientError.unsupportedConfiguration("permissions")
                    }
                    configuration = try await setPermission(permission)
                    try Task.checkCancellation()
                    guard configuration.permission == permission else {
                        throw LocalACPClientError.configurationNotConfirmed("permission")
                    }
                } catch {
                    publishChange(conversationID: descriptor.conversationID, runID: runID ?? "",
                        phase: .configuration(configuration))
                    throw error
                }
            }
            if let model,
               !(descriptor.runtimeKind == .defaultAgent && initialized.loadedExistingSession),
               model != configuration.model {
                guard configuration.modelOptions.contains(model) else {
                    publishChange(conversationID: descriptor.conversationID, runID: runID ?? "",
                        phase: .configuration(configuration))
                    throw LocalACPClientError.invalidConfigurationValue(field: "model", value: model)
                }
                configuration = try await started.setConfiguration(
                    model,
                    nil
                )
                try Task.checkCancellation()
                guard !isShutDown else { throw LifecycleError.shutDown }
                guard configuration.model == model else {
                    throw LocalACPClientError.configurationNotConfirmed("model")
                }
            }
            if let thinking, thinking != configuration.thinking {
                guard configuration.thinkingOptions.contains(thinking) else {
                    publishChange(conversationID: descriptor.conversationID, runID: runID ?? "",
                        phase: .configuration(configuration))
                    throw LocalACPClientError.invalidConfigurationValue(field: "thinking", value: thinking)
                }
                configuration = try await started.setConfiguration(
                    nil,
                    thinking
                )
                try Task.checkCancellation()
                guard !isShutDown else { throw LifecycleError.shutDown }
                guard configuration.thinking == thinking else {
                    throw LocalACPClientError.configurationNotConfirmed("thinking")
                }
            }
            try await persistConfiguration(
                configuration,
                conversationID: descriptor.conversationID
            )
            try Task.checkCancellation()
            guard !isShutDown else { throw LifecycleError.shutDown }
            let observationID = UUID()
            activeSessions[descriptor.conversationID] = ActiveSession(
                client: started,
                configurationObservationID: observationID,
                runtimeKind: descriptor.runtimeKind,
                pendingDurableSessionID:
                    Self.defersNewSessionPersistence(descriptor.runtimeKind)
                        && !initialized.loadedExistingSession
                        ? initialized.sessionID
                        : nil,
                activeUseCount: 0,
                lastUsedSequence: useSequence
            )
            if let observeConfiguration = started.observeConfiguration {
                await observeConfiguration { [weak self] configuration in
                    await self?.receiveConfiguration(configuration,
                        conversationID: descriptor.conversationID,
                        runID: runID ?? "", observationID: observationID)
                }
            }

            return started
        } catch {
            await started.shutdown()
            throw error
        }
    }

    private func receiveConfiguration(
        _ configuration: LocalACPSessionConfiguration,
        conversationID: String, runID: String, observationID: UUID
    ) async {
        guard activeSessions[conversationID]?.configurationObservationID == observationID else { return }
        // Keep native model/effort changes for session recreation, without
        // letting an evicted adapter overwrite its replacement's preferences.
        if !permissionMutationConversationIDs.contains(conversationID) {
            try? await persistConfiguration(configuration, conversationID: conversationID)
        }
        guard activeSessions[conversationID]?.configurationObservationID == observationID,
              !isShutDown else { return }
        onChange?(DashboardConversationChange(conversationID: conversationID,
            runID: runID, phase: .configuration(configuration)))
    }

    private func startInitializedSession(
        descriptor: LocalACPSessionDescriptor,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String?
    ) async throws -> (LocalACPSessionDriver, LocalACPInitializedSession) {
        // The launch descriptor is shared across conversations; permission is not.
        var launch = LocalACPRuntimeLaunchConfiguration(
            runtimeKind: launch.runtimeKind, executableURL: launch.executableURL,
            arguments: launch.arguments, environment: launch.environment,
            environmentKeysToRemove: launch.environmentKeysToRemove,
            environmentKeyPrefixesToRemove: launch.environmentKeyPrefixesToRemove,
            processWorkingDirectoryURL: launch.processWorkingDirectoryURL,
            requestedPermission: descriptor.permission,
            wrappedCommand: launch.wrappedCommand
        )
        launch.historyRecorder = database.historyWireRecorder(
            conversationID: descriptor.conversationID, harness: descriptor.runtimeKind.rawValue
        )
        let started = try clientFactory(launch, workspace.rootURL)
        do {
            let initialized = try await initializeSession(
                started,
                descriptor: descriptor,
                workspace: workspace,
                systemPrompt: systemPrompt
            )
            return (started, initialized)
        } catch {
            await started.shutdown()
            guard descriptor.runtimeKind == .pi,
                  descriptor.acpSessionID != nil,
                  let piError = error as? PiRPCClientError,
                  case .processExited(let detail) = piError,
                  detail?.contains("No session found matching") == true else {
                throw error
            }

            // Pi exits when --session names an ID that was allocated by an
            // earlier configuration probe but never materialized by a prompt.
            // Retry once with a fresh session and preserve it after success.
            let recovered = try clientFactory(launch, workspace.rootURL)
            do {
                let initialized = try await initializeSession(
                    recovered,
                    descriptor: descriptor,
                    usesPersistedSessionID: false,
                    workspace: workspace,
                    systemPrompt: systemPrompt
                )
                return (recovered, initialized)
            } catch {
                await recovered.shutdown()
                throw error
            }
        }
    }

    private func initializeSession(
        _ client: LocalACPSessionDriver,
        descriptor: LocalACPSessionDescriptor,
        usesPersistedSessionID: Bool = true,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String?
    ) async throws -> LocalACPInitializedSession {
        let sessionID = usesPersistedSessionID
            ? descriptor.acpSessionID
            : nil
        return try await withTaskCancellationHandler {
            // Loading a Built-in session can resume a remote run that is
            // waiting for approval, before any new prompt handler exists.
            if descriptor.runtimeKind == .defaultAgent,
               let handler = resumePermissionHandler {
                await client.setResumePermissionHandler? { request in
                    await handler(descriptor.conversationID, request)
                }
            }
            try Task.checkCancellation()
            return try await client.initializeSession(
                workspace.rootURL,
                sessionID,
                descriptor.title,
                systemPrompt
            )
        } onCancel: {
            Task {
                await client.shutdown()
            }
        }
    }

    private static func defersNewSessionPersistence(
        _ runtimeKind: AgentRuntimeKind
    ) -> Bool {
        runtimeKind == .cursor || runtimeKind == .pi || runtimeKind == .hermes
    }

    private func persistConfiguration(
        _ configuration: LocalACPSessionConfiguration,
        conversationID: String
    ) async throws {
        try await database.updateLocalACPSessionConfiguration(
            conversationID: conversationID,
            model: configuration.model,
            thinking: configuration.thinking,
            permission: configuration.permission
        )
    }

    private func persistSessionIdentity(_ sessionID: String, conversationID: String, runID: String) async throws {
        try await database.updateLocalACPSessionID(conversationID: conversationID, runID: runID, sessionID: sessionID)
        activeSessions[conversationID]?.pendingDurableSessionID = nil
    }

    private func persistPendingDurableSessionID(
        conversationID: String,
        runID: String
    ) async throws {
        guard let sessionID = activeSessions[conversationID]?
            .pendingDurableSessionID else {
            return
        }
        try await database.updateLocalACPSessionID(
            conversationID: conversationID,
            runID: runID,
            sessionID: sessionID
        )
        activeSessions[conversationID]?.pendingDurableSessionID = nil
    }

    private func publishChange(
        conversationID: String,
        runID: String,
        phase: DashboardConversationChange.Phase
    ) {
        onChange?(DashboardConversationChange(
            conversationID: conversationID,
            runID: runID,
            phase: phase
        ))
    }

    private func usageSessionID(descriptor: LocalACPSessionDescriptor) -> String {
        activeSessions[descriptor.conversationID]?.pendingDurableSessionID
            ?? descriptor.acpSessionID
            ?? descriptor.conversationID
    }
}

actor LocalACPAssistantStreamWriter {
    private static let immediateFlushCharacters = 4_096
    private static let coalescingDelay = Duration.milliseconds(75)

    private let database: WorkspaceDatabase
    private let runID: String
    private var assistantMessageID: String
    private let conversationID: String
    private let onChange: LocalACPSessionCoordinator.ChangeHandler?
    // Actor isolation does not cover suspension points. Keep each stream's
    // buffer changes and persistence ordered while SQLite runs on its worker.
    private var persistenceBusy = false
    private var persistenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var buffer = ""
    private var accumulatedText = ""
    private var seenThoughtIDs: Set<String> = []
    private var completedSegmentPrefix = ""
    private var flushTask: Task<Void, Never>?
    private var flushError: (any Error)?
    private var isFinished = false
    private var isPausedAtSegmentBoundary = false
    private var segmentBoundaryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        database: WorkspaceDatabase,
        runID: String,
        assistantMessageID: String,
        conversationID: String,
        onChange: LocalACPSessionCoordinator.ChangeHandler?
    ) {
        self.database = database
        self.runID = runID
        self.assistantMessageID = assistantMessageID
        self.conversationID = conversationID
        self.onChange = onChange
    }

    func append(_ chunk: String) async throws {
        await acquireResumedPersistence()
        defer { releasePersistence() }
        guard !isFinished else { return }
        if let flushError { throw flushError }
        guard !chunk.isEmpty else { return }
        buffer += chunk
        accumulatedText += chunk
        if buffer.count >= Self.immediateFlushCharacters {
            flushTask?.cancel()
            flushTask = nil
            try await flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.coalescingDelay)
                guard !Task.isCancelled else { return }
                await self?.flushScheduled()
            }
        }
    }

    func replace(_ content: String) async throws {
        await acquireResumedPersistence()
        defer { releasePersistence() }
        guard !isFinished else { return }
        flushTask?.cancel(); flushTask = nil
        if let flushError { throw flushError }
        guard content.hasPrefix(completedSegmentPrefix) else {
            throw LocalACPClientError.invalidResponse("The final response changed text before a steering boundary; earlier messages were preserved.")
        }
        let segment = String(content.dropFirst(completedSegmentPrefix.count))
        try await Task { try await database.replaceLocalACPAssistantMessage(runID: runID, content: segment) }.value
        buffer.removeAll(keepingCapacity: true)
        accumulatedText = content
        onChange?(DashboardConversationChange(conversationID: conversationID, runID: runID, phase: .content))
    }

    func finish() async throws {
        await acquirePersistence()
        defer { releasePersistence() }
        guard !isFinished else { return }
        isFinished = true
        resumeAfterSegmentBoundary()
        flushTask?.cancel()
        flushTask = nil
        if let flushError { throw flushError }
        try await flush()
    }

    private func flushSegment() async throws {
        flushTask?.cancel()
        flushTask = nil
        if let flushError { throw flushError }
        try await flush()
    }

    func finishSegment(for activity: AgentRunActivity) async throws {
        // A provider can deliver the last delta of an existing reasoning block
        // after the first answer token. Updating that block is not a new segment.
        if activity.kind == .thought, !seenThoughtIDs.insert(activity.id).inserted { return }
        try await finishSegment()
    }

    func finishSegment() async throws {
        await acquireResumedPersistence()
        defer { releasePersistence() }
        try await flushSegment()
        try await database.recordAssistantStreamBoundary(
            runID: runID,
            assistantMessageID: assistantMessageID,
            updatedAt: Date()
        )
    }

    func finishSegmentAndPause() async throws {
        await acquirePersistence()
        defer { releasePersistence() }
        flushTask?.cancel()
        flushTask = nil
        if let flushError { throw flushError }
        try await flush()
        try await database.recordAssistantStreamBoundary(
            runID: runID,
            assistantMessageID: assistantMessageID,
            updatedAt: Date()
        )
        completedSegmentPrefix = accumulatedText
        isPausedAtSegmentBoundary = true
    }

    func resumeAfterSegmentBoundary(assistantMessageID: String? = nil) {
        if let assistantMessageID {
            self.assistantMessageID = assistantMessageID
        }
        isPausedAtSegmentBoundary = false
        let waiters = segmentBoundaryWaiters
        segmentBoundaryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func acquirePersistence() async {
        if !persistenceBusy { persistenceBusy = true; return }
        await withCheckedContinuation { persistenceWaiters.append($0) }
    }

    private func releasePersistence() {
        if persistenceWaiters.isEmpty { persistenceBusy = false }
        else { persistenceWaiters.removeFirst().resume() }
    }

    private func acquireResumedPersistence() async {
        while true {
            await waitUntilResumed()
            await acquirePersistence()
            if !isPausedAtSegmentBoundary { return }
            releasePersistence()
        }
    }

    private func waitUntilResumed() async {
        guard isPausedAtSegmentBoundary else { return }
        await withCheckedContinuation { continuation in
            segmentBoundaryWaiters.append(continuation)
        }
    }

    private func flush() async throws {
        guard !buffer.isEmpty else { return }
        // A cancelled timer or run cannot discard a chunk already accepted into
        // this buffer. The persistence gate prevents overlapping flushes.
        let chunk = buffer
        try await Task { try await database.appendLocalACPAssistantChunk(runID: runID, chunk: chunk) }.value
        buffer.removeAll(keepingCapacity: true)
        onChange?(DashboardConversationChange(
            conversationID: conversationID,
            runID: runID,
            phase: .content
        ))
    }

    private func flushScheduled() async {
        await acquirePersistence()
        defer { releasePersistence() }
        guard !Task.isCancelled else { return }
        flushTask = nil
        do {
            try await flush()
        } catch {
            flushError = error
        }
    }
}
