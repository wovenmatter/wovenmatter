import Darwin
import Foundation
import WovenMatterCore

public enum PiRPCSupport: Sendable {
    public static let commandName = "pi"
    public static let arguments = ["--mode", "rpc"]
    public static let loginCommand = "pi"
    public static let probeTimeout: Duration = .seconds(8)

    public static func unauthenticatedDetail() -> String {
        "Pi CLI is installed, but no models are signed in. Run “pi” in Terminal and use /login, or set a provider API key."
    }

    public static func readyDetail(modelCount: Int) -> String {
        if modelCount == 1 {
            return "Pi is installed with native RPC. 1 signed-in model is available."
        }
        if modelCount > 1 {
            return "Pi is installed with native RPC. \(modelCount) signed-in models are available."
        }
        return "Pi is installed with native RPC."
    }

    public static func modelReference(provider: String?, id: String) -> String {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedProvider, !trimmedProvider.isEmpty {
            return "\(trimmedProvider)/\(trimmedID)"
        }
        return trimmedID
    }

    public static func splitModelReference(_ value: String) -> (provider: String, modelID: String)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let slash = trimmed.firstIndex(of: "/") {
            let provider = String(trimmed[..<slash])
            let modelID = String(trimmed[trimmed.index(after: slash)...])
            guard !provider.isEmpty, !modelID.isEmpty else { return nil }
            return (provider, modelID)
        }
        return nil
    }
}

public enum PiRPCClientError: LocalizedError, Sendable {
    case deliveryUncertain(String)
    case processExited(String? = nil)
    case invalidResponse(String)
    case commandFailed(String)
    case archiveFailed(String)
    case sessionNotInitialized
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .deliveryUncertain(let message): message
        case .processExited(let detail):
            if let detail {
                "The Pi RPC process exited unexpectedly: \(detail)"
            } else {
                "The Pi RPC process exited unexpectedly."
            }
        case .invalidResponse(let detail):
            "Pi RPC returned a malformed response: \(detail)"
        case .commandFailed(let detail):
            detail
        case .archiveFailed(let detail):
            "Pi native history could not be archived: \(detail) Its native session records remain preserved. Retry history synchronization after resolving this failure."
        case .sessionNotInitialized:
            "The Pi RPC session has not been initialized."
        case .timedOut:
            "Pi RPC did not respond in time."
        }
    }
}

public actor PiRPCClient {
    private let launch: LocalACPRuntimeLaunchConfiguration
    private let workingDirectory: URL
    private var process: Process?
    private var input: FileHandle?
    private var cursor: ACPLineCursor?
    private var nextID = 0
    private var closed = false
    private var sessionID: String?
    private var nativeStoreIdentity: String?
    private var nativeEntryCursor: String?
    private let archiveStreamIdentity = UUID().uuidString.lowercased()
    private var archiveEventOrdinal = 0
    private var runID: String?
    private var recoveredRuns: [DefaultAgentRunSnapshot] = []
    private var confirmedRemoteIdleSessionID: String?
    private var configuration = LocalACPSessionConfiguration.empty
    private var pendingResponses: [String: CheckedContinuation<[String: Any], any Error>] = [:]
    private var pendingCommandTypes: [String: String] = [:]
    private var initialArchiveRequestIDs: Set<String> = []
    private var promptEvents: LocalACPClient.EventHandler?
    private var promptPermission: LocalACPClient.PermissionHandler?
    private var promptInteraction: LocalACPClient.InteractionHandler?
    private var extensionDecisions: [String: LocalACPInteractionDecision] = [:]
    private var extensionUIClosed = false
    private var resumePermissionHandler: LocalACPClient.PermissionHandler?

    public func setResumePermissionHandler(_ handler: @escaping LocalACPClient.PermissionHandler) {
        resumePermissionHandler = handler
    }
    private var promptGeneration: UUID?
    private var reasoningPhaseSequence = 0
    private var activeReasoningPhaseID: String?
    private var assistantMessageSequence = 0
    private var assistantMessageOpen = false
    private var completedVisibleText = ""
    private var latestStopReason: LocalACPStopReason?
    private var latestTerminalError: String?
    private var promptAcknowledged = false
    private var sawAgentStart = false
    private var hasQueuedSettlement = false
    private var steeringRequestID: String?
    private var settlementGeneration = 0
    private var settlement: Result<Void, any Error>?
    private var transportError: (any Error)?
    private var settledWaiters: [CheckedContinuation<Void, any Error>] = []
    private var cancelled = false
    private var pendingDispatches: [ObjectIdentifier: AgentDispatchFence] = [:]
    private var abortTask: Task<Void, any Error>?
    private var nativeArchiveTask: Task<Void, Never>?
    private var pendingNativeArchives: [UUID: Task<Void, Never>] = [:]
    private var nativeArchiveFailure: (any Error)?
    private var readerTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private struct ExtensionUIRequest: Sendable {
        let id: String
        let method: String?
        let title: String
        let form: LocalACPFormRequest?
        let deadline: ContinuousClock.Instant?
    }

    private var stderrTask: Task<String?, Never>?
    private var shutdownTask: Task<Void, Never>?

    public init(
        launch: LocalACPRuntimeLaunchConfiguration,
        workingDirectory: URL
    ) {
        self.launch = launch
        self.workingDirectory = workingDirectory.standardizedFileURL
    }

    // Pipe-backed transport for deterministic protocol tests without subprocesses.
    init(launch: LocalACPRuntimeLaunchConfiguration, workingDirectory: URL,
         input: FileHandle, output: FileHandle) {
        self.launch = launch
        self.workingDirectory = workingDirectory
        self.input = input
        self.cursor = ACPLineCursor(handle: output)
    }

    public static func start(
        launch: LocalACPRuntimeLaunchConfiguration,
        workingDirectory: URL
    ) -> PiRPCClient {
        PiRPCClient(launch: launch, workingDirectory: workingDirectory)
    }

    public static func probe(
        launch: LocalACPRuntimeLaunchConfiguration,
        workingDirectory: URL,
        timeout: Duration = PiRPCSupport.probeTimeout
    ) async throws -> LocalACPSessionConfiguration {
        let client = start(launch: launch, workingDirectory: workingDirectory)
        return try await withTaskCancellationHandler {
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await client.shutdown()
            }
            do {
                let initialized = try await client.initializeSession(
                    workingDirectory: workingDirectory,
                    existingSessionID: nil,
                    title: nil,
                    systemPrompt: nil
                )
                timeoutTask.cancel()
                await client.shutdown()
                return initialized.configuration
            } catch {
                timeoutTask.cancel()
                await client.shutdown()
                throw error
            }
        } onCancel: {
            Task { await client.shutdown() }
        }
    }

    public func initializeSession(
        workingDirectory: URL,
        existingSessionID: String?,
        title: String?,
        systemPrompt: String?
    ) async throws -> LocalACPInitializedSession {
        _ = workingDirectory
        _ = systemPrompt
        try spawn(sessionID: existingSessionID)
        startReader()
        try await refreshConfiguration()
        if let title, !title.isEmpty {
            _ = try? await sendCommand([
                "type": "set_session_name",
                "name": title,
            ])
        }
        guard let sessionID else {
            throw PiRPCClientError.invalidResponse("missing session id")
        }
        try await archiveNativeHistory(initial: true)
        return LocalACPInitializedSession(
            sessionID: sessionID,
            loadedExistingSession: existingSessionID != nil,
            configuration: configuration,
            recoveredDefaultAgentRuns: recoveredRuns,
            confirmedRemoteIdleSessionID: confirmedRemoteIdleSessionID
        )
    }

    public func setRunID(_ value: String) { runID = value }

    public func sessionConfiguration() -> LocalACPSessionConfiguration {
        configuration
    }

    public func setSessionConfiguration(
        model: String? = nil,
        thinking: String? = nil
    ) async throws -> LocalACPSessionConfiguration {
        if let model {
            guard let parts = PiRPCSupport.splitModelReference(model) else {
                throw LocalACPClientError.unsupportedConfiguration("model")
            }
            let response = try await sendCommand([
                "type": "set_model",
                "provider": parts.provider,
                "modelId": parts.modelID,
            ])
            if response["success"] as? Bool != true {
                throw PiRPCClientError.commandFailed(
                    string(response["error"]) ?? "Pi could not select that model."
                )
            }
        }
        if let thinking {
            let response = try await sendCommand([
                "type": "set_thinking_level",
                "level": thinking,
            ])
            if response["success"] as? Bool != true {
                throw PiRPCClientError.commandFailed(
                    string(response["error"]) ?? "Pi could not set that thinking level."
                )
            }
        }
        try await refreshConfiguration()
        return configuration
    }

    public func prompt(_ input: AgentMessageInput, onEvent: LocalACPClient.EventHandler? = nil,
                       onPermission: LocalACPClient.PermissionHandler? = nil,
                       onInteraction: LocalACPClient.InteractionHandler? = nil,
                       dispatchFence: AgentDispatchFence? = nil) async throws -> LocalACPStopReason {
        try dispatchFence?.check()
        let payload = try Self.attachmentPayload(input)
        return try await prompt(payload.text, images: payload.images, cliContext: input.cliContext, onEvent: onEvent,
            onPermission: onPermission, onInteraction: onInteraction, dispatchFence: dispatchFence)
    }

    public func steer(_ input: AgentMessageInput, dispatchFence: AgentDispatchFence? = nil) async throws {
        _ = try await beginActiveInput(input, dispatchFence: dispatchFence)
    }

    public func beginActiveInput(_ input: AgentMessageInput, dispatchFence: AgentDispatchFence? = nil) async throws -> LocalACPActiveInputReceipt {
        try dispatchFence?.check()
        let payload = try Self.attachmentPayload(input)
        return try await beginActiveInput(payload.text, images: payload.images, cliContext: input.cliContext, dispatchFence: dispatchFence)
    }

    static func attachmentPayload(_ input: AgentMessageInput) throws -> (text: String, images: [[String: String]]) {
        var text = input.transportText(), images: [[String: String]] = []
        for file in input.files {
            if file.kind == .image {
                let bytes = try Data(contentsOf: file.localURL)
                guard bytes.count <= AgentMessageAttachmentLimits.maximumFileBytes else {
                    throw AgentMessageAttachmentError.fileTooLarge(name: file.fileName, maximumBytes: AgentMessageAttachmentLimits.maximumFileBytes)
                }
                images.append(["type": "image", "data": bytes.base64EncodedString(), "mimeType": file.mimeType])
            } else {
                text += "\nAttached file: " + file.fileName + "\n" + (file.remotePath ?? file.localURL.path) + "\n"
            }
        }
        return (text, images)
    }

    public func prompt(
        _ text: String,
        images: [[String: String]] = [],
        cliContext: AgentCLIContext? = nil,
        onEvent: LocalACPClient.EventHandler? = nil,
        onPermission: LocalACPClient.PermissionHandler? = nil,
        onInteraction: LocalACPClient.InteractionHandler? = nil,
        dispatchFence: AgentDispatchFence? = nil
    ) async throws -> LocalACPStopReason {
        let fence = dispatchFence ?? AgentDispatchFence()
        try fence.check()
        pendingDispatches[ObjectIdentifier(fence)] = fence
        defer { pendingDispatches[ObjectIdentifier(fence)] = nil }
        let generation = UUID()
        promptGeneration = generation
        hasQueuedSettlement = false
        sawAgentStart = false
        promptAcknowledged = false
        settlement = nil
        cancelled = false
        abortTask = nil
        reasoningPhaseSequence = 0
        activeReasoningPhaseID = nil
        assistantMessageSequence = 0
        assistantMessageOpen = false
        completedVisibleText = ""
        latestStopReason = nil
        latestTerminalError = nil
        promptEvents = onEvent
        promptPermission = onPermission
        promptInteraction = onInteraction
        defer {
            promptGeneration = nil
        }
        return try await withTaskCancellationHandler {
            do {
                var command: [String: Any] = [
                    "type": "prompt", "message": text, "images": images,
                ]
                if launch.environment["WOVEN_DURABLE_REMOTE_ACP"] == "1" {
                    command["_meta"] = ["wovenRunID": runID ?? UUID().uuidString.lowercased()]
                }
                if let cliContext {
                    var metadata = command["_meta"] as? [String: Any] ?? [:]
                    metadata["wovenTools"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cliContext))
                    command["_meta"] = metadata
                }
                let response = try await sendCommand(command, dispatchFence: fence)
                if response["success"] as? Bool != true {
                    if dictionary(response["_meta"])?["deliveryUncertain"] as? Bool == true {
                        throw PiRPCClientError.deliveryUncertain(string(response["error"]) ?? "The remote prompt receipt was lost.")
                    }
                    throw PiRPCClientError.commandFailed(
                        string(response["error"]) ?? "Pi rejected the prompt."
                    )
                }
                promptAcknowledged = true
                try Task.checkCancellation()
                try await settleHandledInputIfIdle()
                try await waitUntilSettled()
                try await abortTask?.value
                try await waitForNativeArchives()
                try await archiveNativeHistory()
                if cancelled { return .cancelled }
                if let latestTerminalError {
                    throw PiRPCClientError.commandFailed(latestTerminalError)
                }
                return latestStopReason ?? .endTurn
            } catch {
                failSettledWaiters(error)
                throw error
            }
        } onCancel: {
            Task { await self.cancelPromptTask(generation: generation) }
        }
    }

    public func steer(_ text: String, images: [[String: String]] = [], dispatchFence: AgentDispatchFence? = nil) async throws {
        _ = try await beginActiveInput(text, images: images, dispatchFence: dispatchFence)
    }

    private func beginActiveInput(_ text: String, images: [[String: String]], cliContext: AgentCLIContext? = nil, dispatchFence: AgentDispatchFence? = nil) async throws -> LocalACPActiveInputReceipt {
        let fence = dispatchFence ?? AgentDispatchFence()
        try fence.check()
        guard !cancelled else { throw CancellationError() }
        pendingDispatches[ObjectIdentifier(fence)] = fence
        defer { pendingDispatches[ObjectIdentifier(fence)] = nil }
        settlementGeneration += 1
        settlement = nil
        sawAgentStart = false
        hasQueuedSettlement = false
        var command: [String: Any] = ["type": "prompt", "streamingBehavior": "steer", "message": text, "images": images]
        if launch.environment["WOVEN_DURABLE_REMOTE_ACP"] == "1" {
            command["_meta"] = ["wovenRunID": runID ?? UUID().uuidString.lowercased()]
        }
        if let cliContext {
            var metadata = command["_meta"] as? [String: Any] ?? [:]
            metadata["wovenTools"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cliContext))
            command["_meta"] = metadata
        }
        do {
            // Native prompt preflight atomically steers a running loop or starts
            // an idle one. `steer` alone can strand a late message in Pi's queue.
            let response = try await sendCommand(command, dispatchFence: fence)
            guard response["success"] as? Bool == true else {
                if dictionary(response["_meta"])?["deliveryUncertain"] as? Bool == true {
                    throw PiRPCClientError.deliveryUncertain(string(response["error"]) ?? "The remote steering receipt was lost.")
                }
                throw PiRPCClientError.commandFailed(string(response["error"]) ?? "Pi rejected the steering input.")
            }
        } catch {
            steeringRequestID = nil
            Task { try? await self.settleHandledInputIfIdle(forceStateCheck: true) }
            throw error
        }
        return LocalACPActiveInputReceipt(completion: Task {
            try await self.settleHandledInputIfIdle(forceStateCheck: true)
            try await self.waitUntilSettled()
            try await self.abortTask?.value
            try await self.waitForNativeArchives()
            try await self.archiveNativeHistory()
            if self.cancelled { return .cancelled }
            if let error = self.latestTerminalError { throw PiRPCClientError.commandFailed(error) }
            return self.latestStopReason ?? .endTurn
        })
    }

    public func finishRun() {
        promptEvents = nil
        promptPermission = nil
        promptInteraction = nil
        runID = nil
    }

    public func cancel() async {
        try? await stop()
    }

    /// Return native abort failure to admission owners. They must not release
    /// newer input merely because the best-effort cancellation task finished.
    public func stop() async throws {
        pendingDispatches.values.forEach { $0.cancel() }
        cancelled = true
        for decision in extensionDecisions.values { decision.cancel() }
        guard promptAcknowledged, steeringRequestID == nil else {
            // Abort only stops native agent work, not an extension command that
            // is still awaiting a UI decision, including steering preflight.
            // Retire that transport so its late
            // ACK/output cannot leak into a subsequent run. The coordinator
            // recreates the same durable session after this cancellation error.
            if launch.environment["WOVEN_DURABLE_REMOTE_ACP"] == "1" {
                // The workspace owns the native process. Closing this SSH
                // attachment alone cannot fence a late preflight there.
                _ = try? await sendCommand(["type": "abort", "_meta": ["wovenStopPreflight": true]])
            }
            failPending(CancellationError())
            await shutdown()
            return
        }
        if let abortTask {
            try await abortTask.value
            return
        }
        let generation = promptGeneration
        let task = Task {
            do {
                let response = try await self.sendCommand(["type": "abort"])
                guard response["success"] as? Bool == true else {
                    throw PiRPCClientError.commandFailed(string(response["error"]) ?? "Pi could not stop the active turn.")
                }
                // Drain prior output before the session can accept another run.
                await self.eventTask?.value
                if !self.sawAgentStart { self.finishSettledWaiters() }
            } catch {
                // A rejected abort does not prove the active turn ended or the
                // pipe failed. Keep its ownership so an explicit Stop can retry.
                throw error
            }
        }
        abortTask = task
        defer { if promptGeneration == generation { abortTask = nil } }
        try await task.value
    }

    private func cancelPromptTask(generation: UUID) async {
        guard promptGeneration == generation else { return }
        pendingDispatches.values.forEach { $0.cancel() }
        failPending(CancellationError())
        await shutdown()
    }

    public func shutdown() async {
        pendingDispatches.values.forEach { $0.cancel() }
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !closed else { return }
        for decision in extensionDecisions.values { decision.cancel() }
        closed = true
        failPending(PiRPCClientError.processExited())
        readerTask?.cancel()
        eventTask?.cancel()
        let archives = Array(pendingNativeArchives.values)
        archives.forEach { $0.cancel() }
        pendingNativeArchives.removeAll()
        let tracked = process
        let inputHandle = input
        let processGroupIdentifier = tracked?.processIdentifier ?? 0
        let task = Task {
            try? inputHandle?.close()
            guard let tracked else { return }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    if localACPProcessGroupIsRunning(processGroupIdentifier) {
                        terminateLocalACPProcessGroup(tracked, signal: SIGTERM)
                    }
                    let deadline = Date().addingTimeInterval(2)
                    while localACPProcessGroupIsRunning(processGroupIdentifier),
                          Date() < deadline {
                        usleep(10_000)
                    }
                    if localACPProcessGroupIsRunning(processGroupIdentifier) {
                        terminateLocalACPProcessGroup(tracked, signal: SIGKILL)
                    }
                    if tracked.isRunning {
                        tracked.waitUntilExit()
                    }
                    PiRPCProcessRegistry.shared.unregister(tracked)
                    continuation.resume()
                }
            }
        }
        shutdownTask = task
        await task.value
        for archive in archives { await archive.value }
        nativeArchiveTask = nil
    }

    static func sessionLaunchArguments(_ launch: LocalACPRuntimeLaunchConfiguration, sessionID: String?) -> [String] {
        var arguments = launch.arguments
        guard let sessionID, !sessionID.isEmpty else { return arguments }
        if let wrapped = launch.wrappedCommand {
            let command = wrapped.command + ["--session", sessionID]
            arguments[wrapped.argumentIndex] = command.map {
                "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            }.joined(separator: " ")
        } else { arguments += ["--session", sessionID] }
        return arguments
    }

    private func spawn(sessionID: String?) throws {
        guard !closed else { throw PiRPCClientError.processExited() }
        guard process == nil, input == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let arguments = [
            "-c",
            #"set -m; exec "$@""#,
            "wovenmatter-local-pi",
        ] + NativeCLIAdapter.command(launch: launch, arguments: Self.sessionLaunchArguments(launch, sessionID: sessionID))
        process.arguments = arguments
        process.currentDirectoryURL = launch.processWorkingDirectoryURL
            ?? workingDirectory
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in launch.environment { environment[key] = value }
        environment["WOVENMATTER_LOCAL_PI"] = "1"
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        PiRPCProcessRegistry.shared.register(process)
        self.process = process
        input = stdin.fileHandleForWriting
        cursor = ACPLineCursor(handle: stdout.fileHandleForReading)
        stderrTask = Task.detached {
            Self.readStderr(from: stderr.fileHandleForReading)
        }
    }

    private func startReader() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    private func readLoop() async {
        do {
            while let cursor, !closed {
                if launch.historyRecorder != nil {
                    guard let frame = try await cursor.nextFrame() else { break }
                    switch frame {
                    case .inline(let line): try await handleLine(line)
                    case .spooled(let file, let byteCount): try await handleSpooledFrame(file, byteCount: byteCount)
                    }
                } else {
                    guard let line = try await cursor.next() else { break }
                    try await handleLine(line)
                }
            }
        } catch {
            if case LocalACPClientError.lineTooLarge = error {
                failPending(PiRPCClientError.archiveFailed("The native RPC frame exceeds the 1 GiB disk-frame limit."))
            } else { failPending(error) }
            // A failed reader cannot confirm native Stop. Fence new dispatch
            // and retire our process/relay rather than orphan unusable work.
            await shutdown()
            return
        }
        guard !closed else { return }
        extensionUIClosed = true
        for decision in extensionDecisions.values { decision.cancel() }
        if hasQueuedSettlement { await eventTask?.value }
        else { eventTask?.cancel() }
        let detail = await stderrTask?.value
        failPending(PiRPCClientError.processExited(detail))
    }

    private nonisolated static func readStderr(
        from handle: FileHandle,
        maximumBytes: Int = 16 * 1_024
    ) -> String? {
        defer { try? handle.close() }
        var captured = Data()
        do {
            while let chunk = try handle.read(upToCount: 4 * 1_024),
                  !chunk.isEmpty {
                captured.append(chunk)
                if captured.count > maximumBytes {
                    captured.removeFirst(captured.count - maximumBytes)
                }
            }
        } catch {
            return nil
        }
        guard let value = String(data: captured, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func handleLine(_ line: Data) async throws {
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw PiRPCClientError.invalidResponse("expected JSON object")
        }
        let type = string(object["type"])
        let responseID = string(object["id"]) ?? ""
        let command = string(object["command"]) ?? pendingCommandTypes[responseID]
        let safe = Self.credentialSafeRPCRecord(object, command: command)
        try await launch.historyRecorder?("in", safe.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? line)
        if type == "response" {
            let id = string(object["id"]) ?? ""
            pendingCommandTypes.removeValue(forKey: id)
            initialArchiveRequestIDs.remove(id)
            if steeringRequestID == id { steeringRequestID = nil }
            if let waiter = pendingResponses.removeValue(forKey: id) {
                waiter.resume(returning: object)
            }
            return
        }
        if launch.historyRecorder != nil, let sessionID {
            archiveEventOrdinal += 1
            let record = NativeHarnessArchive.record(id: "event:" + archiveStreamIdentity + ":" + String(archiveEventOrdinal),
                runID: runID, kind: type ?? "event", data: line, contentMode: type == "message_update" ? "delta" : "event")
            try await NativeHarnessArchive.capture(sourceID: archiveSourceID, sessionID: sessionID,
                records: [record], recorder: launch.historyRecorder)
        }
        let events = projectedEvents(from: object)
        let extensionRequest = type == "extension_ui_request"
            ? Self.extensionUIRequest(from: object)
            : nil
        queueProjection(type: type, events: events, extensionRequest: extensionRequest, aborted: object["aborted"] as? Bool == true)
    }

    private func queueProjection(type: String?, events: [LocalACPEvent], extensionRequest: ExtensionUIRequest? = nil, aborted: Bool = false) {
        guard extensionRequest != nil
                || type == "agent_settled"
                || !events.isEmpty else { return }
        // A previous loop may settle while the native prompt preflight is
        // admitting its continuation. Only post-ack settlement owns this input.
        if type == "agent_settled", steeringRequestID != nil { return }
        if type == "agent_settled" { hasQueuedSettlement = true }
        let generation = settlementGeneration
        let previous = eventTask
        eventTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                if let extensionRequest {
                    try await self.handleExtensionUI(extensionRequest)
                } else {
                    for event in events {
                        try await self.promptEvents?(event)
                    }
                    if type == "agent_settled" {
                        await self.finishSettledWaiters(generation: generation, aborted: aborted)
                    }
                }
            } catch {
                await self.failPending(error)
            }
        }
    }

    private func refreshConfiguration() async throws {
        var stateCommand: [String: Any] = ["type": "get_state"]
        if let connection = launch.cliConnection {
            stateCommand["_meta"] = ["wovenToolsConnection": try JSONSerialization.jsonObject(with: JSONEncoder().encode(connection))]
        }
        let state = try await sendCommand(stateCommand)
        let models = try await sendCommand(["type": "get_available_models"])
        let thinking = try await sendCommand(["type": "get_available_thinking_levels"])
        let commands = try await sendCommand(["type": "get_commands"])
        let data = dictionary(state["data"])
        if launch.environment["WOVEN_DURABLE_REMOTE_ACP"] == "1" {
            let metadata = dictionary(data?["_meta"])
            confirmedRemoteIdleSessionID = metadata?["recoveryComplete"] as? Bool == true
                ? string(metadata?["recoverySessionID"]) : nil
        }
        if launch.environment["WOVEN_DURABLE_REMOTE_ACP"] == "1",
           let recovery = dictionary(data?["_meta"])?["recoveredRuns"] {
            recoveredRuns = try JSONDecoder().decode([DefaultAgentRunSnapshot].self,
                from: JSONSerialization.data(withJSONObject: recovery))
        }
        sessionID = string(data?["sessionId"]) ?? string(data?["session_id"]) ?? sessionID
        nativeStoreIdentity = string(data?["sessionFile"]) ?? nativeStoreIdentity
        let model = dictionary(data?["model"]).flatMap { model in
            guard let id = string(model["id"]) else { return nil as String? }
            return PiRPCSupport.modelReference(
                provider: string(model["provider"]),
                id: id
            )
        }
        let availableModels = array(dictionary(models["data"])?["models"])?.compactMap {
            $0 as? [String: Any]
        } ?? []
        let modelOptions = availableModels.compactMap { model -> String? in
            guard let id = string(model["id"]) else { return nil }
            return PiRPCSupport.modelReference(provider: string(model["provider"]), id: id)
        }
        var seenNames: Set<String> = []
        var duplicateNames: Set<String> = []
        for model in availableModels {
            if let name = string(model["name"]), !seenNames.insert(name).inserted {
                duplicateNames.insert(name)
            }
        }
        var modelOptionMetadata: [String: SessionOptionMetadata] = [:]
        for model in availableModels {
            guard let id = string(model["id"]) else { continue }
            let provider = string(model["provider"])
            let reference = PiRPCSupport.modelReference(provider: provider, id: id)
            var name = string(model["name"])
            if let suppliedName = name, duplicateNames.contains(suppliedName),
               let provider, !provider.isEmpty {
                name = "\(suppliedName) (\(provider))"
            }
            let description = string(model["description"])
            if name != nil || description != nil {
                modelOptionMetadata[reference] = SessionOptionMetadata(
                    name: name,
                    description: description
                )
            }
        }
        let thinkingLevel = string(data?["thinkingLevel"])
        let thinkingOptions = array(dictionary(thinking["data"])?["levels"])?.compactMap {
            $0 as? String
        } ?? []
        var seenCommands: Set<String> = []
        let slashCommands = array(dictionary(commands["data"])?["commands"])?.compactMap { value -> LocalACPSlashCommand? in
            guard let command = value as? [String: Any],
                  let name = string(command["name"]),
                  !name.isEmpty, !name.contains(where: \.isWhitespace),
                  seenCommands.insert(name).inserted else {
                return nil
            }
            return LocalACPSlashCommand(
                name: name,
                detail: string(command["description"])
            )
        } ?? []
        configuration = LocalACPSessionConfiguration(
            model: model,
            thinking: thinkingLevel,
            modelOptions: modelOptions,
            thinkingOptions: thinkingOptions,
            slashCommands: slashCommands,
            modelOptionMetadata: modelOptionMetadata
        )
        if sessionID == nil {
            throw PiRPCClientError.invalidResponse("missing session id")
        }
    }

    private var archiveSourceID: String { "pi:" + (nativeStoreIdentity ?? workingDirectory.path) }

    private func handleSpooledFrame(_ file: URL, byteCount: Int) async throws {
        defer { try? FileManager.default.removeItem(at: file) }
        let metadata: PiNativeHistoryFrame.Metadata
        do { metadata = try await PiNativeHistoryFrame.inspect(file) }
        catch PiNativeHistoryFrame.Failure.unsupportedEnvelope {
            let object = try await PiNativeHistoryFrame.inspectObject(file)
            if object.scalars["type"] == "response" || object.scalars["type"] == "extension_ui_request" {
                guard byteCount <= PiNativeHistoryFrame.maximumEntryBytes else {
                    throw PiRPCClientError.archiveFailed("The native configuration response exceeds the 64 MiB control-record limit.")
                }
                try await handleLine(Data(contentsOf: file, options: [.mappedIfSafe]))
            } else {
                try await archiveSpooledEvent(file, metadata: object)
            }
            return
        } catch { throw PiRPCClientError.archiveFailed(error.localizedDescription) }
        guard var response = try JSONSerialization.jsonObject(with: metadata.envelope) as? [String: Any],
              string(response["type"]) == "response", let id = string(response["id"]),
              let command = pendingCommandTypes[id], command == "get_entries",
              metadata.arrayKey == "entries",
              response["success"] as? Bool == true, let sessionID else {
            throw PiRPCClientError.archiveFailed("The large history response did not match its pending native command.")
        }
        let sourceID = archiveSourceID
        let initial = initialArchiveRequestIDs.contains(id)
        do {
            if let recorder = launch.historyRecorder {
                try await NativeHarnessArchive.captureFile(file, byteCount: byteCount, expectedSHA256: metadata.sha256,
                    sourceID: sourceID, sessionID: sessionID, recorder: recorder) { [weak self] safeFile, reference in
                    guard let self else { throw CancellationError() }
                    // Offsets/checksums refer to the sanitized stored copy,
                    // including any length change from endpoint redaction.
                    let safeMetadata = try await PiNativeHistoryFrame.inspect(safeFile)
                    try await PiNativeHistoryFrame.records(safeFile, expected: safeMetadata) { record, ordinal in
                        try await self.archiveStreamedRecord(record, ordinal: ordinal, initial: initial,
                            sourceID: sourceID, sessionID: sessionID, file: safeFile, reference: reference)
                    }
                }
            }
        } catch { throw PiRPCClientError.archiveFailed(error.localizedDescription) }
        var data = dictionary(response["data"]) ?? [:]
        data["_wovenArchiveLastEntryID"] = nativeEntryCursor
        response["data"] = data
        pendingCommandTypes.removeValue(forKey: id)
        initialArchiveRequestIDs.remove(id)
        pendingResponses.removeValue(forKey: id)?.resume(returning: response)
    }

    private func archiveSpooledEvent(_ file: URL, metadata: PiNativeHistoryFrame.ObjectMetadata) async throws {
        guard let recorder = launch.historyRecorder, let sessionID, let type = metadata.scalars["type"],
              Self.isNativeRunEvent(type: type, scalars: metadata.scalars, message: metadata.messageScalars) else {
            throw PiRPCClientError.archiveFailed("The large native frame could not be classified as run content.")
        }
        archiveEventOrdinal += 1
        let id = "event:" + archiveStreamIdentity + ":" + String(archiveEventOrdinal)
        let sourceID = archiveSourceID, activeRunID = runID
        // Bound outstanding disk frames while letting ordinary native control
        // replies drain during SQLite ingestion of a large completed event.
        if pendingNativeArchives.count >= 2 { await nativeArchiveTask?.value }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("woven-pi-archive-" + UUID().uuidString)
        try FileManager.default.moveItem(at: file, to: owned)
        let token = UUID(), previous = nativeArchiveTask
        let task = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: owned) }
            await previous?.value
            do {
                try Task.checkCancellation()
                try await NativeHarnessArchive.captureFile(owned, byteCount: metadata.byteCount, expectedSHA256: metadata.sha256,
                    sourceID: sourceID, sessionID: sessionID, recorder: recorder) { safeFile, reference in
                    try await NativeHarnessArchive.captureRecordReference(file: safeFile, reference: reference,
                        id: id, kind: type, runID: activeRunID, byteOffset: 0, byteCount: reference.totalBytes, sha256: reference.sha256,
                        sourceID: sourceID, sessionID: sessionID, recorder: recorder)
                }
                await self?.nativeArchiveFinished(token: token, error: nil)
            } catch { await self?.nativeArchiveFinished(token: token, error: error) }
        }
        pendingNativeArchives[token] = task; nativeArchiveTask = task
        var object: [String: Any] = metadata.scalars
        object["message"] = metadata.messageScalars
        for key in ["isError", "aborted", "willRetry"] {
            if let value = metadata.scalars[key] { object[key] = value == "true" }
        }
        if type == "message_end", metadata.messageScalars["role"] == "assistant" {
            activeReasoningPhaseID = nil; assistantMessageOpen = false
            captureTerminalStatus(metadata.messageScalars)
            // Retain already delivered text deltas. A huge authoritative
            // snapshot is available through the archive, not copied into UI RAM.
            queueProjection(type: type, events: [.assistantBoundary])
        } else {
            queueProjection(type: type, events: projectedEvents(from: object), aborted: object["aborted"] as? Bool == true)
        }
    }

    private func nativeArchiveFinished(token: UUID, error: (any Error)?) {
        pendingNativeArchives.removeValue(forKey: token)
        if let error, nativeArchiveFailure == nil { nativeArchiveFailure = error }
    }

    private func waitForNativeArchives() async throws {
        await nativeArchiveTask?.value
        if let nativeArchiveFailure { throw PiRPCClientError.archiveFailed(nativeArchiveFailure.localizedDescription) }
    }

    private nonisolated static func isNativeRunEvent(type: String, scalars: [String: String], message: [String: String]) -> Bool {
        guard type != "response", type != "extension_ui_request",
              !["auth", "config", "provider", "credential", "secret"].contains(where: { type.hasPrefix($0) }) else { return false }
        return ["agent_", "message_", "tool_", "turn_", "compaction_", "auto_compaction_", "auto_retry_"].contains(where: type.hasPrefix)
            || scalars["toolCallId"] != nil || ["user", "assistant", "toolResult"].contains(message["role"] ?? "")
    }

    private func archiveStreamedRecord(_ record: PiNativeHistoryFrame.Record, ordinal: Int, initial: Bool,
                                      sourceID: String, sessionID: String, file: URL, reference: NativeHarnessArchive.FileReference) async throws {
        switch record {
        case .inline(let bytes):
            try await archiveStreamedEntry(bytes, ordinal: ordinal, initial: initial,
                sourceID: sourceID, sessionID: sessionID)
        case .reference(let offset, let count, let sha, _, let nativeID, let kind):
            guard let recorder = launch.historyRecorder else { return }
            let id = nativeID ?? "exposed:" + String(ordinal) + ":" + sha
            try await NativeHarnessArchive.captureRecordReference(file: file, reference: reference,
                id: "entry:" + id, kind: kind ?? "entry",
                runID: initial ? nil : runID, byteOffset: offset, byteCount: count, sha256: sha,
                sourceID: sourceID, sessionID: sessionID, recorder: recorder)
            nativeEntryCursor = nativeID ?? nativeEntryCursor
        }
    }

    private func archiveStreamedEntry(_ bytes: Data, ordinal: Int, initial: Bool,
                                     sourceID: String, sessionID: String) async throws {
        guard let row = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw PiNativeHistoryFrame.Failure.malformed }
        try await NativeHarnessArchive.capture(sourceID: sourceID, sessionID: sessionID,
            records: [nativeHistoryRecord(row, ordinal: ordinal, runID: initial ? nil : runID)],
            recorder: launch.historyRecorder)
        nativeEntryCursor = string(row["id"]) ?? nativeEntryCursor
    }

    private func nativeHistoryRecord(_ value: Any, ordinal: Int, runID: String?) throws -> WorkspaceNativeRunRecord {
        guard let row = dictionary(value) else { throw PiNativeHistoryFrame.Failure.malformed }
        let bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .fragmentsAllowed])
        let id = string(row["id"]) ?? "exposed:" + String(ordinal) + ":" + NativeHarnessArchive.digest(bytes)
        return NativeHarnessArchive.record(id: "entry:" + id, runID: runID,
            kind: string(row["type"]) ?? "entry", data: bytes, completeness: "native-export")
    }

    /// Copy native entries through Pi's public RPC, including compaction and
    /// context records, without opening execution-host session files.
    private func archiveNativeHistory(initial: Bool = false) async throws {
        guard let recorder = launch.historyRecorder else { return }
        var fullReconciliation = initial
        if !initial {
            let response = try await sendCommand(["type": "get_state"])
            guard response["success"] as? Bool == true else {
                throw PiRPCClientError.archiveFailed(string(response["error"]) ?? "Pi could not confirm its native session before reconciliation.")
            }
            guard let state = dictionary(response["data"]),
                  let nativeID = string(state["sessionId"]) ?? string(state["session_id"]), !nativeID.isEmpty else {
                throw PiRPCClientError.archiveFailed("Pi returned native state without a stable session identity.")
            }
            let store = string(state["sessionFile"])
            if nativeID != sessionID || store != nil && store != nativeStoreIdentity {
                nativeEntryCursor = nil
                fullReconciliation = true
            }
            if nativeID != sessionID {
                sessionID = nativeID
                try await promptEvents?(.sessionIdentity(nativeID))
            }
            nativeStoreIdentity = store ?? nativeStoreIdentity
        }
        guard let sessionID else { return }
        var command: [String: Any] = ["type": "get_entries"]
        if let nativeEntryCursor { command["since"] = nativeEntryCursor }
        let response = try await sendCommand(command, archiveInitial: fullReconciliation)
        guard response["success"] as? Bool == true, let entries = array(dictionary(response["data"])?["entries"]) else {
            throw PiRPCClientError.archiveFailed(string(response["error"]) ?? "Pi returned an incomplete native entry export.")
        }
        let records = try entries.enumerated().map {
            try nativeHistoryRecord($0.element, ordinal: $0.offset, runID: fullReconciliation ? nil : runID)
        }
        try await NativeHarnessArchive.capture(sourceID: archiveSourceID, sessionID: sessionID, records: records, recorder: recorder)
        nativeEntryCursor = string(dictionary(response["data"])?["_wovenArchiveLastEntryID"])
            ?? entries.last.flatMap(dictionary).flatMap { string($0["id"]) } ?? nativeEntryCursor
    }

    /// Provider model definitions are configuration; custom HTTP headers can
    /// contain authorization. Remove those transport fields specifically while
    /// preserving identically named values in actual messages/tool results.
    nonisolated static func credentialSafeRPCRecord(_ object: [String: Any], command: String?) -> [String: Any]? {
        guard object["type"] as? String == "response", ["get_state", "get_available_models", "set_model", "cycle_model"].contains(command ?? ""),
              var data = object["data"] as? [String: Any] else { return nil }
        func safeModel(_ model: [String: Any]) -> [String: Any] {
            model.filter { !["headers", "apiKey", "accessToken", "refreshToken", "token", "baseUrl"].contains($0.key) }
        }
        if let model = data["model"] as? [String: Any] { data["model"] = safeModel(model) }
        if let models = data["models"] as? [[String: Any]] { data["models"] = models.map(safeModel) }
        if command == "set_model" { data = safeModel(data) }
        var result = object; result["data"] = data
        return result
    }

    private var outgoingBusy = false
    private var outgoingWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireOutgoing() async {
        if outgoingBusy {
            await withCheckedContinuation { outgoingWaiters.append($0) }
        } else { outgoingBusy = true }
    }

    private func releaseOutgoing() {
        if outgoingWaiters.isEmpty { outgoingBusy = false }
        else { outgoingWaiters.removeFirst().resume() }
    }

    private func sendCommand(_ payload: [String: Any], dispatchFence: AgentDispatchFence? = nil, archiveInitial: Bool = false) async throws -> [String: Any] {
        try Task.checkCancellation()
        try dispatchFence?.check()
        if let transportError { throw transportError }
        guard !closed, let input else {
            throw PiRPCClientError.sessionNotInitialized
        }
        nextID += 1
        let id = "wm-\(nextID)"
        if payload["streamingBehavior"] as? String == "steer" { steeringRequestID = id }
        var body = payload
        body["id"] = id
        let data = try JSONSerialization.data(withJSONObject: body)
        await acquireOutgoing()
        do {
            try await launch.historyRecorder?("out", data)
            try Task.checkCancellation()
            if let transportError { throw transportError }
            guard !closed else { throw PiRPCClientError.sessionNotInitialized }
        } catch { releaseOutgoing(); throw error }
        var line = data
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], any Error>) in
            defer { releaseOutgoing() }
            pendingResponses[id] = continuation
            pendingCommandTypes[id] = payload["type"] as? String
            if archiveInitial { initialArchiveRequestIDs.insert(id) }
            do {
                // Stop can run while outbound history is being persisted.
                try dispatchFence?.claimDispatch()
                try input.write(contentsOf: line)
            } catch {
                pendingResponses.removeValue(forKey: id)
                pendingCommandTypes.removeValue(forKey: id)
                initialArchiveRequestIDs.remove(id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func settleHandledInputIfIdle(forceStateCheck: Bool = false) async throws {
        guard (!sawAgentStart || forceStateCheck), !hasQueuedSettlement, settlement == nil else { return }
        let generation = settlementGeneration
        // Pi acknowledges extension commands and handled input without an agent
        // turn. Ask native state after the ACK; an ACK alone is not completion.
        // Native prompt() sets _isAgentRunActive synchronously after preflight
        // ACK, before another stdin command can run. get_state therefore sees
        // normal startup as streaming even if agent_start has not arrived.
        let response: [String: Any]
        do {
            response = try await sendCommand(["type": "get_state"])
        } catch {
            // A short-lived transport may settle and close while the probe is
            // in flight. Preserve that authoritative, ordered terminal event.
            if hasQueuedSettlement {
                await eventTask?.value
                return
            }
            throw error
        }
        guard response["success"] as? Bool == true,
              let state = dictionary(response["data"]),
              state["isStreaming"] as? Bool == false,
              state["isCompacting"] as? Bool == false,
              Self.integer(state["pendingMessageCount"]) == 0 else { return }
        await eventTask?.value
        guard (!sawAgentStart || forceStateCheck), !hasQueuedSettlement,
              steeringRequestID == nil, generation == settlementGeneration else { return }
        finishSettledWaiters(generation: generation)
    }

    private func waitUntilSettled() async throws {
        if let settlement { return try settlement.get() }
        try await withCheckedThrowingContinuation { continuation in
            settledWaiters.append(continuation)
        }
    }

    private func finishSettledWaiters(generation: Int? = nil, aborted: Bool = false) {
        if let generation, generation != settlementGeneration { return }
        guard settlement == nil else { return }
        if aborted { cancelled = true }
        settlement = .success(())
        let waiters = settledWaiters
        settledWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func failSettledWaiters(_ error: any Error) {
        guard settlement == nil else { return }
        settlement = .failure(error)
        let waiters = settledWaiters
        settledWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func failPending(_ error: any Error) {
        transportError = error
        let pending = pendingResponses
        pendingResponses.removeAll()
        pendingCommandTypes.removeAll()
        initialArchiveRequestIDs.removeAll()
        for waiter in pending.values {
            waiter.resume(throwing: error)
        }
        failSettledWaiters(error)
    }

    private nonisolated static func extensionUIRequest(from object: [String: Any]) -> ExtensionUIRequest? {
        guard let id = string(object["id"]) else { return nil }
        let method = string(object["method"])
        if ["notify", "setStatus", "setWidget", "setTitle", "set_editor_text"].contains(method ?? "") { return nil }
        let prompt = [string(object["title"]), string(object["message"])].compactMap { $0 }.joined(separator: "\n\n")
        let title = prompt.isEmpty ? "Pi has a question." : prompt
        let form: LocalACPFormRequest?
        if method == "select", let raw = object["options"] as? [String], !raw.isEmpty, raw.count <= 256,
           Set(raw).count == raw.count {
            form = LocalACPFormRequest(message: title, fields: [LocalACPFormField(id: "value", title: "Choose an option",
                kind: .singleChoice, options: raw.map { LocalACPQuestionOption(id: $0, label: $0) })])
        } else if method == "input" || method == "editor" {
            form = LocalACPFormRequest(message: title, fields: [LocalACPFormField(id: "value", title: "Answer",
                initialValue: method == "editor" ? .string((object["prefill"] as? String) ?? "") : nil,
                placeholder: object["placeholder"] as? String, multiline: method == "editor")])
        } else { form = nil }
        let timeout = (object["timeout"] as? NSNumber)?.doubleValue
        let deadline = timeout.flatMap { value -> ContinuousClock.Instant? in
            // Pi uses Node's setTimeout only for a truthy timeout: zero disables
            // it, and delays outside Node's timer range are clamped to 1 ms.
            guard value != 0, !value.isNaN else { return nil }
            let milliseconds = value < 1 || value > Double(Int32.max) ? 1 : value.rounded(.towardZero)
            return ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
        }
        return ExtensionUIRequest(id: id, method: method, title: title, form: form, deadline: deadline)
    }

    private func handleExtensionUI(_ request: ExtensionUIRequest) async throws {
        let generation = promptGeneration
        let decision = LocalACPInteractionDecision()
        extensionDecisions[request.id] = decision
        defer { extensionDecisions.removeValue(forKey: request.id) }
        let permission = promptPermission ?? (launch.environment["WOVEN_DURABLE_REMOTE_ACP"] == "1" ? resumePermissionHandler : nil)
        let interaction = promptInteraction
        if cancelled || extensionUIClosed || Task.isCancelled || request.deadline.map({ $0 <= ContinuousClock.now }) == true { decision.cancel() }
        else if request.method == "confirm" {
            decision.start {
                let selected = await permission?(LocalACPPermissionRequest(title: request.title, options: [
                    LocalACPPermissionOption(id: "allow", name: "Allow", kind: "allow_once"),
                    LocalACPPermissionOption(id: "reject", name: "Reject", kind: "reject_once"),
                ]))
                if let selected, ["allow", "reject"].contains(selected) { return .answers(["value": .single(selected)]) }
                return .cancelled
            }
        } else if let form = request.form {
            decision.start { await interaction?(.form(form)) ?? .cancelled }
        } else { decision.cancel() }
        let timeoutTask = request.deadline.map { deadline in Task {
            do { try await ContinuousClock().sleep(until: deadline); decision.cancel() } catch { }
        } }
        defer { timeoutTask?.cancel() }
        let answer = await decision.value()
        let selected: String?
        if case .answers(let values) = answer, case .single(let value) = values["value"] { selected = value }
        else if case .formValues(let values) = answer, request.form?.accepts(values) == true,
                case .string(let value) = values["value"] { selected = value }
        else { selected = nil }
        func response(cancelled: Bool) throws -> Data {
            var payload: [String: Any] = ["type": "extension_ui_response", "id": request.id]
            if cancelled {
                payload["cancelled"] = true
                if request.method == "confirm" { payload["confirmed"] = false }
            } else if request.method == "confirm" { payload["confirmed"] = selected == "allow" }
            else { payload["value"] = selected }
            return try JSONSerialization.data(withJSONObject: payload)
        }
        await acquireOutgoing()
        defer { releaseOutgoing() }
        guard !closed, let input else { return }
        func shouldCancelResponse() -> Bool {
            selected == nil || cancelled || extensionUIClosed || Task.isCancelled || promptGeneration != generation
                || request.deadline.map { $0 <= ContinuousClock.now } == true
        }
        let rejected = shouldCancelResponse()
        var data = try response(cancelled: rejected)
        try await launch.historyRecorder?("out", data)
        guard !closed else { return }
        if !rejected && shouldCancelResponse() {
            data = try response(cancelled: true)
            try await launch.historyRecorder?("out", data)
            guard !closed else { return }
        }
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private static func encodedJSON(_ value: Any?) -> String? {
        guard let value,
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys]
              ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func toolResultText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let object = value as? [String: Any] {
            return toolResultText(object["content"]) ?? (object["text"] as? String)
        }
        if let values = value as? [Any] {
            let text = values.compactMap(toolResultText).joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private func projectedEvents(
        from object: [String: Any]
    ) -> [LocalACPEvent] {
        switch string(object["type"]) {
        case "agent_start":
            sawAgentStart = true
            return [.programStatus(ProgramStatus(state: .working, app: "pi"), runID: nil)]
        case "compaction_start", "auto_compaction_start":
            return [.programStatus(ProgramStatus(state: .working, app: "pi", message: "Compacting context"), runID: nil)]
        case "compaction_end", "auto_compaction_end":
            if let error = object["errorMessage"] as? String {
                let safe = ProgramStatus.message(error)?.replacingOccurrences(of: #"https?://[^\s]+"#,
                    with: "[URL redacted]", options: .regularExpression) ?? "Context compaction failed."
                return [.programStatus(ProgramStatus(state: .working, app: "pi", message: "Context compaction failed"), runID: nil),
                    .activity(AgentRunActivity(id: "pi-compaction", kind: .activity, phase: "end", title: "Context compaction",
                        status: "failed", content: safe, contentIsDelta: false), appendsContent: false)]
            }
            return [.programStatus(ProgramStatus(state: .working, app: "pi"), runID: nil)]
        case "auto_retry_end":
            return [.programStatus(ProgramStatus(state: .working, app: "pi"), runID: nil)]
        case "auto_retry_start":
            return [.programStatus(ProgramStatus(state: .working, app: "pi", message: "Retrying request"), runID: nil)]
        case "extension_ui_request":
            guard string(object["method"]) == "notify",
                  let message = object["message"] as? String else { return [] }
            return [.activity(AgentRunActivity(
                id: string(object["id"]) ?? UUID().uuidString,
                kind: .activity, phase: "end", title: "Pi",
                detail: string(object["notifyType"]),
                status: string(object["notifyType"]) == "error" ? "failed" : "completed",
                content: message, contentIsDelta: false
            ), appendsContent: false)]
        case "message_start":
            guard string(dictionary(object["message"])?["role"]) == "assistant" else {
                return []
            }
            beginAssistantMessage()
            return []
        case "message_update":
            let event = dictionary(object["assistantMessageEvent"])
            let kind = string(event?["type"])
            let contentIndex = Self.integer(event?["contentIndex"]) ?? 0
            ensureAssistantMessage()
            if kind == "text_start" {
                activeReasoningPhaseID = nil
                return []
            }
            if kind == "text_delta" {
                guard let delta = event?["delta"] as? String, !delta.isEmpty else { return [] }
                activeReasoningPhaseID = nil
                return [.assistantChunk(delta)]
            }
            if kind == "text_end" {
                // Reconcile the complete authoritative text at message_end.
                activeReasoningPhaseID = nil
                return []
            }
            if kind == "thinking_start" {
                reasoningPhaseSequence += 1
                let reasoningID = reasoningIdentity(
                    contentIndex: contentIndex,
                    fallbackSequence: reasoningPhaseSequence
                )
                activeReasoningPhaseID = reasoningID
                return [.activity(
                    AgentRunActivity(
                        id: reasoningID, kind: .thought, phase: "start",
                        title: "Thinking", status: "running", content: "",
                        contentIsDelta: false
                    ),
                    appendsContent: false
                )]
            }
            if kind == "thinking_delta" {
                guard let delta = (event?["delta"] as? String)
                    ?? (event?["text"] as? String), !delta.isEmpty else { return [] }
                let reasoningID: String
                if let activeReasoningPhaseID {
                    reasoningID = activeReasoningPhaseID
                } else {
                    reasoningPhaseSequence += 1
                    reasoningID = reasoningIdentity(
                        contentIndex: contentIndex,
                        fallbackSequence: reasoningPhaseSequence
                    )
                    activeReasoningPhaseID = reasoningID
                }
                return [.activity(
                    AgentRunActivity(
                        id: reasoningID,
                        kind: .thought,
                        phase: "update",
                        title: "Thinking",
                        status: "running",
                        content: delta,
                        contentIsDelta: true
                    ),
                    appendsContent: true
                )]
            }
            if kind == "thinking_end" {
                let reasoningID = activeReasoningPhaseID ?? reasoningIdentity(
                    contentIndex: contentIndex,
                    fallbackSequence: reasoningPhaseSequence + 1
                )
                let content = (event?["content"] as? String)
                    ?? (event?["text"] as? String)
                activeReasoningPhaseID = nil
                return [.activity(
                    AgentRunActivity(
                        id: reasoningID, kind: .thought, phase: "end",
                        title: "Thinking", status: "completed", content: content,
                        contentIsDelta: false
                    ),
                    appendsContent: false
                )]
            }
            return []
        case "message_end":
            guard let message = dictionary(object["message"]),
                  string(message["role"]) == "assistant" else {
                return []
            }
            activeReasoningPhaseID = nil
            ensureAssistantMessage()
            let canonical = Self.assistantText(message)
            let total = completedVisibleText + canonical
            completedVisibleText = total
            assistantMessageOpen = false
            captureTerminalStatus(message)
            return [.assistantSnapshot(total), .assistantBoundary]
        case "tool_execution_start", "tool_execution_update", "tool_execution_end":
            activeReasoningPhaseID = nil
            let type = string(object["type"])
            let isStart = type == "tool_execution_start"
            let isEnd = type == "tool_execution_end"
            let failed = object["isError"] as? Bool == true
            let result = object["result"] ?? object["partialResult"]
            return [.activity(
                AgentRunActivity(
                    id: string(object["toolCallId"]) ?? "tool",
                    kind: .tool,
                    phase: isStart ? "start" : isEnd ? "end" : "update",
                    title: string(object["toolName"]) ?? "Tool",
                    status: isEnd ? (failed ? "failed" : "completed") : "running",
                    toolName: string(object["toolName"]),
                    content: Self.toolResultText(result),
                    contentIsDelta: false,
                    rawInputJSON: Self.encodedJSON(object["args"]),
                    rawOutputJSON: Self.encodedJSON(result)
                ),
                appendsContent: false
            )]
        case "agent_end":
            if object["willRetry"] as? Bool != true,
               let messages = object["messages"] as? [[String: Any]],
               let assistant = messages.last(where: { string($0["role"]) == "assistant" }) {
                captureTerminalStatus(assistant)
            }
            return []
        default:
            return []
        }
    }

    private func beginAssistantMessage() {
        assistantMessageSequence += 1
        assistantMessageOpen = true
        activeReasoningPhaseID = nil
    }

    private func ensureAssistantMessage() {
        if !assistantMessageOpen { beginAssistantMessage() }
    }

    private func reasoningIdentity(
        contentIndex: Int,
        fallbackSequence: Int
    ) -> String {
        "thought-\(assistantMessageSequence)-\(contentIndex)-\(fallbackSequence)"
    }

    private func captureTerminalStatus(_ message: [String: Any]) {
        let error = string(message["errorMessage"])
        latestTerminalError = error
        switch string(message["stopReason"])?.lowercased() {
        case "length", "max_tokens", "max-tokens":
            latestStopReason = .maxTokens
        case "aborted", "cancelled", "canceled":
            latestStopReason = .cancelled
        case "refusal", "refused":
            latestStopReason = .refusal
        default:
            latestStopReason = .endTurn
        }
    }

    private static func assistantText(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        guard let content = message["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { block in
            string(block["type"]) == "text" ? block["text"] as? String : nil
        }.joined()
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}

private final class PiRPCProcessRegistry: @unchecked Sendable {
    static let shared = PiRPCProcessRegistry()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func register(_ process: Process) {
        lock.withLock { processes[ObjectIdentifier(process)] = process }
    }

    func unregister(_ process: Process) {
        _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(process)) }
    }

    func terminateAll() {
        let active = lock.withLock {
            let values = Array(processes.values)
            processes.removeAll()
            return values
        }
        for process in active where process.isRunning {
            terminateLocalACPProcessGroup(process, signal: SIGTERM)
        }
    }
}

extension PiRPCClient {
    public nonisolated static func terminateAllProcesses() {
        PiRPCProcessRegistry.shared.terminateAll()
    }
}

private func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func array(_ value: Any?) -> [Any]? {
    value as? [Any]
}

private func string(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
