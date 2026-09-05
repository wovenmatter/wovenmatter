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
    let setConfiguration: @Sendable (
        _ model: String?,
        _ thinking: String?
    ) async throws -> LocalACPSessionConfiguration
    let activeInput: (@Sendable (
        _ input: AgentMessageInput
    ) async throws -> LocalACPActiveInputReceipt)?
    let cancel: @Sendable () async throws -> Void
    let shutdown: @Sendable () async -> Void

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
        setConfiguration: @escaping @Sendable (
            _ model: String?,
            _ thinking: String?
        ) async throws -> LocalACPSessionConfiguration,
        activeInput: (@Sendable (
            _ input: AgentMessageInput
        ) async throws -> LocalACPActiveInputReceipt)? = nil,
        cancel: @escaping @Sendable () async throws -> Void,
        shutdown: @escaping @Sendable () async -> Void
    ) {
        self.initializeSession = initializeSession
        self.prompt = prompt
        self.configuration = configuration
        self.setConfiguration = setConfiguration
        self.activeInput = activeInput
        self.cancel = cancel
        self.shutdown = shutdown
    }

    static func start(
        launch: LocalACPRuntimeLaunchConfiguration,
        workingDirectory: URL
    ) throws -> Self {
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
                        input.textWithReferenceContext,
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
                    guard input.files.isEmpty else {
                        throw AgentMessageAttachmentError.unsupportedForAgent(
                            "Pi RPC does not advertise a file attachment contract yet."
                        )
                    }
                    try await client.steer(input.transportText())
                    return LocalACPActiveInputReceipt(
                        completion: Task { nil }
                    )
                },
                cancel: {
                    await client.cancel()
                },
                shutdown: {
                    await client.shutdown()
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
            setConfiguration: { model, thinking in
                try await client.setSessionConfiguration(
                    model: model,
                    thinking: thinking
                )
            },
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
            }
        )
    }
}

public actor LocalACPSessionCoordinator {
    public typealias PermissionHandler = @Sendable (
        LocalACPPermissionRequest
    ) async -> String?
    public typealias InteractionHandler = LocalACPClient.InteractionHandler
    public typealias ChangeHandler = @Sendable (DashboardConversationChange) -> Void
    typealias ClientFactory = @Sendable (
        _ launch: LocalACPRuntimeLaunchConfiguration,
        _ workingDirectory: URL
    ) throws -> LocalACPSessionDriver

    private struct ActiveSession {
        let client: LocalACPSessionDriver
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

        var errorDescription: String? {
            "The local ACP session coordinator has shut down."
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
    private var activeSessions: [String: ActiveSession] = [:]
    private var runTasks: [String: Task<Void, any Error>] = [:]
    private var runIDsByConversation: [String: String] = [:]
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
        onInteraction: InteractionHandler? = nil
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
            onInteraction: onInteraction
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
        onInteraction: InteractionHandler? = nil
    ) async throws -> LocalACPRunIdentifiers {
        let (run, _) = try beginAcceptedRun(
            conversationID: conversationID,
            input: input,
            deliveryContent: deliveryContent,
            noteContext: noteContext,
            launch: launch,
            workspace: workspace,
            systemPrompt: systemPrompt,
            onPermission: onPermission,
            onInteraction: onInteraction
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
        onInteraction: InteractionHandler?
    ) throws -> (LocalACPRunIdentifiers, Task<Void, any Error>) {
        let leaseAcquisition = try acquireOperationLease(
            recoveringInterruptedRuns: true
        )
        do {
            let descriptor = try database.localACPSession(
                conversationID: conversationID
            )
            guard descriptor.runtimeKind == launch.runtimeKind else {
                throw LocalACPSessionDatabaseError.runtimeUnavailable
            }
            if descriptor.runtimeKind == .pi, !input.files.isEmpty {
                throw AgentMessageAttachmentError.unsupportedForAgent(
                    "Pi RPC does not advertise a file attachment contract yet."
                )
            }
            let run = try database.beginLocalACPRun(
                conversationID: conversationID,
                input: input,
                noteContext: noteContext
            )
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
                    leaseAcquisition: leaseAcquisition
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
        leaseAcquisition: LocalACPProcessLeaseAcquisition?
    ) async throws {
        defer {
            releaseOperationLease(leaseAcquisition)
            finishAcceptedRun(
                conversationID: descriptor.conversationID,
                runID: run.runID
            )
        }
        do {
            let client = try await acquireSession(
                descriptor: descriptor,
                launch: launch,
                workspace: workspace,
                systemPrompt: systemPrompt,
                runID: run.runID
            )
            if cancellationRequestedRunIDs.contains(run.runID) {
                try database.completeLocalACPRun(
                    runID: run.runID,
                    error: "The local ACP run was cancelled."
                )
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
                conversationID: descriptor.conversationID,
                onChange: onChange
            )
            streamWritersByRunID[run.runID] = streamWriter
            resumeStreamWriterWaiters(runID: run.runID, writer: streamWriter)
            var stopReason = try await client.prompt(
                input,
                { event in
                    switch event {
                    case .assistantChunk(let chunk):
                        try await streamWriter.append(chunk)
                    case .assistantBoundary:
                        try await streamWriter.finishSegment()
                    case .activity(let activity, let appendsContent):
                        try await streamWriter.finishSegment()
                        try self.database.upsertDeviceOwnedRunActivity(
                            runID: run.runID,
                            activity: activity,
                            appendingContent: appendsContent
                        )
                        await self.publishChange(
                            conversationID: descriptor.conversationID,
                            runID: run.runID,
                            phase: .content
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
                onPermission,
                onInteraction
            )
            stopReason = try await drainActiveInputs(
                runID: run.runID,
                conversationID: descriptor.conversationID,
                initialStopReason: stopReason
            )
            try persistPendingDurableSessionID(
                conversationID: descriptor.conversationID,
                runID: run.runID
            )
            try persistConfiguration(
                await client.configuration(),
                conversationID: descriptor.conversationID
            )
            try await streamWriter.finish()
            switch stopReason {
            case .endTurn, .maxTokens, .maxTurnRequests:
                try database.completeLocalACPRun(runID: run.runID)
            case .cancelled:
                try database.completeLocalACPRun(
                    runID: run.runID,
                    error: "The local ACP run was cancelled."
                )
            case .refusal:
                try database.completeLocalACPRun(
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
            try? database.completeLocalACPRun(
                runID: run.runID,
                error: error.localizedDescription
            )
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
        let leaseAcquisition = try acquireOperationLease()
        defer {
            releaseOperationLease(leaseAcquisition)
        }
        let descriptor = try database.localACPSession(
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
            try persistConfiguration(
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
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String? = nil
    ) async throws -> LocalACPSessionConfiguration {
        guard model != nil || thinking != nil else {
            return try await configuration(
                conversationID: conversationID,
                launch: launch,
                workspace: workspace,
                systemPrompt: systemPrompt
            )
        }
        let leaseAcquisition = try acquireOperationLease()
        defer {
            releaseOperationLease(leaseAcquisition)
        }
        let descriptor = try database.localACPSession(
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
            let configuration = try await client.setConfiguration(
                model,
                thinking
            )
            try persistConfiguration(
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

    public func cancel(conversationID: String) async {
        if let runID = runIDsByConversation[conversationID] {
            cancellationRequestedRunIDs.insert(runID)
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
        deliveryContent: String? = nil
    ) async throws -> LocalACPSteeringIdentifiers {
        try await sendActiveInput(
            conversationID: conversationID,
            input: AgentMessageInput(text: content),
            deliveryContent: deliveryContent
        )
    }

    @discardableResult
    public func sendActiveInput(
        conversationID: String,
        input: AgentMessageInput,
        deliveryContent: String? = nil
    ) async throws -> LocalACPSteeringIdentifiers {
        await acquireSteeringLock(conversationID: conversationID)
        defer { releaseSteeringLock(conversationID: conversationID) }
        guard let runID = runIDsByConversation[conversationID],
              acceptingActiveInputRunIDs.contains(runID),
              let streamWriter = await streamWriter(runID: runID),
              let active = activeSessions[conversationID],
              let activeInput = active.client.activeInput else {
            throw LocalACPSessionDatabaseError.steeringUnsupported
        }
        if active.runtimeKind == .pi, !input.files.isEmpty {
            throw AgentMessageAttachmentError.unsupportedForAgent(
                "Pi RPC does not advertise a file attachment contract yet."
            )
        }
        try await streamWriter.finishSegmentAndPause()
        let identifiers: LocalACPSteeringIdentifiers
        do {
            identifiers = try database.beginLocalACPSteeringTurn(
                runID: runID,
                input: input
            )
        } catch {
            await streamWriter.resumeAfterSegmentBoundary()
            throw error
        }
        let deliveryInput = AgentMessageInput(
            text: deliveryContent ?? input.text,
            attachments: input.attachments
        )
        let task = Task {
            let receipt = try await activeInput(deliveryInput)
            return try await receipt.completion.value
        }
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
        await streamWriter.resumeAfterSegmentBoundary()
        return identifiers
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
                        completeAssistantSegment(
                            runID: runID,
                            assistantMessageID: input.assistantMessageID,
                            stopReason: activeStopReason
                        )
                    }
                    latestCompletionFailed = false
                    latestError = nil
                } catch {
                    try? database.completeLocalACPAssistantMessage(
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
    ) {
        let error: String? = switch stopReason {
        case .endTurn, .maxTokens, .maxTurnRequests: nil
        case .cancelled: "The local ACP run was cancelled."
        case .refusal: "The local ACP agent refused this prompt."
        }
        try? database.completeLocalACPAssistantMessage(
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
    ) throws -> LocalACPProcessLeaseAcquisition? {
        let acquisition = try processLease?.acquire()
        if acquisition == .unavailable {
            throw LocalACPSessionDatabaseError.anotherApplicationIsRunningPrompt
        }
        do {
            if recoveringInterruptedRuns, acquisition == .acquired {
                try database.recoverInterruptedLocalACPRuns()
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
        runID: String? = nil
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
                runID: runID
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
        runID: String?
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
                    runID: runID
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
                .filter({ $0.value.activeUseCount == 0 })
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
        runID: String? = nil
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
            if initialized.sessionID != descriptor.acpSessionID {
                // Cursor and Pi allocate IDs before their session stores are
                // durable. Persist those IDs only after the first prompt has
                // materialized a session that a later process can resume.
                if !Self.defersNewSessionPersistence(descriptor.runtimeKind)
                    || initialized.loadedExistingSession {
                    try database.updateLocalACPSessionID(
                        conversationID: descriptor.conversationID,
                        runID: runID,
                        sessionID: initialized.sessionID
                    )
                }
            }
            var configuration = initialized.configuration
            if let model,
               model != configuration.model,
               configuration.modelOptions.contains(model) {
                configuration = try await started.setConfiguration(
                    model,
                    nil
                )
                try Task.checkCancellation()
                guard !isShutDown else { throw LifecycleError.shutDown }
            }
            if let thinking,
               thinking != configuration.thinking,
               configuration.thinkingOptions.contains(thinking) {
                configuration = try await started.setConfiguration(
                    nil,
                    thinking
                )
                try Task.checkCancellation()
                guard !isShutDown else { throw LifecycleError.shutDown }
            }
            try persistConfiguration(
                configuration,
                conversationID: descriptor.conversationID
            )
            activeSessions[descriptor.conversationID] = ActiveSession(
                client: started,
                runtimeKind: descriptor.runtimeKind,
                pendingDurableSessionID:
                    Self.defersNewSessionPersistence(descriptor.runtimeKind)
                        && !initialized.loadedExistingSession
                        ? initialized.sessionID
                        : nil,
                activeUseCount: 0,
                lastUsedSequence: useSequence
            )
            return started
        } catch {
            await started.shutdown()
            throw error
        }
    }

    private func startInitializedSession(
        descriptor: LocalACPSessionDescriptor,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration,
        systemPrompt: String?
    ) async throws -> (LocalACPSessionDriver, LocalACPInitializedSession) {
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
            try await client.initializeSession(
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
        runtimeKind == .cursor || runtimeKind == .pi
    }

    private func persistConfiguration(
        _ configuration: LocalACPSessionConfiguration,
        conversationID: String
    ) throws {
        try database.updateLocalACPSessionConfiguration(
            conversationID: conversationID,
            model: configuration.model,
            thinking: configuration.thinking
        )
    }

    private func persistPendingDurableSessionID(
        conversationID: String,
        runID: String
    ) throws {
        guard let sessionID = activeSessions[conversationID]?
            .pendingDurableSessionID else {
            return
        }
        try database.updateLocalACPSessionID(
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

private actor LocalACPAssistantStreamWriter {
    private static let immediateFlushCharacters = 4_096
    private static let coalescingDelay = Duration.milliseconds(50)

    private let database: WorkspaceDatabase
    private let runID: String
    private let conversationID: String
    private let onChange: LocalACPSessionCoordinator.ChangeHandler?
    private var buffer = ""
    private var flushTask: Task<Void, Never>?
    private var flushError: (any Error)?
    private var isPausedAtSegmentBoundary = false
    private var segmentBoundaryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        database: WorkspaceDatabase,
        runID: String,
        conversationID: String,
        onChange: LocalACPSessionCoordinator.ChangeHandler?
    ) {
        self.database = database
        self.runID = runID
        self.conversationID = conversationID
        self.onChange = onChange
    }

    func append(_ chunk: String) async throws {
        await waitUntilResumed()
        if let flushError { throw flushError }
        guard !chunk.isEmpty else { return }
        buffer += chunk
        if buffer.count >= Self.immediateFlushCharacters {
            flushTask?.cancel()
            flushTask = nil
            try flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.coalescingDelay)
                guard !Task.isCancelled else { return }
                await self?.flushScheduled()
            }
        }
    }

    func finish() async throws {
        try await flushSegment()
    }

    private func flushSegment() async throws {
        await waitUntilResumed()
        flushTask?.cancel()
        flushTask = nil
        if let flushError { throw flushError }
        try flush()
    }

    func finishSegment() async throws {
        try await flushSegment()
    }

    func finishSegmentAndPause() throws {
        flushTask?.cancel()
        flushTask = nil
        if let flushError { throw flushError }
        try flush()
        isPausedAtSegmentBoundary = true
    }

    func resumeAfterSegmentBoundary() {
        isPausedAtSegmentBoundary = false
        let waiters = segmentBoundaryWaiters
        segmentBoundaryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitUntilResumed() async {
        guard isPausedAtSegmentBoundary else { return }
        await withCheckedContinuation { continuation in
            segmentBoundaryWaiters.append(continuation)
        }
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try database.appendLocalACPAssistantChunk(runID: runID, chunk: buffer)
        buffer.removeAll(keepingCapacity: true)
        onChange?(DashboardConversationChange(
            conversationID: conversationID,
            runID: runID,
            phase: .content
        ))
    }

    private func flushScheduled() {
        flushTask = nil
        do {
            try flush()
        } catch {
            flushError = error
        }
    }
}
