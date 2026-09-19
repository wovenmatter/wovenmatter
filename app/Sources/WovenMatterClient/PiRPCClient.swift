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
    case processExited(String? = nil)
    case invalidResponse(String)
    case commandFailed(String)
    case sessionNotInitialized
    case timedOut

    public var errorDescription: String? {
        switch self {
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
    private var configuration = LocalACPSessionConfiguration.empty
    private var pendingResponses: [String: CheckedContinuation<[String: Any], any Error>] = [:]
    private var promptEvents: LocalACPClient.EventHandler?
    private var promptPermission: LocalACPClient.PermissionHandler?
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
    private var settlement: Result<Void, any Error>?
    private var transportError: (any Error)?
    private var settledWaiters: [CheckedContinuation<Void, any Error>] = []
    private var cancelled = false
    private var abortTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private struct ExtensionUIRequest: Sendable {
        let id: String
        let method: String?
        let title: String
        let options: [LocalACPPermissionOption]
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
        return LocalACPInitializedSession(
            sessionID: sessionID,
            loadedExistingSession: existingSessionID != nil,
            configuration: configuration
        )
    }

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

    public func prompt(
        _ text: String,
        onEvent: LocalACPClient.EventHandler? = nil,
        onPermission: LocalACPClient.PermissionHandler? = nil
    ) async throws -> LocalACPStopReason {
        try Task.checkCancellation()
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
        defer {
            promptGeneration = nil
            promptEvents = nil
            promptPermission = nil
        }
        return try await withTaskCancellationHandler {
            do {
                let response = try await sendCommand([
                    "type": "prompt",
                    "message": text,
                ])
                if response["success"] as? Bool != true {
                    throw PiRPCClientError.commandFailed(
                        string(response["error"]) ?? "Pi rejected the prompt."
                    )
                }
                promptAcknowledged = true
                try Task.checkCancellation()
                try await settleHandledInputIfIdle()
                try await waitUntilSettled()
                await abortTask?.value
                if let latestTerminalError {
                    throw PiRPCClientError.commandFailed(latestTerminalError)
                }
                return cancelled ? .cancelled : (latestStopReason ?? .endTurn)
            } catch {
                failSettledWaiters(error)
                throw error
            }
        } onCancel: {
            Task { await self.cancelPromptTask(generation: generation) }
        }
    }

    public func steer(_ text: String) async throws {
        let response = try await sendCommand([
            "type": "steer",
            "message": text,
        ])
        guard response["success"] as? Bool == true else {
            throw PiRPCClientError.commandFailed(
                string(response["error"])
                    ?? "Pi could not steer the active turn."
            )
        }
    }

    public func cancel() async {
        cancelled = true
        guard promptAcknowledged else {
            // Abort only stops native agent work, not an extension command that
            // is still awaiting a UI decision. Retire that transport so its late
            // ACK/output cannot leak into a subsequent run. The coordinator
            // recreates the same durable session after this cancellation error.
            failPending(CancellationError())
            await shutdown()
            return
        }
        if let abortTask {
            await abortTask.value
            return
        }
        let task = Task {
            do {
                _ = try await self.sendCommand(["type": "abort"])
                // Drain prior output before the session can accept another run.
                await self.eventTask?.value
                if !self.sawAgentStart { self.finishSettledWaiters() }
            } catch {
                self.failPending(error)
            }
        }
        abortTask = task
        await task.value
    }

    private func cancelPromptTask(generation: UUID) async {
        guard promptGeneration == generation else { return }
        failPending(CancellationError())
        await shutdown()
    }

    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !closed else { return }
        closed = true
        failPending(PiRPCClientError.processExited())
        readerTask?.cancel()
        eventTask?.cancel()
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
    }

    private func spawn(sessionID: String?) throws {
        guard !closed else { throw PiRPCClientError.processExited() }
        guard process == nil, input == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        var arguments = [
            "-c",
            #"set -m; exec "$@""#,
            "wovenmatter-local-pi",
            launch.executableURL.path,
        ] + launch.arguments
        if let sessionID, !sessionID.isEmpty {
            arguments += ["--session", sessionID]
        }
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
                guard let line = try await cursor.next() else { break }
                try await handleLine(line)
            }
        } catch {
            failPending(error)
        }
        guard !closed else { return }
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
        try launch.historyRecorder?("in", line)
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw PiRPCClientError.invalidResponse("expected JSON object")
        }
        let type = string(object["type"])
        if type == "response" {
            let id = string(object["id"]) ?? ""
            if let waiter = pendingResponses.removeValue(forKey: id) {
                waiter.resume(returning: object)
            }
            return
        }
        let events = projectedEvents(from: object)
        let extensionRequest = type == "extension_ui_request"
            ? Self.extensionUIRequest(from: object)
            : nil
        guard extensionRequest != nil
                || type == "agent_settled"
                || !events.isEmpty else { return }
        if type == "agent_settled" { hasQueuedSettlement = true }
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
                        await self.finishSettledWaiters()
                    }
                }
            } catch {
                await self.failPending(error)
            }
        }
    }

    private func refreshConfiguration() async throws {
        let state = try await sendCommand(["type": "get_state"])
        let models = try await sendCommand(["type": "get_available_models"])
        let thinking = try await sendCommand(["type": "get_available_thinking_levels"])
        let commands = try await sendCommand(["type": "get_commands"])
        let data = dictionary(state["data"])
        sessionID = string(data?["sessionId"]) ?? string(data?["session_id"]) ?? sessionID
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

    private func sendCommand(_ payload: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        if let transportError { throw transportError }
        guard !closed, let input else {
            throw PiRPCClientError.sessionNotInitialized
        }
        nextID += 1
        let id = "wm-\(nextID)"
        var body = payload
        body["id"] = id
        let data = try JSONSerialization.data(withJSONObject: body)
        try launch.historyRecorder?("out", data)
        var line = data
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], any Error>) in
            pendingResponses[id] = continuation
            do {
                try input.write(contentsOf: line)
            } catch {
                pendingResponses.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func settleHandledInputIfIdle() async throws {
        guard !sawAgentStart, !hasQueuedSettlement, settlement == nil else { return }
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
        guard !sawAgentStart, !hasQueuedSettlement else { return }
        finishSettledWaiters()
    }

    private func waitUntilSettled() async throws {
        if let settlement { return try settlement.get() }
        try await withCheckedThrowingContinuation { continuation in
            settledWaiters.append(continuation)
        }
    }

    private func finishSettledWaiters() {
        guard settlement == nil else { return }
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
        for waiter in pending.values {
            waiter.resume(throwing: error)
        }
        failSettledWaiters(error)
    }

    private nonisolated static func extensionUIRequest(
        from object: [String: Any]
    ) -> ExtensionUIRequest? {
        guard let id = string(object["id"]) else { return nil }
        let method = string(object["method"])
        if method == "notify"
            || method == "setStatus"
            || method == "setWidget"
            || method == "setTitle"
            || method == "set_editor_text" {
            return nil
        }
        let options: [LocalACPPermissionOption]
        if method == "confirm" {
            options = [
                LocalACPPermissionOption(id: "allow", name: "Allow", kind: "allow_once"),
                LocalACPPermissionOption(id: "reject", name: "Reject", kind: "reject_once"),
            ]
        } else if let raw = array(object["options"]) {
            options = raw.compactMap { value in
                let name = (value as? String)
                    ?? string((value as? [String: Any])?["label"])
                    ?? string((value as? [String: Any])?["name"])
                guard let name else { return nil }
                return LocalACPPermissionOption(id: name, name: name, kind: "allow_once")
            }
        } else {
            options = [
                LocalACPPermissionOption(id: "allow", name: "Allow", kind: "allow_once"),
                LocalACPPermissionOption(id: "reject", name: "Reject", kind: "reject_once"),
            ]
        }
        let title = string(object["title"])
            ?? string(object["message"])
            ?? "Pi is requesting a decision."
        return ExtensionUIRequest(
            id: id,
            method: method,
            title: title,
            options: options
        )
    }

    private func handleExtensionUI(
        _ request: ExtensionUIRequest
    ) async throws {
        let selected = await promptPermission?(
            LocalACPPermissionRequest(
                title: request.title,
                options: request.options
            )
        )
        var payload: [String: Any] = [
            "type": "extension_ui_response",
            "id": request.id,
        ]
        if selected == nil || selected == "reject" {
            payload["cancelled"] = true
            if request.method == "confirm" {
                payload["confirmed"] = false
            }
        } else if request.method == "confirm" {
            payload["confirmed"] = true
        } else {
            payload["value"] = selected
        }
        guard let input else { return }
        var data = try JSONSerialization.data(withJSONObject: payload)
        try launch.historyRecorder?("out", data)
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
            return []
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
