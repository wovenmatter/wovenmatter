import Foundation
import WovenMatterCore

/// Adapts the native Hermes Gateway to Woven Matter's existing composer and transcript.
/// Persisted identities include the profile home; runtime session IDs never reach the database.
public actor HermesGatewayClient {
    private let launch: LocalACPRuntimeLaunchConfiguration
    private var remoteConnection: HermesGatewayConnection?
    private var rpc: (any HermesGatewayTransport)?
    private let connectTransport: @Sendable (LocalACPRuntimeLaunchConfiguration) async throws -> (String, any HermesGatewayTransport)
    private var cliPluginReady = false
    private var sessionID = ""
    private var storedID = ""
    private var resolvedStoredID = ""
    private var runID: String?
    private var archivedNativeHighWater: [String: Int64] = [:]
    private var home = ""
    private var sequence: Double = 0
    private var epoch: String?
    private var configuration = LocalACPSessionConfiguration.empty
    private var permissionInfo: HermesValue = .null
    private var inheritedPermissionMode: String?
    private var permissionChangeInFlight = false
    private var confirmedPermissionOverride: String?
    private var permissionDowngradeUnavailable = false
    private var onEvent: LocalACPClient.EventHandler?
    private var onPermission: LocalACPClient.PermissionHandler?
    private var onInteraction: LocalACPClient.InteractionHandler?
    private var terminal: Result<LocalACPStopReason, any Error>?
    private var completion: CheckedContinuation<LocalACPStopReason, any Error>?
    private var busy = false
    private var stopped = false
    private var pendingDispatches: [ObjectIdentifier: AgentDispatchFence] = [:]
    private var imported = false
    private var closed = false
    private var recoveryInvalidated = false
    private var text = ""
    private var completedText = ""
    private var reasoningPhase = 0
    private var activeReasoningID: String?
    private var lastReasoningID: String?
    private var lastReasoningText = ""
    private var workingDirectory: URL?
    private var latestUsage: HermesValue = [:]
    private var usageBaseline: HermesValue = [:]
    private var initialContext: String?
    private var replaying = false
    private var buffered: [HermesValue] = []
    private var interactionFences: [String: AgentDispatchFence] = [:]
    private var interactionTasks: [String: Task<Void, Never>] = [:]
    private var heartbeat: Task<Void, Never>?
    private var nativeArchiveTask: Task<Void, Never>?
    private var nativeArchiveToken: UUID?

    public init(launch: LocalACPRuntimeLaunchConfiguration) {
        self.launch = launch
        self.remoteConnection = Self.remoteConnection(in: launch)
        self.connectTransport = { scoped in
            let connection = try await HermesGatewayService.shared.ensure(launch: scoped)
            return (connection.identityHome, HermesGatewayRPC(connection: connection, historyRecorder: scoped.historyRecorder))
        }
    }

    init(launch: LocalACPRuntimeLaunchConfiguration, transport: any HermesGatewayTransport, home: String) {
        self.launch = launch
        self.remoteConnection = Self.remoteConnection(in: launch)
        self.connectTransport = { _ in (home, transport) }
    }

    private static func remoteConnection(in launch: LocalACPRuntimeLaunchConfiguration) -> HermesGatewayConnection? {
        guard let encoded = launch.environment["WOVENMATTER_HERMES_CONNECTION"],
              let bytes = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(HermesGatewayConnection.self, from: bytes)
    }

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
        let priorArchive = nativeArchiveTask
        nativeArchiveToken = nil; nativeArchiveTask = nil
        priorArchive?.cancel()
        await priorArchive?.value
        permissionInfo = .null
        inheritedPermissionMode = nil
        permissionDowngradeUnavailable = false
        self.workingDirectory = workingDirectory
        heartbeat?.cancel(); heartbeat = nil
        await rpc?.setHandlers(event: nil, disconnected: nil, request: nil)
        await rpc?.disconnect()
        imported = existingSessionID?.hasPrefix("hermes-import:") == true
        let previous = existingSessionID.map(Self.parseIdentity)
        if previous?.storedID != storedID || (previous?.home != nil && previous?.home != home) {
            confirmedPermissionOverride = nil
        }
        if previous?.storedID == "" { throw HermesGatewayError.message("The saved Hermes conversation identity is invalid.") }
        var environment = launch.environment
        if let pinnedHome = previous?.home { environment["HERMES_HOME"] = pinnedHome }
        var scoped = LocalACPRuntimeLaunchConfiguration(runtimeKind: .hermes, executableURL: launch.executableURL,
            arguments: launch.arguments, environment: environment,
            environmentKeysToRemove: launch.environmentKeysToRemove,
            environmentKeyPrefixesToRemove: launch.environmentKeyPrefixesToRemove,
            processWorkingDirectoryURL: launch.processWorkingDirectoryURL)
        scoped.historyRecorder = launch.historyRecorder
        let (profileHome, client) = try await connectTransport(scoped)
        if let pinnedHome = previous?.home, pinnedHome != profileHome {
            throw HermesGatewayError.message("This conversation belongs to another Hermes profile or remote workspace. Reconnect its original workspace before continuing.")
        }
        home = profileHome
        rpc = client
        await client.setHandlers(event: { [weak self] event in await self?.receive(event) }, disconnected: { [weak self] in await self?.recover() },
            request: { [weak self] frame in await self?.receiveRequest(frame) })
        try await client.connect()
        epoch = await client.epoch
        var params: HermesValue = ["source": "desktop", "close_on_disconnect": .bool(false)]
        if previous == nil { params["cwd"] = .string(workingDirectory.path) }
        let snapshot: HermesValue
        if let previous {
            params["session_id"] = .string(previous.storedID)
            params["defer_history"] = .bool(true)
            snapshot = try await client.call("session.resume", params)
        } else {
            if let title { params["title"] = .string(title) }
            snapshot = try await client.call("session.create", params)
            // Same ACP v1 compatibility behavior: agent instructions accompany the first user turn.
            initialContext = systemPrompt
        }
        try bind(snapshot, requestedStoredID: previous?.storedID)
        try await prepareCLI(launch.cliConnection)
        if previous != nil { try await archiveNativeSession() }
        guard !snapshot["running"].bool else { throw HermesGatewayError.message("This Hermes conversation is already running. Wait for its current turn before continuing it here.") }
        let replay = try await client.call("session.events.since", ["session_id": .string(sessionID), "last_seen": .number(0)])
        if launch.historyRecorder != nil {
            for event in replay["events"].array { try await archiveEvent(event["params"].isNull ? event : event["params"]) }
        }
        sequence = replay["latest_seq"].number ?? 0
        // Existing sessions keep their durable history, but Woven sessions follow their selected workspace.
        if !imported {
            _ = try await client.call("session.cwd.set", ["session_id": .string(sessionID), "cwd": .string(workingDirectory.path)])
            configuration.workingDirectory = workingDirectory.path
        }
        try await refreshConfiguration()
        // Transport recovery may rebuild this native session internally, without
        // returning to the coordinator. Restore only an explicitly chosen mode.
        if let permission = confirmedPermissionOverride {
            _ = try await setSessionPermission(permission)
        }
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
        sessionID = live; storedID = requestedStoredID ?? stored; resolvedStoredID = stored
        let info = snapshot["info"]
        updatePermissionInfo(info)
        if !info["usage"].isNull { latestUsage = info["usage"] }
        configuration = LocalACPSessionConfiguration(model: info["model"].string, thinking: info["reasoning_effort"].string,
            modelOptions: configuration.modelOptions, thinkingOptions: configuration.thinkingOptions,
            slashCommands: configuration.slashCommands,
            modelOptionMetadata: configuration.modelOptionMetadata,
            thinkingOptionMetadata: configuration.thinkingOptionMetadata,
            permission: configuration.permission, permissionOptions: configuration.permissionOptions,
            permissionOptionMetadata: configuration.permissionOptionMetadata,
            workingDirectory: info["cwd"].string ?? snapshot["cwd"].string)
    }

    public func sessionConfiguration() -> LocalACPSessionConfiguration { configuration }
    public func setRunID(_ value: String) { runID = value }

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
                modelOptions: configuration.modelOptions, thinkingOptions: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: configuration.permission, permissionOptions: configuration.permissionOptions,
                permissionOptionMetadata: configuration.permissionOptionMetadata,
                workingDirectory: configuration.workingDirectory)
        }
        try await refreshConfiguration()
        return configuration
    }

    private func refreshConfiguration() async throws {
        guard let rpc else { return }
        let reasoning = try await rpc.call("config.get", ["session_id": .string(sessionID), "key": "reasoning"])
        let approvals = try? await rpc.call("config.get", ["session_id": .string(sessionID), "key": "approvals.mode"])
        inheritedPermissionMode = approvals?["value"].string ?? inheritedPermissionMode
        let options = try await rpc.call("model.options", ["session_id": .string(sessionID), "explicit_only": .bool(true)])
        let catalog = try? await rpc.call("commands.catalog", ["session_id": .string(sessionID)])
        let directory = configuration.workingDirectory
        // Initial create/resume can return before the agent's effective policy
        // is ready. Read it after catalog discovery without changing any flags.
        if let snapshot = try? await rpc.call("session.activate", ["session_id": .string(sessionID), "omit_messages": .bool(true)]),
           snapshot["session_id"].text == sessionID {
            updatePermissionInfo(snapshot["info"])
        }
        configuration = Self.configuration(
            options: options,
            reasoning: reasoning,
            slashCommands: catalog.map(HermesSlashCommands.catalog) ?? configuration.slashCommands
        )
        configuration.workingDirectory = directory
        applyPermissionConfiguration()
    }

    /// Changes only this session's native YOLO flag. The inherited approval mode
    /// is read-only: changing approvals.mode would affect other conversations.
    public func setSessionPermission(_ permission: String) async throws -> LocalACPSessionConfiguration {
        guard !permissionChangeInFlight, !closed, !sessionID.isEmpty, let rpc else {
            throw HermesGatewayError.message("Hermes is busy or disconnected.")
        }
        guard ["default", "full"].contains(permission) else {
            throw HermesGatewayError.message("This Hermes permission mode is not supported.")
        }
        permissionChangeInFlight = true
        defer { permissionChangeInFlight = false }
        let target = sessionID
        // Settings or another native client may have changed the profile since
        // the last event. Do not let stale inherited `off` hide a valid downgrade.
        let current = try await rpc.call("session.activate", ["session_id": .string(target), "omit_messages": .bool(true)])
        guard sessionID == target, !closed, current["session_id"].text == target else { throw CancellationError() }
        updatePermissionInfo(current["info"])
        if permission == "default", inheritedPermissionMode == "off" || permissionDowngradeUnavailable {
            throw HermesGatewayError.message("Hermes has full access enabled in its inherited policy. Change that policy in Settings before lowering access for this conversation.")
        }
        let response = try await rpc.call("config.set", ["session_id": .string(target), "key": "yolo",
            "value": permission == "full" ? "1" : "0", "scope": "session"])
        guard sessionID == target, !closed else { throw CancellationError() }
        guard response["scope"].text == "session", response["value"].text == (permission == "full" ? "1" : "0") else {
            throw HermesGatewayError.message("Hermes did not confirm the session permission override.")
        }
        // A successful flag write is not sufficient: global/process YOLO can
        // still force full access. Read the live session's effective policy.
        let snapshot = try await rpc.call("session.activate", ["session_id": .string(target), "omit_messages": .bool(true)])
        guard sessionID == target, !closed, snapshot["session_id"].text == target else { throw CancellationError() }
        permissionInfo = snapshot["info"]
        updatePermissionInfo(permissionInfo)
        if permission == "default", permissionInfo["yolo"] == .bool(true) {
            permissionDowngradeUnavailable = true
            applyPermissionConfiguration()
            throw HermesGatewayError.message("Hermes still reports full access from its inherited or process policy. This conversation has not switched to approvals.")
        }
        guard configuration.permission == permission else {
            throw HermesGatewayError.message("Hermes has not reported the effective permission policy yet. Wait for it to finish preparing and try again.")
        }
        confirmedPermissionOverride = permission
        return configuration
    }

    private func updatePermissionInfo(_ info: HermesValue) {
        if !info["yolo"].isNull { permissionInfo = info }
        inheritedPermissionMode = info["approval_mode"].string ?? inheritedPermissionMode
        if info["yolo"] == .bool(false) { permissionDowngradeUnavailable = false }
        applyPermissionConfiguration()
    }

    private func applyPermissionConfiguration() {
        let state = HermesSessionPermissions.configuration(info: permissionInfo,
            inheritedMode: inheritedPermissionMode, downgradeUnavailable: permissionDowngradeUnavailable)
        configuration = LocalACPSessionConfiguration(model: configuration.model, thinking: configuration.thinking,
            modelOptions: configuration.modelOptions, thinkingOptions: configuration.thinkingOptions,
            slashCommands: configuration.slashCommands, modelOptionMetadata: configuration.modelOptionMetadata,
            thinkingOptionMetadata: configuration.thinkingOptionMetadata,
            permission: state.permission, permissionOptions: state.permissionOptions,
            permissionOptionMetadata: state.permissionOptionMetadata,
            workingDirectory: configuration.workingDirectory)
    }

    /// The Gateway accepts this native session vocabulary and normalizes it at
    /// each provider transport. `model.options` deliberately omits narrower
    /// wire effort sets because they under-report values Hermes can normalize.
    static func configuration(
        options: HermesValue,
        reasoning: HermesValue,
        slashCommands: [LocalACPSlashCommand] = []
    ) -> LocalACPSessionConfiguration {
        var models: [String] = []
        var metadata: [String: SessionOptionMetadata] = [:]
        for provider in options["providers"].array {
            let providerID = provider["slug"].text
            let providerName = provider["name"].string
            for model in provider["models"].array.compactMap(\.string) {
                let key = providerID.isEmpty ? model : model + " --provider " + providerID
                models.append(key)
                metadata[key] = SessionOptionMetadata(
                    name: model,
                    description: providerName
                )
            }
        }
        let currentModel = options["model"].string ?? ""
        let provider = options["provider"].text
        let selectedKey = provider.isEmpty ? currentModel : currentModel + " --provider " + provider
        let capabilities = options["providers"].array.first {
            $0["slug"].text == provider
        }?["capabilities"][currentModel] ?? .null
        let supportsReasoning = capabilities["reasoning"] != .bool(false)
        let currentReasoning = supportsReasoning ? reasoning["value"].string : nil
        var efforts: [String] = []
        if supportsReasoning {
            if capabilities["can_disable_reasoning"] != .bool(false) {
                efforts.append("none")
            }
            efforts += ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        }
        return LocalACPSessionConfiguration(
            model: selectedKey.isEmpty ? nil : selectedKey,
            thinking: currentReasoning,
            modelOptions: models,
            thinkingOptions: efforts,
            slashCommands: slashCommands,
            modelOptionMetadata: metadata
        )
    }

    private func prepareCLI(_ context: AgentCLIContext?, text: String? = nil, resetPending: Bool = false, removePending: Bool = false) async throws {
        guard let context, let rpc else { return }
        let pluginDirectory = URL(fileURLWithPath: home).appending(path: "plugins/wovenmatter-cli").path
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if !cliPluginReady {
            guard let resource = Bundle.main.resourceURL?.appending(path: "harnesses/cli/hermes.py") else {
                throw HermesGatewayError.message("The bundled Hermes CLI integration is missing.")
            }
            let source = try Data(contentsOf: resource).base64EncodedString()
            let install = #"""
            import base64,pathlib,sys
            root=pathlib.Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True,mode=0o700)
            source=base64.b64decode(sys.argv[2])
            file=root/'__init__.py'
            changed=not file.exists() or file.read_bytes()!=source
            if changed: file.write_bytes(source)
            (root/'plugin.yaml').write_text('name: wovenmatter-cli\nversion: 1.0.0\ndescription: Woven Matter session CLI integration\n')
            print('changed' if changed else 'ready')
            """#
            let result = try await rpc.callConfiguration("shell.exec", ["command": .string(
                ["python3", "-c", install, pluginDirectory, source].map(quote).joined(separator: " "))])
            guard result["code"].number == 0 else { throw HermesGatewayError.message("Could not install the Hermes CLI integration.") }
            if result["stdout"].text.contains("changed") {
                _ = try await rpc.callConfiguration("plugins.manage", ["action": "toggle", "name": "wovenmatter-cli", "enable": .bool(false)])
            }
            let activation = try await rpc.callConfiguration("plugins.manage", ["action": "toggle", "name": "wovenmatter-cli", "enable": .bool(true)])
            let live = activation["activation"]["activated_now"]["hooks"].array.compactMap(\.string)
            guard activation["unchanged"].bool || live.contains("pre_tool_call") else {
                throw HermesGatewayError.message("Hermes could not activate its Woven Matter CLI integration.")
            }
            cliPluginReady = true
        }
        let payload: HermesValue = ["context": try JSONDecoder().decode(HermesValue.self, from: JSONEncoder().encode(context)),
            "text": text.map(HermesValue.string) ?? .null, "resetPending": .bool(resetPending), "removePending": .bool(removePending)]
        let encoded = try JSONEncoder().encode(payload).base64EncodedString()
        let result = try await rpc.callConfiguration("shell.exec", ["command": .string(["python3", pluginDirectory + "/__init__.py", home, storedID, encoded].map(quote).joined(separator: " "))])
        guard result["code"].number == 0, result["stdout"].text.contains("ready") else {
            throw HermesGatewayError.message("Could not bind the Woven Matter CLI to this Hermes input.")
        }
    }

    public func prompt(_ input: AgentMessageInput, onEvent: LocalACPClient.EventHandler?,
                       onPermission: LocalACPClient.PermissionHandler?, onInteraction: LocalACPClient.InteractionHandler?,
                       dispatchFence: AgentDispatchFence? = nil) async throws -> LocalACPStopReason {
        let fence = dispatchFence ?? AgentDispatchFence()
        try fence.check()
        pendingDispatches[ObjectIdentifier(fence)] = fence
        defer { pendingDispatches[ObjectIdentifier(fence)] = nil }
        if let archive = nativeArchiveTask { await archive.value; nativeArchiveTask = nil }
        guard !closed, !busy, !replaying, !sessionID.isEmpty else { throw HermesGatewayError.message("Hermes is busy or disconnected.") }
        let connected = await rpc?.isConnected == true
        if (recoveryInvalidated || !connected), let workingDirectory {
            _ = try await initializeSession(workingDirectory: workingDirectory,
                existingSessionID: Self.identity(home: home, storedID: storedID, imported: imported), title: nil, systemPrompt: nil)
        }
        try fence.check()
        guard let rpc else { throw HermesGatewayError.message("Hermes is disconnected.") }
        self.onEvent = onEvent; self.onPermission = onPermission; self.onInteraction = onInteraction
        busy = true; terminal = nil; text = ""; completedText = ""; stopped = false; activeReasoningID = nil
        lastReasoningID = nil; lastReasoningText = ""
        usageBaseline = latestUsage
        defer { busy = false; self.onEvent = nil; self.onPermission = nil; self.onInteraction = nil; runID = nil }
        var content = input.transportText()
        if HermesSlashCommands.name(in: input.text).map({ name in
            configuration.slashCommands.contains { $0.name == name }
        }) == true {
            guard input.attachments.isEmpty else {
                throw AgentMessageAttachmentError.unsupportedForAgent("Hermes slash commands accept text arguments. Remove attachments before running this command.")
            }
            let result = try await HermesSlashCommands.dispatch(input.text, sessionID: sessionID) { method, params in
                try await rpc.call(method, params, dispatchFence: fence)
            }
            if stopped { return .cancelled }
            switch result["type"].text {
            case "send", "skill":
                guard let message = result["message"].string else {
                    throw HermesGatewayError.message("Hermes returned a command without its message.")
                }
                content = message
                try await publishCommandFeedback(result)
                if stopped { return .cancelled }
            case "prefill":
                guard let message = result["message"].string else {
                    throw HermesGatewayError.message("Hermes returned a command without its draft.")
                }
                try await onEvent?(.composerPrefill(message))
                try await publishCommandFeedback(result)
                return stopped ? .cancelled : .endTurn
            case "", "exec", "plugin":
                try await publishCommandFeedback(result)
                if stopped { return .cancelled }
                try? await refreshConfiguration()
                return stopped ? .cancelled : .endTurn
            default:
                throw HermesGatewayError.message("Hermes returned an unsupported command outcome.")
            }
        }
        if let initialContext, !initialContext.isEmpty { content = initialContext + "\n\n" + content }
        var stagedImages: [String] = []
        do {
            for file in input.files {
                try fence.check()
                // Hermes opens the path itself, so it must be where Hermes runs:
                // the staged container path for a remote workspace.
                if remoteConnection != nil, file.remotePath == nil {
                    throw HermesGatewayError.message("\(file.fileName) was not staged in the remote workspace.")
                }
                let path = file.remotePath ?? file.localURL.resolvingSymlinksInPath().path
                let method = file.kind == .image ? "image.attach" : "file.attach"
                var params: HermesValue = ["session_id": .string(sessionID), "path": .string(path)]
                if file.kind == .image { stagedImages.append(path) }
                else { params["name"] = .string(file.fileName) }
                let attached = try await rpc.call(method, params)
                if let reference = attached["ref_text"].string { content += "\n" + reference }
            }
        } catch {
            // No prompt was submitted. Remove images already queued by this attempt
            // so a failed attachment cannot accompany a later, unrelated message.
            for path in stagedImages {
                _ = try? await rpc.call("image.detach", ["session_id": .string(sessionID), "path": .string(path)])
            }
            throw error
        }
        do {
            // Configuration and local slash commands can use an unpersisted native
            // draft. Pin its identity before submission, including an uncertain ack.
            try fence.check()
            try await onEvent?(.sessionIdentity(Self.identity(home: home, storedID: storedID, imported: imported)))
            try await prepareCLI(input.cliContext, text: content, resetPending: true)
            try fence.check()
            _ = try await rpc.call("prompt.submit", ["session_id": .string(sessionID), "text": .string(content)], dispatchFence: fence)
            initialContext = nil
            if let terminal { return try terminal.get() }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { completion = $0 }
            } onCancel: { Task { try? await self.cancel() } }
        } catch {
            if !fence.hasDispatched { try? await prepareCLI(input.cliContext, removePending: true) }
            else if case HermesGatewayError.rpc = error { try? await prepareCLI(input.cliContext, removePending: true) }
            // The worker may still be running after a lost submit acknowledgement.
            // A subsequent explicit send must resume and check running state first.
            recoveryInvalidated = true
            heartbeat?.cancel(); heartbeat = nil
            finish(.failure(error))
            await rpc.disconnect()
            throw error
        }
    }

    private func publishCommandFeedback(_ result: HermesValue) async throws {
        let output = [result["output"].string, result["warning"].string, result["notice"].string]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !output.isEmpty else { return }
        try await onEvent?(.activity(AgentRunActivity(
            id: UUID().uuidString, kind: .activity, phase: "end", title: "Hermes",
            status: "completed", content: output, contentIsDelta: false
        ), appendsContent: false))
    }

    public func steer(_ input: AgentMessageInput, dispatchFence: AgentDispatchFence? = nil) async throws {
        let fence = dispatchFence ?? AgentDispatchFence()
        try fence.check()
        guard !stopped else { throw CancellationError() }
        pendingDispatches[ObjectIdentifier(fence)] = fence
        defer { pendingDispatches[ObjectIdentifier(fence)] = nil }
        guard busy, let rpc else { throw HermesGatewayError.message("Hermes has no active turn to steer.") }
        guard input.files.isEmpty else { throw AgentMessageAttachmentError.unsupportedForAgent("Hermes steering accepts text and references. Send files with the next turn.") }
        try await prepareCLI(input.cliContext, text: input.transportText())
        do {
            try fence.check()
            let receipt = try await rpc.call("session.steer", ["session_id": .string(sessionID), "text": .string(input.transportText())], dispatchFence: fence)
            guard receipt["status"].text == "queued" else {
                try await prepareCLI(input.cliContext, removePending: true)
                throw HermesGatewayError.message("Hermes did not accept this steering input.")
            }
        } catch {
            if !fence.hasDispatched { try? await prepareCLI(input.cliContext, removePending: true) }
            else if case HermesGatewayError.rpc = error { try? await prepareCLI(input.cliContext, removePending: true) }
            throw error
        }
    }

    public func cancel() async throws {
        pendingDispatches.values.forEach { $0.cancel() }
        stopped = true
        cancelInteractions()
        guard let rpc, busy else { return }
        _ = try await rpc.call("session.interrupt", ["session_id": .string(sessionID)])
        // Completion comes from message.complete, never from terminating the service.
    }

    public func shutdown() async {
        pendingDispatches.values.forEach { $0.cancel() }
        closed = true
        heartbeat?.cancel(); heartbeat = nil
        let archive = nativeArchiveTask
        nativeArchiveToken = nil; nativeArchiveTask = nil
        archive?.cancel()
        cancelInteractions()
        if busy { try? await cancel() }
        await rpc?.setHandlers(event: nil, disconnected: nil, request: nil)
        await rpc?.disconnect(); rpc = nil
        finish(.failure(CancellationError()))
        await archive?.value
    }

    private func ping() async {
        guard !recoveryInvalidated, let rpc else { return }
        do { _ = try await rpc.call("ping", [:]) }
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
            // A service restart can interrupt replay while leaving its saved
            // transcript available through the read-only export interface.
            try await archiveNativeSession()
            guard newEpoch == epoch else {
                throw HermesGatewayError.message("Hermes Gateway restarted. Conversation history is preserved; review it before continuing this interrupted turn.")
            }
            let oldSession = sessionID
            let requested = storedID
            let snapshot = try await rpc.call("session.resume", ["session_id": .string(requested), "defer_history": .bool(true)])
            try bind(snapshot, requestedStoredID: requested)
            try await archiveNativeSession()
            guard sessionID == oldSession else {
                throw HermesGatewayError.message("Hermes Gateway restarted. Conversation history is preserved; review it before continuing this interrupted turn.")
            }
            let replay = try await rpc.call("session.events.since", ["session_id": .string(sessionID), "last_seen": .number(sequence)])
            guard !replay["truncated"].bool, replay["epoch"].string == epoch else {
                throw HermesGatewayError.message("Hermes event history no longer covers this interruption. The conversation is preserved in Hermes; input has not been resent.")
            }
            let events = replay["events"].array.map { $0["params"].isNull ? $0 : $0["params"] } + buffered
            buffered = []
            for request in replay["open_requests"].array { await receiveRequest(request) }
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
            try await archiveEvent(event)
            switch event["type"].text {
            case "message.delta":
                guard busy else { return }
                activeReasoningID = nil
                let delta = payload["text"].text; text += delta
                try await onEvent?(.assistantChunk(delta))
            case "message.interim":
                guard busy else { return }
                activeReasoningID = nil
                let interim = payload["text"].text
                completedText += interim + "\n\n"
                try await onEvent?(.assistantSnapshot(completedText))
                try await onEvent?(.assistantBoundary)
                text = ""
            case "message.complete":
                guard busy else { return }
                activeReasoningID = nil
                let final = payload["text"].text
                if !payload["response_previewed"].bool, !final.isEmpty || text.isEmpty {
                    try await onEvent?(.assistantSnapshot(completedText + final))
                }
                try await onEvent?(.assistantBoundary)
                if let reasoning = payload["reasoning"].string, !reasoning.isEmpty, reasoning != lastReasoningText {
                    if let id = lastReasoningID, reasoning.hasPrefix(lastReasoningText) {
                        let suffix = String(reasoning.dropFirst(lastReasoningText.count))
                        try await onEvent?(.activity(AgentRunActivity(id: id, kind: .thought, content: suffix, contentIsDelta: true), appendsContent: true))
                    } else {
                        activeReasoningID = nil
                        let id = reasoningID()
                        try await onEvent?(.activity(AgentRunActivity(id: id, kind: .thought, content: reasoning, contentIsDelta: false), appendsContent: false))
                    }
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
                    reconcileCompletedTurn(.failure(HermesGatewayError.message(payload["error"].string ?? "Hermes turn failed.")))
                } else {
                    reconcileCompletedTurn(.success(stopped || payload["status"].text == "interrupted" ? .cancelled : .endTurn))
                }
            case "session.info":
                updatePermissionInfo(payload)
                if !payload["usage"].isNull { latestUsage = payload["usage"] }
            case "reasoning.delta", "thinking.delta":
                let id = reasoningID()
                let delta = payload["text"].text
                lastReasoningText += delta
                try await onEvent?(.activity(AgentRunActivity(id: id, kind: .thought, content: delta, contentIsDelta: true), appendsContent: true))
            case "tool.start", "tool.complete":
                activeReasoningID = nil
                let complete = event["type"].text == "tool.complete"
                try await onEvent?(.activity(AgentRunActivity(id: payload["tool_id"].text, kind: .tool,
                    title: payload["name"].string, status: complete ? "completed" : "running", toolName: payload["name"].string,
                    content: complete ? payload["result_text"].string ?? payload["result"].json : payload["context"].string,
                    rawInputJSON: payload["args"].isNull ? nil : payload["args"].json), appendsContent: false))
            case "approval.request", "clarify.request", "sudo.request", "secret.request":
                beginInteraction(event["type"].text, payload)
            case "request.cancel":
                cancelInteraction(payload["id"].text)
            case "clarify.expire", "sudo.expire", "secret.expire":
                cancelInteraction(payload["request_id"].text)
            default: break
            }
        } catch { finish(.failure(error)) }
    }

    private func archiveNativeSession() async throws {
        guard let recorder = launch.historyRecorder, let rpc, !storedID.isEmpty else { return }
        let targets = storedID == resolvedStoredID || resolvedStoredID.isEmpty ? [storedID] : [storedID, resolvedStoredID]
        for target in targets {
            if let maximum = try await rpc.archiveSession(storedID: target, recorder: recorder,
                afterMessageID: archivedNativeHighWater[target], runID: runID) {
                archivedNativeHighWater[target] = maximum
            }
        }
        // Only the requested durable store and current compression tip matter.
        archivedNativeHighWater = archivedNativeHighWater.filter { targets.contains($0.key) }
    }

    /// Final history may be large. Keep the native reader free to process ping,
    /// interrupt and interaction replies while completion waits on this owned
    /// archive task. Shutdown cancels and drains it before retiring the client.
    private func reconcileCompletedTurn(_ result: Result<LocalACPStopReason, any Error>) {
        guard terminal == nil, nativeArchiveTask == nil else { return }
        guard !closed, launch.historyRecorder != nil else { finish(result); return }
        let token = UUID(); nativeArchiveToken = token
        nativeArchiveTask = Task { [weak self] in await self?.completeArchive(result, token: token) }
    }

    private func completeArchive(_ result: Result<LocalACPStopReason, any Error>, token: UUID) async {
        let outcome: Result<LocalACPStopReason, any Error>
        do {
            try await archiveNativeSession()
            if stopped, case .success = result { outcome = .success(.cancelled) }
            else { outcome = result }
        }
        catch { outcome = .failure(error) }
        guard nativeArchiveToken == token, !closed else { return }
        nativeArchiveToken = nil; nativeArchiveTask = nil
        finish(outcome)
    }

    private func archiveEvent(_ event: HermesValue) async throws {
        guard launch.historyRecorder != nil, !storedID.isEmpty else { return }
        guard !event["type"].text.hasPrefix("config.") else { return }
        let safe = HermesGatewayRPC.credentialSafeFrame(["method": "event", "params": event], secretRequestIDs: [])["params"]
        let bytes = try NativeHarnessArchive.encode(safe)
        // Replay sequence numbers are stable within the advertised native epoch.
        let id = event["seq"].number.map { (epoch ?? "unknown-epoch") + ":" + String($0) }
            ?? NativeHarnessArchive.digest(bytes)
        let kind = event["type"].string ?? "event"
        try await NativeHarnessArchive.capture(sourceID: "hermes:" + home, sessionID: storedID,
            records: [NativeHarnessArchive.record(id: "event:" + id, runID: runID, kind: kind, data: bytes,
                contentMode: kind.hasSuffix(".delta") ? "delta" : "event")], recorder: launch.historyRecorder)
    }

    private func reasoningID() -> String {
        if let activeReasoningID { return activeReasoningID }
        reasoningPhase += 1
        let id = "hermes-thinking-\(reasoningPhase)"
        activeReasoningID = id
        lastReasoningID = id
        lastReasoningText = ""
        return id
    }

    private func finish(_ result: Result<LocalACPStopReason, any Error>) {
        guard terminal == nil else { return }
        terminal = result
        nativeArchiveToken = nil
        nativeArchiveTask?.cancel()
        cancelInteractions()
        let waiting = completion; completion = nil
        waiting?.resume(with: result)
    }

    private func receiveRequest(_ frame: HermesValue) async {
        guard let rpc, let id = frame["id"].string else { return }
        let payload = frame["params"]
        guard !closed, !stopped, !recoveryInvalidated, busy, payload["session_id"].text == sessionID,
              ["approval", "clarify", "sudo", "secret"].contains(frame["method"].text) else {
            // Decline unsupported or unowned requests so the native worker never
            // waits indefinitely for a UI this client cannot present.
            try? await rpc.respond(id: id, result: [:])
            return
        }
        beginInteraction(frame["method"].text + ".request", payload, responseID: id)
    }

    private func cancelInteraction(_ id: String) {
        interactionFences.removeValue(forKey: id)?.cancel()
        interactionTasks.removeValue(forKey: id)?.cancel()
    }

    private func cancelInteractions() {
        interactionFences.values.forEach { $0.cancel() }
        interactionFences.removeAll()
        for task in interactionTasks.values { task.cancel() }
        interactionTasks.removeAll()
    }

    private func beginInteraction(_ type: String, _ payload: HermesValue, responseID: String? = nil) {
        let id = responseID ?? payload["request_id"].text
        guard !closed, !stopped, busy, !id.isEmpty, interactionTasks[id] == nil else { return }
        let fence = AgentDispatchFence()
        interactionFences[id] = fence
        interactionTasks[id] = Task { [weak self] in await self?.respond(type, payload, responseID: responseID, fence: fence) }
    }

    private func respond(_ type: String, _ payload: HermesValue, responseID: String?, fence: AgentDispatchFence) async {
        let id = responseID ?? payload["request_id"].text
        defer {
            if interactionFences[id] === fence { interactionTasks[id] = nil; interactionFences[id] = nil }
        }
        guard let rpc else { return }
        var params: HermesValue = ["session_id": .string(sessionID), "request_id": .string(id)]
        do {
            if type == "approval.request" {
                let choices = payload["choices"].array.compactMap(\.string)
                let offered = choices.isEmpty ? ["once", "deny"] : choices
                let selected = await onPermission?(LocalACPPermissionRequest(title: payload["description"].text + "\n" + payload["command"].text,
                    options: offered.map { LocalACPPermissionOption(id: $0, name: $0, kind: $0 == "deny" ? "reject_once" : $0 == "always" ? "allow_always" : "allow_once") }))
                guard !stopped, !closed, !Task.isCancelled else { return }
                let choice = HermesValue.string(selected.flatMap { offered.contains($0) ? $0 : nil } ?? "deny")
                if let responseID { try await rpc.respond(id: responseID, result: ["choice": choice], dispatchFence: fence) }
                else {
                    params["choice"] = choice
                    _ = try await rpc.call("approval.respond", params, dispatchFence: fence)
                }
            } else if type == "clarify.request" {
                let batch = payload["questions"].array
                let questions = (batch.isEmpty ? [payload] : batch).enumerated().map { index, question in
                    LocalACPQuestion(id: question["qid"].string ?? String(index), prompt: question["question"].text,
                        options: question["choices"].array.compactMap(\.string).map { LocalACPQuestionOption(id: $0, label: $0) }, allowsMultiple: question["multi_select"].bool)
                }
                let response = await onInteraction?(.questions(LocalACPQuestionRequest(questions: questions)))
                guard !stopped, !closed, !Task.isCancelled else { return }
                var answers: [String: HermesValue] = [:]
                if case .answers(let values) = response {
                    for (key, value) in values {
                        switch value {
                        case .single(let answer): answers[key] = .string(answer)
                        case .multiple(let answer): answers[key] = .string(answer.joined(separator: ", "))
                        }
                    }
                }
                if let responseID {
                    let result: HermesValue = answers.isEmpty ? [:] : batch.isEmpty
                        ? ["answer": answers[questions[0].id] ?? ""] : ["answers": .object(answers)]
                    try await rpc.respond(id: responseID, result: result, dispatchFence: fence)
                } else {
                    for question in questions {
                        guard !stopped, !closed, !Task.isCancelled else { return }
                        if !batch.isEmpty { params["question_id"] = .string(question.id) }
                        params["answer"] = answers[question.id] ?? ""
                        _ = try await rpc.call("clarify.respond", params, dispatchFence: fence)
                    }
                }
            } else {
                let prompt = type == "sudo.request" ? "Hermes requests your sudo password" : payload["prompt"].text
                let answer = await onInteraction?(.secret(prompt: prompt))
                guard !stopped, !closed, !Task.isCancelled else { return }
                let value: HermesValue
                if case .secret(let secret) = answer { value = .string(secret) } else { value = "" }
                if let responseID { try await rpc.respond(id: responseID, result: ["value": value], dispatchFence: fence) }
                else {
                    params[type == "sudo.request" ? "password" : "value"] = value
                    _ = try await rpc.call(type == "sudo.request" ? "sudo.respond" : "secret.respond", params, dispatchFence: fence)
                }
            }
        } catch { if !Task.isCancelled { finish(.failure(error)) } }
    }
}
