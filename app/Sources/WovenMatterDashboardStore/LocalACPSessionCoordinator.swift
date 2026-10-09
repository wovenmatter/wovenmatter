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
    let activeInputCapability: @Sendable () async -> LocalACPActiveInputRoute
    let cancel: @Sendable () async throws -> Void
    let setRunID: (@Sendable (String) async throws -> Void)?
    let setResumePermissionHandler: (@Sendable (@escaping LocalACPClient.PermissionHandler) async -> Void)?
    let finishRun: (@Sendable () async -> Void)?
    let awaitIdle: (@Sendable () async throws -> Void)?
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
        activeInputCapability: @escaping @Sendable () async -> LocalACPActiveInputRoute = { .unsupported },
        cancel: @escaping @Sendable () async throws -> Void,
        shutdown: @escaping @Sendable () async -> Void,
        finishRun: (@Sendable () async -> Void)? = nil,
        setRunID: (@Sendable (String) async throws -> Void)? = nil,
        setResumePermissionHandler: (@Sendable (@escaping LocalACPClient.PermissionHandler) async -> Void)? = nil,
        awaitIdle: (@Sendable () async throws -> Void)? = nil,
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
        self.activeInputCapability = activeInputCapability
        self.cancel = cancel
        self.setRunID = setRunID
        self.setResumePermissionHandler = setResumePermissionHandler
        self.awaitIdle = awaitIdle
        self.shutdown = shutdown
        self.finishRun = finishRun
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
                activeInputCapability: { .hermesGateway },
                cancel: { try await client.cancel() },
                shutdown: { await client.shutdown() },
                setRunID: { await client.setRunID($0) },
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
                    try await client.beginActiveInput(input)
                },
                activeInputCapability: { .piRPC },
                cancel: {
                    try await client.stop()
                },
                shutdown: {
                    await client.shutdown()
                },
                finishRun: { await client.finishRun() },
                setRunID: { await client.setRunID($0) },
                setResumePermissionHandler: { await client.setResumePermissionHandler($0) },
                fencedPrompt: { input, event, permission, _, fence in
                    try await client.prompt(input, onEvent: event, onPermission: permission,
                        dispatchFence: fence)
                },
                fencedActiveInput: { input, fence in
                    try await client.beginActiveInput(input, dispatchFence: fence)
                }
            )
        }
        let client = try LocalACPClient.start(
            launch: launch,
            workingDirectory: workingDirectory
        )
        let awaitIdle: (@Sendable () async throws -> Void)?
        if launch.runtimeKind == .defaultAgent {
            awaitIdle = { @Sendable in try await client.awaitIdle() }
        } else {
            awaitIdle = nil
        }
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
            activeInputCapability: { await client.activeInputCapability() },
            cancel: {
                try await client.cancel()
            },
            shutdown: {
                await client.shutdown()
            },
            finishRun: { await client.finishRun() },
            setRunID: { value in try await client.setDefaultAgentRunID(value) },
            setResumePermissionHandler: { handler in
                await client.setResumePermissionHandler(handler)
            },
            awaitIdle: awaitIdle,
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
        let nativeSessionID: String
        let remoteWorkspaceID: UUID?
        // Codex and Cursor allocate IDs before creating their durable session
        // history. Keep those draft IDs attached to this process until the
        // first prompt succeeds, so a configuration probe cannot persist an
        // identity that session/load cannot yet reopen.
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
        case failedStopNeedsReconnection

        var errorDescription: String? {
            switch self {
            case .shutDown: "The local ACP session coordinator has shut down."
            case .sessionBusy: "Wait for the current session operation to finish before changing permissions."
            case .sessionIdentityChanged: "The harness could not reconnect the existing session to change permissions."
            case .failedStopNeedsReconnection: "The previous Stop was not confirmed. Reconnect the original agent session and confirm it has stopped before sending again."
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
    private var cliConnectionProvider: (@Sendable (String) async throws -> AgentCLIContext?)?
    public func setCLIConnectionProvider(_ provider: @escaping @Sendable (String) async throws -> AgentCLIContext?) {
        cliConnectionProvider = provider
    }
    private var activeSessions: [String: ActiveSession] = [:]
    // Losing a client after an unsuccessful Stop is not evidence that native
    // work ended. Only that client's successful cancellation can clear this.
    private struct FailedStopIdentity {
        let observationID: UUID
        let nativeSessionID: String
        let remoteWorkspaceID: UUID?
    }
    private var failedStopSessionIDs: [String: FailedStopIdentity] = [:]
    private var runTasks: [String: Task<Void, any Error>] = [:]
    private var runIDsByConversation: [String: String] = [:]
    private var idleSessionRetirements: [UUID: Task<Void, Never>] = [:]
    private var admissionDispatchFences: [String: AgentDispatchFence] = [:]
    private var runDispatchFences: [String: [AgentDispatchFence]] = [:]
    private var admittingConversations: Set<String> = []
    private var cancelledAdmissions: Set<String> = []
    private var cancellationRequestedRunIDs: Set<String> = []
    private var durableRunIDs: Set<String> = []
    private var uncertainDurableInputRunIDs: Set<String> = []
    private var streamWritersByRunID: [String: LocalACPAssistantStreamWriter] = [:]
    private var eventBuffersByRunID: [String: LocalACPRunEventBuffer] = [:]
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
                attachments: input.attachments,
                historyDeliveryID: input.historyDeliveryID,
                visibleWorkspace: input.visibleWorkspace,
                cliContext: input.cliContext
            )
            publishChange(
                conversationID: conversationID,
                runID: run.runID,
                phase: .content
            )
            acceptingActiveInputRunIDs.insert(run.runID)
            if descriptor.runtimeKind == .defaultAgent
                || (descriptor.remoteWorkspaceID != nil && launch.environment["WOVEN_DURABLE_REMOTE_ACP"] == "1") {
                durableRunIDs.insert(run.runID)
            }
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
        let uncertainOutcomeDetail = descriptor.runtimeKind == .defaultAgent
            ? "The connection ended before the native outcome was confirmed. Review the native session history before starting new work."
            : "The connection ended before the native outcome was confirmed. Reconnect this conversation to recover its result."
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
            if durableRunIDs.contains(run.runID), let workspaceID = descriptor.remoteWorkspaceID {
                let stored = try await database.localACPSession(conversationID: descriptor.conversationID)
                guard let sessionID = activeSessions[descriptor.conversationID]?.pendingDurableSessionID ?? stored.acpSessionID else {
                    throw LocalACPClientError.sessionNotInitialized
                }
                try await database.registerDurableLocalACPRun(runID: run.runID, remoteWorkspaceID: workspaceID, sessionID: sessionID)
            }
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
            let permissionHandler: LocalACPClient.PermissionHandler?
            if let onPermission {
                permissionHandler = { request in
                    try? await streamWriter.finishSegmentForDecision()
                    return await onPermission(request)
                }
            } else {
                permissionHandler = nil
            }
            let interactionHandler: LocalACPClient.InteractionHandler?
            if let onInteraction {
                interactionHandler = { request in
                    try? await streamWriter.finishSegmentForDecision()
                    return await onInteraction(request)
                }
            } else {
                interactionHandler = nil
            }
            try await client.setRunID?(run.runID)
            let eventBuffer = LocalACPRunEventBuffer(deliver: { event in
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
            })
            eventBuffersByRunID[run.runID] = eventBuffer
            streamWritersByRunID[run.runID] = streamWriter
            resumeStreamWriterWaiters(runID: run.runID, writer: streamWriter)
            let initialResult: Result<LocalACPStopReason, any Error>
            var promptDispatchAttempted = false
            do {
                try Task.checkCancellation()
                try dispatchFence?.check()
                guard !cancellationRequestedRunIDs.contains(run.runID), !isShutDown else { throw CancellationError() }
                promptDispatchAttempted = true
                let reason = try await client.sendPrompt(input,
                    onEvent: { try await eventBuffer.receive($0) },
                    onPermission: permissionHandler, onInteraction: interactionHandler,
                    dispatchFence: dispatchFence)
                initialResult = .success(reason)
            } catch {
                if durableRunIDs.contains(run.runID),
                   dispatchFence?.hasDispatched ?? promptDispatchAttempted,
                   !Self.isDefinitiveSteeringRejection(error) {
                    uncertainDurableInputRunIDs.insert(run.runID)
                }
                initialResult = .failure(error)
            }
            let stopReason = try await drainActiveInputs(
                runID: run.runID,
                conversationID: descriptor.conversationID,
                initialResult: initialResult
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
            await client.finishRun?()
            if uncertainDurableInputRunIDs.contains(run.runID) {
                try await database.markLocalACPRunUncertain(runID: run.runID,
                    detail: uncertainOutcomeDetail)
            } else { switch stopReason {
            case .endTurn, .maxTokens, .maxTurnRequests:
                try await database.completeLocalACPRun(runID: run.runID)
            case .cancelled:
                try await database.cancelLocalACPRun(runID: run.runID)
            case .refusal:
                try await database.completeLocalACPRun(
                    runID: run.runID,
                    error: "The local ACP agent refused this prompt."
                )
            } }
            publishChange(
                conversationID: descriptor.conversationID,
                runID: run.runID,
                phase: .terminal
            )
            if uncertainDurableInputRunIDs.contains(run.runID),
               let active = activeSessions.removeValue(forKey: descriptor.conversationID) {
                await shutDownSession(active, conversationID: descriptor.conversationID)
            } else {
                await releaseSession(conversationID: descriptor.conversationID)
            }
        } catch {
            // Terminalize only after the coalesced tail is durable. Once the
            // run is completed the database correctly rejects later chunks.
            if let writer = streamWritersByRunID[run.runID] {
                try? await writer.finish()
            }
            if uncertainDurableInputRunIDs.contains(run.runID) {
                try? await database.markLocalACPRunUncertain(runID: run.runID,
                    detail: uncertainOutcomeDetail)
            } else if cancellationRequestedRunIDs.contains(run.runID) || error is CancellationError {
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
        durableRunIDs.remove(runID)
        uncertainDurableInputRunIDs.remove(runID)
        runTasks.removeValue(forKey: runID)
        for fence in runDispatchFences.removeValue(forKey: runID) ?? [] { fence.cancel() }
        streamWritersByRunID.removeValue(forKey: runID)
        eventBuffersByRunID.removeValue(forKey: runID)
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
            requiredSessionID: permission != nil && permission != stored.permission ? stored.acpSessionID : nil
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
                    guard let active = activeSessions[conversationID],
                          active.activeUseCount == 1 else {
                        throw LifecycleError.sessionBusy
                    }
                    let sessionID = latest.acpSessionID
                    // Cursor does not durably save a configuration-only draft.
                    // It can be recreated before its first prompt with the new
                    // native process flag. Saved native sessions must still load
                    // their exact identity rather than silently forking history.
                    guard sessionID != nil || (latest.runtimeKind == .cursor
                        && active.pendingDurableSessionID != nil) else {
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

    public func activeInputCapability(conversationID: String) async -> LocalACPActiveInputRoute? {
        guard let active = activeSessions[conversationID] else { return nil }
        return await active.client.activeInputCapability()
    }

    public func cancel(conversationID: String, expectedRunID: String) async throws {
        guard runIDsByConversation[conversationID] == expectedRunID else {
            throw LocalACPSessionDatabaseError.runNotFound
        }
        try await stop(conversationID: conversationID)
    }

    public func cancel(conversationID: String) async {
        try? await stop(conversationID: conversationID)
    }

    /// Admission barriers need the native result; best-effort lifecycle callers
    /// can continue using cancel without falsely acknowledging a successful Stop.
    public func stop(conversationID: String) async throws {
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
            guard failedStopSessionIDs[conversationID] == nil else {
                throw LifecycleError.failedStopNeedsReconnection
            }
            return
        }
        if let failedSession = failedStopSessionIDs[conversationID],
           failedSession.observationID != active.configurationObservationID {
            throw LifecycleError.failedStopNeedsReconnection
        }
        do {
            try await active.client.cancel()
            if failedStopSessionIDs[conversationID]?.observationID == active.configurationObservationID {
                failedStopSessionIDs.removeValue(forKey: conversationID)
            }
        } catch {
            failedStopSessionIDs[conversationID] = FailedStopIdentity(
                observationID: active.configurationObservationID,
                nativeSessionID: active.nativeSessionID,
                remoteWorkspaceID: active.remoteWorkspaceID
            )
            throw error
        }
    }

    // Called only after typed, fenced recovery confirms this exact native
    // session is idle and its durable runs have been reconciled.
    private func confirmRecoveredStop(
        conversationID: String, nativeSessionID: String, remoteWorkspaceID: UUID?
    ) {
        guard let failed = failedStopSessionIDs[conversationID],
              failed.nativeSessionID == nativeSessionID,
              failed.remoteWorkspaceID == remoteWorkspaceID else { return }
        failedStopSessionIDs.removeValue(forKey: conversationID)
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
        expectedRunID: String? = nil,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> LocalACPSteeringIdentifiers {
        let operationFence = dispatchFence ?? AgentDispatchFence()
        try Task.checkCancellation()
        try operationFence.check()
        let requestedRunID = runIDsByConversation[conversationID]
        guard let retainedRunID = requestedRunID else {
            throw LocalACPSessionDatabaseError.steeringUnsupported
        }
        // Own the fence while queued too; a stopped run must not pass this input
        // to a later run that starts before the steering lock becomes available.
        runDispatchFences[retainedRunID, default: []].append(operationFence)
        var transfersFenceToTask = false
        defer {
            if !transfersFenceToTask { releaseDispatchFence(operationFence, runID: retainedRunID) }
        }
        await acquireSteeringLock(conversationID: conversationID)
        defer { releaseSteeringLock(conversationID: conversationID) }
        if let expectedRunID, runIDsByConversation[conversationID] != expectedRunID {
            throw LocalACPSessionDatabaseError.runNotFound
        }
        try Task.checkCancellation()
        try operationFence.check()
        guard let runID = runIDsByConversation[conversationID],
              runID == requestedRunID,
              acceptingActiveInputRunIDs.contains(runID),
              !cancellationRequestedRunIDs.contains(runID),
              let streamWriter = await streamWriter(runID: runID),
              acceptingActiveInputRunIDs.contains(runID),
              !cancellationRequestedRunIDs.contains(runID),
              let eventBuffer = eventBuffersByRunID[runID],
              let active = activeSessions[conversationID],
              let activeInput = active.client.activeInput else {
            throw LocalACPSessionDatabaseError.steeringUnsupported
        }
        try checkActiveInputAdmission(conversationID: conversationID, runID: runID,
            sessionID: active.configurationObservationID, dispatchFence: operationFence)
        await eventBuffer.pause()
        let reservation: WorkspaceDatabase.SteeringReservation
        do {
            try await streamWriter.finishSegmentAndPause()
            try checkActiveInputAdmission(conversationID: conversationID, runID: runID,
                sessionID: active.configurationObservationID, dispatchFence: operationFence)
            reservation = try await database.reserveLocalACPSteeringTurn(runID: runID, input: input)
        } catch {
            await streamWriter.resumeAfterSegmentBoundary()
            try await eventBuffer.resume()
            throw error
        }
        let identifiers = reservation.identifiers
        let completion: Task<LocalACPStopReason?, any Error>
        var dispatchStarted = false
        do {
            // Reservation waits on the writer. Stop or session replacement may
            // win while it is queued, before any native request has been sent.
            try checkActiveInputAdmission(conversationID: conversationID, runID: runID,
                sessionID: active.configurationObservationID, dispatchFence: operationFence)
            dispatchStarted = true
            let deliveryInput = AgentMessageInput(text: deliveryContent ?? input.text,
                attachments: input.attachments, visibleWorkspace: input.visibleWorkspace,
                cliContext: input.cliContext)
            let receipt: LocalACPActiveInputReceipt
            if let fencedInput = active.client.fencedActiveInput {
                receipt = try await fencedInput(deliveryInput, operationFence)
            } else {
                try operationFence.claimDispatch()
                receipt = try await activeInput(deliveryInput)
            }
            completion = receipt.completion
        } catch {
            // Close an unclaimed sender before awaiting rollback. Revoke only
            // this reservation; the original run still belongs to its driver.
            let definitelyNotAdmitted = operationFence.cancel()
            if !dispatchStarted || definitelyNotAdmitted || Self.isDefinitiveSteeringRejection(error),
               (try? await database.rejectLocalACPSteeringTurn(reservation)) == true {
                await streamWriter.resumeAfterSegmentBoundary()
                try await eventBuffer.resume()
                throw error
            }
            // Dispatch may have succeeded. Keep the durable input and let the
            // run report the error; restoring its draft would invite a duplicate.
            if durableRunIDs.contains(runID) {
                uncertainDurableInputRunIDs.insert(runID)
            }
            completion = Task { throw error }
        }
        let ownedCompletion = Task {
            defer { releaseDispatchFence(operationFence, runID: runID) }
            return try await completion.value
        }
        transfersFenceToTask = true
        activeInputTasksByRunID[runID, default: []].append(ActiveInputTask(
            assistantMessageID: identifiers.assistantMessageID, task: ownedCompletion
        ))
        publishChange(conversationID: conversationID, runID: runID, phase: .content)
        await streamWriter.resumeAfterSegmentBoundary(assistantMessageID: identifiers.assistantMessageID)
        do { try await eventBuffer.resume() }
        catch {
            // Projection failed after acceptance. Retain native completion
            // ownership and surface this as a run failure, not an unsent draft.
            activeInputTasksByRunID[runID, default: []].append(ActiveInputTask(
                assistantMessageID: identifiers.assistantMessageID, task: Task { throw error }
            ))
        }
        return identifiers
    }

    private static func isDefinitiveSteeringRejection(_ error: any Error) -> Bool {
        if error is AgentMessageAttachmentError { return true }
        if let error = error as? LocalACPSessionDatabaseError { return error == .steeringUnsupported }
        if let error = error as? LocalACPClientError {
            switch error {
            case .agent, .activeInputUnsupported, .sessionNotInitialized: return true
            default: return false
            }
        }
        if case PiRPCClientError.commandFailed = error { return true }
        if case HermesGatewayError.rpc = error { return true }
        return false
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
        initialResult: Result<LocalACPStopReason, any Error>
    ) async throws -> LocalACPStopReason {
        var stopReason: LocalACPStopReason = .endTurn
        var initialError: (any Error)?
        switch initialResult {
        case .success(let reason): stopReason = reason
        case .failure(let error): initialError = error
        }
        while true {
            await acquireSteeringLock(conversationID: conversationID)
            let tasks = activeInputTasksByRunID.removeValue(forKey: runID) ?? []
            if tasks.isEmpty {
                acceptingActiveInputRunIDs.remove(runID)
                releaseSteeringLock(conversationID: conversationID)
                if let initialError { throw initialError }
                return cancellationRequestedRunIDs.contains(runID) ? .cancelled : stopReason
            }
            releaseSteeringLock(conversationID: conversationID)
            for input in tasks {
                do {
                    if let activeStopReason = try await input.task.value {
                        stopReason = activeStopReason
                        initialError = nil
                        await completeAssistantSegment(
                            runID: runID,
                            assistantMessageID: input.assistantMessageID,
                            stopReason: activeStopReason
                        )
                    }
                } catch {
                    initialError = error
                    if durableRunIDs.contains(runID), !Self.isDefinitiveSteeringRejection(error) {
                        uncertainDurableInputRunIDs.insert(runID)
                    }
                    try? await database.completeLocalACPAssistantMessage(
                        runID: runID,
                        assistantMessageID: input.assistantMessageID,
                        error: error.localizedDescription
                    )
                    publishChange(conversationID: conversationID, runID: runID, phase: .content)
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
        let idleRetirements = idleSessionRetirements.values
        idleSessionRetirements.removeAll()
        for retirement in idleRetirements { retirement.cancel() }
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
        for retirement in idleRetirements { await retirement.value }
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
            if !(await retainSessionUntilNativeIdle(conversationID: descriptor.conversationID)) {
                await releaseIdleSessionIfNeeded(conversationID: descriptor.conversationID)
            }
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
                if await retainSessionUntilNativeIdle(conversationID: conversationID) { return }
                await releaseIdleSessionIfNeeded(
                    conversationID: conversationID
                )
                return
            }
        }
        await evictIdleSessionsIfNeeded()
    }

    /// A primary response can end while Durable still owns compaction or other
    /// background work. Retain this exact process without delaying its UI result.
    private func retainSessionUntilNativeIdle(conversationID: String) async -> Bool {
        guard !isShutDown, pendingSessionStarts[conversationID] == nil,
              let session = activeSessions[conversationID], session.activeUseCount == 0,
              session.runtimeKind == .defaultAgent, let awaitIdle = session.client.awaitIdle,
              idleSessionRetirements[session.configurationObservationID] == nil else { return false }
        activeSessions[conversationID]?.activeUseCount = 1
        let lease: LocalACPProcessLeaseAcquisition?
        do { lease = try await acquireOperationLease() }
        catch {
            if activeSessions[conversationID]?.configurationObservationID == session.configurationObservationID {
                activeSessions[conversationID]?.activeUseCount = 0
            }
            return false
        }
        guard !isShutDown,
              activeSessions[conversationID]?.configurationObservationID == session.configurationObservationID else {
            releaseOperationLease(lease)
            return false
        }
        let task = Task { [self] in
            // An interrupted idle wait cannot prove quiescence. Closing this
            // retired attachment preserves the native checkpoint for reopen.
            try? await awaitIdle()
            await completeIdleSessionRetirement(conversationID: conversationID,
                observationID: session.configurationObservationID, lease: lease)
        }
        idleSessionRetirements[session.configurationObservationID] = task
        return true
    }

    private func completeIdleSessionRetirement(conversationID: String,
        observationID: UUID, lease: LocalACPProcessLeaseAcquisition?) async {
        defer { releaseOperationLease(lease) }
        guard idleSessionRetirements.removeValue(forKey: observationID) != nil,
              !isShutDown,
              activeSessions[conversationID]?.configurationObservationID == observationID else { return }
        if let count = activeSessions[conversationID]?.activeUseCount {
            let remaining = max(0, count - 1)
            activeSessions[conversationID]?.activeUseCount = remaining
            if remaining == 0 {
                await releaseIdleSessionIfNeeded(conversationID: conversationID)
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
        let observationID = UUID()
        let (started, initialized) = try await startInitializedSession(
            descriptor: descriptor, launch: launch, workspace: workspace, systemPrompt: systemPrompt)
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
                // Codex, Cursor, Pi and Hermes allocate IDs before their session stores
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
            if descriptor.runtimeKind != .defaultAgent, let workspaceID = descriptor.remoteWorkspaceID,
               initialized.loadedExistingSession,
               initialized.sessionID == descriptor.acpSessionID,
               initialized.confirmedRemoteIdleSessionID == initialized.sessionID {
                try await database.reconcileUncertainRemoteRuns(conversationID: descriptor.conversationID,
                    remoteWorkspaceID: workspaceID, sessionID: initialized.sessionID,
                    snapshots: initialized.recoveredDefaultAgentRuns)
                confirmRecoveredStop(conversationID: descriptor.conversationID,
                    nativeSessionID: initialized.sessionID, remoteWorkspaceID: workspaceID)
                publishChange(conversationID: descriptor.conversationID, runID: "", phase: .terminal)
            } else if descriptor.runtimeKind != .defaultAgent, !initialized.recoveredDefaultAgentRuns.isEmpty {
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
            activeSessions[descriptor.conversationID] = ActiveSession(
                client: started,
                configurationObservationID: observationID,
                runtimeKind: descriptor.runtimeKind,
                nativeSessionID: initialized.sessionID,
                remoteWorkspaceID: descriptor.remoteWorkspaceID,
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
        let cliConnection: AgentCLIContext?
        if let provider = cliConnectionProvider { cliConnection = try await provider(descriptor.conversationID) }
        else { cliConnection = launch.cliConnection }
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
        launch.cliConnection = cliConnection
        launch.historyRecorder = database.historyWireRecorder(
            conversationID: descriptor.conversationID, harness: descriptor.runtimeKind.rawValue,
            sourceScope: [.defaultAgent, .codex, .claudeCode, .grokBuild, .cursor].contains(descriptor.runtimeKind)
                ? nil : descriptor.remoteWorkspaceID.map { "remote:" + $0.uuidString.lowercased() } ?? "local"
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
            // Loading a durable session can resume a remote run that is
            // waiting for approval, before any new prompt handler exists.
            if descriptor.runtimeKind == .defaultAgent || descriptor.remoteWorkspaceID != nil,
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
        runtimeKind == .codex || runtimeKind == .cursor || runtimeKind == .pi || runtimeKind == .hermes
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

/// Admission must not block the transport's ordered notification queue: native
/// preflight may need to emit output or request permission before its receipt.
/// Hold transcript events locally, then deliver them into the accepted segment
/// (or the original segment on rejection), preserving wire order.
private actor LocalACPRunEventBuffer {
    let deliver: LocalACPClient.EventHandler
    private var paused = false
    private var delivering = 0
    private var pending: [LocalACPEvent] = []
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    init(deliver: @escaping LocalACPClient.EventHandler) { self.deliver = deliver }

    func receive(_ event: LocalACPEvent) async throws {
        if paused { pending.append(event); return }
        delivering += 1
        defer {
            delivering -= 1
            if delivering == 0 {
                let waiters = pauseWaiters; pauseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        try await deliver(event)
    }

    func pause() async {
        paused = true
        if delivering > 0 { await withCheckedContinuation { pauseWaiters.append($0) } }
    }

    func resume() async throws {
        defer { paused = false }
        while !pending.isEmpty {
            let events = pending; pending.removeAll(keepingCapacity: true)
            for event in events { try await deliver(event) }
        }
    }
}

actor LocalACPAssistantStreamWriter {
    enum PersistenceEvent: Sendable { case acquired, queued }
    private static let immediateFlushCharacters = 4_096
    private static let coalescingDelay = Duration.milliseconds(75)

    private let database: WorkspaceDatabase
    private let runID: String
    private var assistantMessageID: String
    private let conversationID: String
    private let onChange: LocalACPSessionCoordinator.ChangeHandler?
    // Internal observation seam for deterministic persistence-gate fixtures.
    private let onPersistenceEvent: (@Sendable (PersistenceEvent) -> Void)?
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
        onChange: LocalACPSessionCoordinator.ChangeHandler?,
        onPersistenceEvent: (@Sendable (PersistenceEvent) -> Void)? = nil
    ) {
        self.database = database
        self.runID = runID
        self.assistantMessageID = assistantMessageID
        self.conversationID = conversationID
        self.onChange = onChange
        self.onPersistenceEvent = onPersistenceEvent
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

    func finishSegmentForDecision() async throws {
        await acquirePersistence()
        defer { releasePersistence() }
        // The pre-admission boundary is already durable. The native decision
        // must remain available while later transcript events are buffered.
        // Inspect pause state under the persistence gate: waiting for resume
        // here could deadlock the admission that is awaiting this decision.
        guard !isPausedAtSegmentBoundary else { return }
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
        isPausedAtSegmentBoundary = true
    }

    func resumeAfterSegmentBoundary(assistantMessageID: String? = nil) {
        if let assistantMessageID {
            completedSegmentPrefix = accumulatedText
            self.assistantMessageID = assistantMessageID
        }
        isPausedAtSegmentBoundary = false
        let waiters = segmentBoundaryWaiters
        segmentBoundaryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func acquirePersistence() async {
        if !persistenceBusy {
            persistenceBusy = true
            onPersistenceEvent?(.acquired)
            return
        }
        await withCheckedContinuation {
            persistenceWaiters.append($0)
            onPersistenceEvent?(.queued)
        }
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
