import Foundation
import WovenMatterCore

/// Adapts the native Hermes Gateway to Woven Matter's existing composer and transcript.
/// Persisted identities include the profile home; runtime session IDs never reach the database.
public actor HermesGatewayClient {
    private let launch: LocalACPRuntimeLaunchConfiguration
    private var rpc: HermesGatewayRPC?
    private var sessionID = ""
    private var storedID = ""
    private var home = ""
    private var sequence: Double = 0
    private var epoch: String?
    private var configuration = LocalACPSessionConfiguration.empty
    private var onEvent: LocalACPClient.EventHandler?
    private var onPermission: LocalACPClient.PermissionHandler?
    private var onInteraction: LocalACPClient.InteractionHandler?
    private var terminal: Result<LocalACPStopReason, any Error>?
    private var completion: CheckedContinuation<LocalACPStopReason, any Error>?
    private var busy = false
    private var stopped = false
    private var imported = false
    private var closed = false
    private var recoveryInvalidated = false
    private var text = ""
    private var completedText = ""
    private var workingDirectory: URL?
    private var latestUsage: HermesValue = [:]
    private var usageBaseline: HermesValue = [:]
    private var initialContext: String?
    private var replaying = false
    private var buffered: [HermesValue] = []
    private var interactionTasks: [String: Task<Void, Never>] = [:]
    private var heartbeat: Task<Void, Never>?

    public init(launch: LocalACPRuntimeLaunchConfiguration) { self.launch = launch }

    public static func identity(home: String, storedID: String, imported: Bool = false) -> String {
        (imported ? "hermes-import:" : "hermes-gateway:") + Data(home.utf8).base64EncodedString() + ":" + storedID
    }
    public static func parseIdentity(_ value: String) -> (home: String?, storedID: String) {
        guard value.hasPrefix("hermes-gateway:") || value.hasPrefix("hermes-import:") else { return (nil, value) }
        let pieces = value.split(separator: ":", maxSplits: 2).map(String.init)
        guard pieces.count == 3, let bytes = Data(base64Encoded: pieces[1]),
              let home = String(data: bytes, encoding: .utf8), home.hasPrefix("/"), !pieces[2].isEmpty else { return (nil, "") }
        return (home, pieces[2])
    }

    public func initializeSession(workingDirectory: URL, existingSessionID: String?, title: String?, systemPrompt: String?) async throws -> LocalACPInitializedSession {
        recoveryInvalidated = true
        self.workingDirectory = workingDirectory
        heartbeat?.cancel(); heartbeat = nil
        await rpc?.setHandlers(event: nil)
        await rpc?.disconnect()
        imported = existingSessionID?.hasPrefix("hermes-import:") == true
        let previous = existingSessionID.map(Self.parseIdentity)
        if previous?.storedID == "" { throw HermesGatewayError.message("The saved Hermes conversation identity is invalid.") }
        var environment = launch.environment
        if let pinnedHome = previous?.home { environment["HERMES_HOME"] = pinnedHome }
        let scoped = LocalACPRuntimeLaunchConfiguration(runtimeKind: .hermes, executableURL: launch.executableURL,
            arguments: launch.arguments, environment: environment)
        let connection = try await HermesGatewayService.shared.ensure(launch: scoped)
        home = connection.home
        let client = HermesGatewayRPC(connection: connection)
        rpc = client
        await client.setHandlers(event: { [weak self] event in await self?.receive(event) }, disconnected: { [weak self] in await self?.recover() })
        try await client.connect()
        epoch = await client.epoch
        var params: HermesValue = ["source": "desktop", "close_on_disconnect": .bool(false)]
        if previous == nil { params["cwd"] = .string(workingDirectory.path); params["lazy"] = .bool(true) }
        if let title { params["title"] = .string(title) }
        let snapshot: HermesValue
        if let previous {
            params["session_id"] = .string(previous.storedID)
            snapshot = try await client.call("session.resume", params)
        } else {
            snapshot = try await client.call("session.create", params)
            // Same ACP v1 compatibility behavior: agent instructions accompany the first user turn.
            initialContext = systemPrompt
        }
        try bind(snapshot, requestedStoredID: previous?.storedID)
        guard !snapshot["running"].bool else { throw HermesGatewayError.message("This Hermes conversation is already running. Wait for its current turn before continuing it here.") }
        let replay = try await client.call("session.events.since", ["session_id": .string(sessionID), "last_seen": .number(0)])
        sequence = replay["latest_seq"].number ?? 0
        // Existing sessions keep their durable history, but Woven sessions follow their selected workspace.
        if !imported {
            _ = try await client.call("session.cwd.set", ["session_id": .string(sessionID), "cwd": .string(workingDirectory.path)])
        }
        try await refreshConfiguration()
        recoveryInvalidated = false
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                await self?.ping()
            }
        }
        return LocalACPInitializedSession(sessionID: Self.identity(home: home, storedID: storedID, imported: imported),
            loadedExistingSession: previous != nil, configuration: configuration)
    }

    private func bind(_ snapshot: HermesValue, requestedStoredID: String? = nil) throws {
        guard let live = snapshot["session_id"].string, !live.isEmpty,
              let stored = snapshot["stored_session_id"].string ?? snapshot["session_key"].string, !stored.isEmpty else {
            throw HermesGatewayError.message("Hermes did not return both runtime and durable conversation identities.")
        }
        if let requestedStoredID, stored != requestedStoredID {
            // Non-lazy native resume may follow a compression tip. Require the explicit
            // resolution acknowledgement and retain the original durable association.
            guard snapshot["resumed"].text == stored else {
                throw HermesGatewayError.message("Hermes resumed an unexpected conversation identity.")
            }
        }
        sessionID = live; storedID = requestedStoredID ?? stored
        let info = snapshot["info"]
        if !info["usage"].isNull { latestUsage = info["usage"] }
        configuration = LocalACPSessionConfiguration(model: info["model"].string, thinking: info["reasoning_effort"].string,
            modelOptions: configuration.modelOptions, thinkingOptions: configuration.thinkingOptions, slashCommands: configuration.slashCommands)
    }

    public func sessionConfiguration() -> LocalACPSessionConfiguration { configuration }

    public func setSessionConfiguration(model: String?, thinking: String?) async throws -> LocalACPSessionConfiguration {
        guard let rpc else { throw HermesGatewayError.message("Hermes is disconnected.") }
        for (key, value) in [("model", model), ("reasoning", thinking)] {
            guard let value, !value.isEmpty else { continue }
            let response = try await rpc.call("config.set", ["session_id": .string(sessionID), "key": .string(key), "value": .string(value), "scope": "session"])
            if response["confirm_required"].bool {
                throw HermesGatewayError.message(response["confirm_message"].string ?? "Hermes requires confirmation for this model. Select it in Hermes before reconnecting.")
            }
            configuration = LocalACPSessionConfiguration(model: key == "model" ? value : configuration.model,
                thinking: key == "reasoning" ? value : configuration.thinking,
                modelOptions: configuration.modelOptions, thinkingOptions: configuration.thinkingOptions, slashCommands: configuration.slashCommands)
        }
        try await refreshConfiguration()
        return configuration
    }

    private func refreshConfiguration() async throws {
        guard let rpc else { return }
        let reasoning = try await rpc.call("config.get", ["session_id": .string(sessionID), "key": "reasoning"])
        let options = try await rpc.call("model.options", ["session_id": .string(sessionID), "explicit_only": .bool(true)])
        let models = options["providers"].array.flatMap { provider in
            provider["models"].array.compactMap(\.string).map { model in
                let providerID = provider["slug"].text
                return providerID.isEmpty ? model : model + " --provider " + providerID
            }
        }
        let currentModel = options["model"].string ?? configuration.model ?? ""
        let provider = options["provider"].text
        let capabilities = options["providers"].array.first { $0["slug"].text == provider }?["capabilities"][currentModel] ?? .null
        var efforts = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        if capabilities["reasoning"] == .bool(false) { efforts = [] }
        else if capabilities["can_disable_reasoning"] != .bool(false) { efforts.insert("none", at: 0) }
        let catalog = try? await rpc.call("commands.catalog", ["session_id": .string(sessionID)])
        configuration = LocalACPSessionConfiguration(model: provider.isEmpty ? currentModel : currentModel + " --provider " + provider,
            thinking: reasoning["value"].string, modelOptions: models, thinkingOptions: efforts,
            slashCommands: catalog.map(HermesSlashCommands.catalog) ?? configuration.slashCommands)
    }

    public func prompt(_ input: AgentMessageInput, onEvent: LocalACPClient.EventHandler?,
                       onPermission: LocalACPClient.PermissionHandler?, onInteraction: LocalACPClient.InteractionHandler?) async throws -> LocalACPStopReason {
        guard !closed, !busy, !replaying, !sessionID.isEmpty else { throw HermesGatewayError.message("Hermes is busy or disconnected.") }
        let connected = await rpc?.isConnected == true
        if (recoveryInvalidated || !connected), let workingDirectory {
            _ = try await initializeSession(workingDirectory: workingDirectory,
                existingSessionID: Self.identity(home: home, storedID: storedID, imported: imported), title: nil, systemPrompt: nil)
        }
        guard let rpc else { throw HermesGatewayError.message("Hermes is disconnected.") }
        self.onEvent = onEvent; self.onPermission = onPermission; self.onInteraction = onInteraction
        busy = true; terminal = nil; text = ""; completedText = ""; stopped = false
        usageBaseline = latestUsage
        defer { busy = false; self.onEvent = nil; self.onPermission = nil; self.onInteraction = nil }
        var content = input.transportText()
        if HermesSlashCommands.name(in: input.text).map({ name in
            configuration.slashCommands.contains { $0.name == name }
        }) == true {
            guard input.attachments.isEmpty else {
                throw AgentMessageAttachmentError.unsupportedForAgent("Hermes slash commands accept text arguments. Remove attachments before running this command.")
            }
            let result = try await HermesSlashCommands.dispatch(input.text, sessionID: sessionID) { method, params in
                try await rpc.call(method, params)
            }
            switch result["type"].text {
            case "send", "skill":
                guard let message = result["message"].string else {
                    throw HermesGatewayError.message("Hermes returned a command without its message.")
                }
                content = message
            case "prefill":
                guard let message = result["message"].string else {
                    throw HermesGatewayError.message("Hermes returned a command without its draft.")
                }
                try await onEvent?(.composerPrefill(message))
                if let notice = result["notice"].string, !notice.isEmpty {
                    try await onEvent?(.assistantSnapshot(notice))
                }
                return .endTurn
            case "", "exec", "plugin":
                let output = [result["output"].string, result["warning"].string, result["notice"].string]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !output.isEmpty { try await onEvent?(.assistantSnapshot(output)) }
                try? await refreshConfiguration()
                return .endTurn
            default:
                throw HermesGatewayError.message("Hermes returned an unsupported command outcome.")
            }
        }
        if let initialContext, !initialContext.isEmpty { content = initialContext + "\n\n" + content }
        for file in input.files {
            let method = file.kind == .image ? "image.attach" : "file.attach"
            let attached = try await rpc.call(method, ["session_id": .string(sessionID), "path": .string(file.localURL.path), "name": .string(file.fileName)])
            if let reference = attached["ref_text"].string { content += "\n" + reference }
        }
        do {
            _ = try await rpc.call("prompt.submit", ["session_id": .string(sessionID), "text": .string(content)])
            initialContext = nil
            if let terminal { return try terminal.get() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { completion = $0 }
            } onCancel: { Task { try? await self.cancel() } }
        } catch { finish(.failure(error)); throw error }
    }

    public func steer(_ input: AgentMessageInput) async throws {
        guard busy, let rpc else { throw HermesGatewayError.message("Hermes has no active turn to steer.") }
        guard input.files.isEmpty else { throw AgentMessageAttachmentError.unsupportedForAgent("Hermes steering accepts text and references. Send files with the next turn.") }
        let receipt = try await rpc.call("session.steer", ["session_id": .string(sessionID), "text": .string(input.transportText())])
        guard receipt["status"].text == "queued" else { throw HermesGatewayError.message("Hermes did not accept this steering input.") }
    }

    public func cancel() async throws {
        guard let rpc, busy else { return }
        stopped = true
        _ = try await rpc.call("session.interrupt", ["session_id": .string(sessionID)])
        // Completion comes from message.complete, never from terminating the service.
    }

    public func shutdown() async {
        closed = true
        heartbeat?.cancel(); heartbeat = nil
        for task in interactionTasks.values { task.cancel() }; interactionTasks.removeAll()
        if busy { try? await cancel() }
        await rpc?.setHandlers(event: nil)
        await rpc?.disconnect(); rpc = nil
        finish(.failure(CancellationError()))
    }

    public func history() async throws -> [HermesValue] {
        guard let rpc else { throw HermesGatewayError.message("Hermes is disconnected.") }
        return try await rpc.call("session.history", ["session_id": .string(sessionID)])["messages"].array
    }

    private func ping() async {
        guard !recoveryInvalidated, let rpc else { return }
        do { _ = try await rpc.call("ping") }
        catch { await recover() }
    }

    private func recover() async {
        guard !closed, !recoveryInvalidated, !replaying, let rpc, !storedID.isEmpty else { return }
        replaying = true; buffered = []
        defer { replaying = false }
        do {
            await rpc.disconnect()
            try await rpc.connect()
            guard !closed else { await rpc.disconnect(); return }
            let newEpoch = await rpc.epoch
            let oldSession = sessionID
            let requested = storedID
            let snapshot = try await rpc.call("session.resume", ["session_id": .string(requested)])
            try bind(snapshot, requestedStoredID: requested)
            guard newEpoch == epoch, sessionID == oldSession else {
                epoch = newEpoch; sequence = 0; buffered = []
                throw HermesGatewayError.message("Hermes Gateway restarted. Conversation history is preserved; review it before continuing this interrupted turn.")
            }
            let replay = try await rpc.call("session.events.since", ["session_id": .string(sessionID), "last_seen": .number(sequence)])
            guard !replay["truncated"].bool, replay["epoch"].string == epoch else {
                throw HermesGatewayError.message("Hermes event history no longer covers this interruption. The conversation is preserved in Hermes; input has not been resent.")
            }
            let events = replay["events"].array.map { $0["params"].isNull ? $0 : $0["params"] } + buffered
            buffered = []
            var pending = events
            while !pending.isEmpty && !closed {
                for event in pending.sorted(by: { ($0["seq"].number ?? 0) < ($1["seq"].number ?? 0) }) { await apply(event) }
                pending = buffered; buffered = []
            }
        } catch {
            recoveryInvalidated = true
            heartbeat?.cancel(); heartbeat = nil
            buffered = []
            await rpc.disconnect()
            if busy { finish(.failure(error)) }
        }
    }

    private func receive(_ event: HermesValue) async {
        guard !recoveryInvalidated, event["session_id"].text == sessionID, !sessionID.isEmpty else { return }
        if replaying { buffered.append(event); return }
        await apply(event)
    }

    private func apply(_ event: HermesValue) async {
        if let seq = event["seq"].number {
            guard seq > sequence else { return }
            sequence = seq
        }
        let payload = event["payload"]
        do {
            switch event["type"].text {
            case "message.delta":
                guard busy else { return }
                let delta = payload["text"].text; text += delta
                try await onEvent?(.assistantChunk(delta))
            case "message.interim":
                guard busy else { return }
                let interim = payload["text"].text
                completedText += interim + "\n\n"
                try await onEvent?(.assistantSnapshot(completedText))
                text = ""
            case "message.complete":
                guard busy else { return }
                let final = payload["text"].text
                if !payload["response_previewed"].bool, !final.isEmpty || text.isEmpty {
                    try await onEvent?(.assistantSnapshot(completedText + final))
                }
                if let reasoning = payload["reasoning"].string, !reasoning.isEmpty {
                    try await onEvent?(.activity(AgentRunActivity(id: "hermes-thinking", kind: .thought, content: reasoning, contentIsDelta: false), appendsContent: false))
                }
                if !payload["usage"].isNull {
                    let usage = payload["usage"]
                    func delta(_ key: String) -> Int64 {
                        let value = max(0, (usage[key].number ?? 0) - (usageBaseline[key].number ?? 0))
                        return Int64(min(value, 9_007_199_254_740_991))
                    }
                    try await onEvent?(.usage(UsageTokenCounts(inputTokens: delta("input"), outputTokens: delta("output"), reasoningTokens: delta("reasoning"), reportedTotalTokens: delta("total"))))
                    latestUsage = usage
                }
                if payload["status"].text == "error" {
                    finish(.failure(HermesGatewayError.message(payload["error"].string ?? "Hermes turn failed.")))
                } else { finish(.success(stopped || payload["status"].text == "interrupted" ? .cancelled : .endTurn)) }
            case "session.info":
                if !payload["usage"].isNull { latestUsage = payload["usage"] }
            case "reasoning.delta", "thinking.delta":
                try await onEvent?(.activity(AgentRunActivity(id: "hermes-thinking", kind: .thought, content: payload["text"].text, contentIsDelta: true), appendsContent: true))
            case "tool.start", "tool.complete":
                let complete = event["type"].text == "tool.complete"
                try await onEvent?(.activity(AgentRunActivity(id: payload["tool_id"].text, kind: .tool,
                    title: payload["name"].string, status: complete ? "completed" : "running", toolName: payload["name"].string,
                    content: complete ? payload["result_text"].string ?? payload["result"].json : payload["context"].string,
                    rawInputJSON: payload["args"].isNull ? nil : payload["args"].json), appendsContent: false))
            case "approval.request", "clarify.request", "sudo.request", "secret.request":
                beginInteraction(event["type"].text, payload)
            case "clarify.expire", "sudo.expire", "secret.expire":
                interactionTasks.removeValue(forKey: payload["request_id"].text)?.cancel()
            default: break
            }
        } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<LocalACPStopReason, any Error>) {
        guard terminal == nil else { return }
        terminal = result
        for task in interactionTasks.values { task.cancel() }; interactionTasks.removeAll()
        let waiting = completion; completion = nil
        waiting?.resume(with: result)
    }

    private func beginInteraction(_ type: String, _ payload: HermesValue) {
        let id = payload["request_id"].text
        guard !id.isEmpty, interactionTasks[id] == nil else { return }
        interactionTasks[id] = Task { [weak self] in await self?.respond(type, payload) }
    }
    private func respond(_ type: String, _ payload: HermesValue) async {
        let id = payload["request_id"].text
        defer { interactionTasks[id] = nil }
        guard let rpc else { return }
        var params: HermesValue = ["session_id": .string(sessionID), "request_id": .string(id)]
        do {
            if type == "approval.request" {
                let choices = payload["choices"].array.compactMap(\.string)
                let offered = choices.isEmpty ? ["once", "deny"] : choices
                let selected = await onPermission?(LocalACPPermissionRequest(title: payload["description"].text + "\n" + payload["command"].text,
                    options: offered.map { LocalACPPermissionOption(id: $0, name: $0, kind: $0 == "deny" ? "reject_once" : $0 == "always" ? "allow_always" : "allow_once") }))
                params["choice"] = .string(selected.flatMap { offered.contains($0) ? $0 : nil } ?? "deny")
                _ = try await rpc.call("approval.respond", params)
            } else if type == "clarify.request" {
                let batch = payload["questions"].array
                let questions = (batch.isEmpty ? [payload] : batch).enumerated().map { index, question in
                    LocalACPQuestion(id: question["qid"].string ?? String(index), prompt: question["question"].text,
                        options: question["choices"].array.compactMap(\.string).map { LocalACPQuestionOption(id: $0, label: $0) }, allowsMultiple: question["multi_select"].bool)
                }
                let response = await onInteraction?(.questions(LocalACPQuestionRequest(questions: questions)))
                let answers: [String: LocalACPQuestionAnswer]
                if case .answers(let values) = response { answers = values } else { answers = [:] }
                for question in questions {
                    if !batch.isEmpty { params["question_id"] = .string(question.id) }
                    switch answers[question.id] {
                    case .single(let value): params["answer"] = .string(value)
                    case .multiple(let values): params["answer"] = .string(values.joined(separator: ", "))
                    case nil: params["answer"] = ""
                    }
                    _ = try await rpc.call("clarify.respond", params)
                }
            } else {
                let prompt = type == "sudo.request" ? "Hermes requests your sudo password" : payload["prompt"].text
                let answer = await onInteraction?(.secret(prompt: prompt))
                if Task.isCancelled { return }
                if case .secret(let value) = answer { params[type == "sudo.request" ? "password" : "value"] = .string(value) }
                else { params[type == "sudo.request" ? "password" : "value"] = "" }
                _ = try await rpc.call(type == "sudo.request" ? "sudo.respond" : "secret.respond", params)
            }
        } catch { finish(.failure(error)) }
    }
}
