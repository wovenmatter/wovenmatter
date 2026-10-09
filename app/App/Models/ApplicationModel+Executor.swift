import Foundation
import WovenMatterCore
import WovenMatterClient

extension ApplicationModel {
    func executorClient(install: Bool = false, config proposed: ExecutorConfiguration? = nil, prepareHost: Bool = false) async throws -> ExecutorBrokerClient {
        guard !isBackendFrontend, let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let saved = try await database.toolSettings().executor
        guard let config = proposed ?? saved else { throw DefaultAgentError.message("Set up Executor in Settings → Connections first.") }
        if executorRuntime.client == nil {
            executorRuntime.client = ExecutorBrokerClient(directory: try Self.dashboardSupportDirectory().appending(path: "executor"))
        }
        let client = executorRuntime.client!
        do {
            if install, config.location == .remote {
                _ = try RemoteWorkspaceSSHClient.validatedDestination(hostName: config.host, userName: config.user)
                let host = config.host, user = config.user
                // Reuse Woven's read-only host inspection; setup refuses to silently provision a host.
                let ssh = RemoteWorkspaceSSHClient()
                var preflight = try await ssh.preflight(hostName: host, userName: user)
                if !preflight.ready, prepareHost {
                    guard preflight.canPrepare == true else { throw DefaultAgentError.message("This Linux host cannot be prepared automatically. Inspect its blocking issues in Remote workspaces.") }
                    _ = try await ssh.prepareHost(hostName: host, userName: user)
                    preflight = try await ssh.preflight(hostName: host, userName: user)
                }
                guard preflight.ready else { throw DefaultAgentError.message("Prepare this Linux host through Remote workspaces, then deploy Executor.") }
            }
            _ = try await client.call(.object(["operation": .string("configure"), "config": try executorJSON(config), "install": .bool(install)]))
            executorRuntime.configured = config
        }
        return client
    }

    func recoverExecutorSetup() async throws {
        guard let database = dashboardStore?.database, let setup = try await database.toolSettings().executorSetup, setup.running else { return }
        try await database.updateExecutor(setup: .init(configuration: setup.configuration, running: false, error: "Executor setup was interrupted. Retry install or deploy; existing data and keys are retained."))
        try await agentTools?.reload()
    }

    func executorJSON<T: Encodable>(_ value: T) throws -> GatewayJSONValue {
        try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(value))
    }

    func executeExecutorControl(_ control: ExecutorControl) async throws -> URL? {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        switch control {
        case let .setup(config, prepareHost):
            guard !executorRuntime.isSettingUp else { return nil }
            executorRuntime.setupStarting = true
            defer { executorRuntime.setupStarting = false }
            if config.id != executorRuntime.configured?.id {
                executorRuntime.cancelAll()
            }
            try await database.updateExecutor(setup: .init(configuration: config, running: true))
            executorRuntime.setupTask = Task { [self] in
                do {
                    _ = try await executorClient(install: true, config: config, prepareHost: prepareHost)
                    try Task.checkCancellation()
                    try await database.updateExecutor(configuration: config)
                    try await refreshExecutorInventory()
                    try await database.updateExecutor(clearSetup: true)
                } catch {
                    try? await database.updateExecutor(setup: .init(configuration: config, running: false, error: error.localizedDescription))
                }
                executorRuntime.setupTask = nil
                try? await agentTools?.reload()
                await backendApplicationService?.invalidations.publish(scopes: [.settings])
            }
            return nil
        case .refresh:
            guard !executorRuntime.isSettingUp else { throw DefaultAgentError.message("Executor setup is still running.") }
            try await refreshExecutorInventory()
            return nil
        case .dashboard:
            guard !executorRuntime.isSettingUp else { throw DefaultAgentError.message("Executor setup is still running.") }
            let value = try await executorClient().call(.object(["operation": .string("dashboard")]))
            guard let text = value.objectValue?["url"]?.stringValue, let url = URL(string: text) else { throw DefaultAgentError.message("Executor dashboard is unavailable.") }
            return url
        case let .selection(session, profiles):
            guard !executorRuntime.isSettingUp else { throw DefaultAgentError.message("Executor setup is still running.") }
            // Per-session edit tasks fence reentrant UI/CLI reads while the server
            // acknowledges the new scope. Publish preferences only after that ACK.
            let task = executorRuntime.serialized(session) { [self] in
                var policy = try await database.sessionTools(session)
                policy.executorProfiles = profiles
                try await synchronizeExecutorScope(session, policy: policy)
                try await database.setSessionExecutorProfiles(profiles, sessionID: session)
            }
            try await task.value
            return nil
        case let .enabled(session, enabled):
            if enabled, executorRuntime.isSettingUp { throw DefaultAgentError.message("Executor setup is still running.") }
            if !enabled { executorRuntime.cancel(session) }
            let task = executorRuntime.serialized(session) { [self] in
                var policy = try await database.sessionTools(session)
                if enabled { policy.enabled.insert(.executor) } else { policy.enabled.remove(.executor) }
                if !enabled {
                    _ = try await database.setSessionToolEnabled(.executor, enabled: false, sessionID: session)
                    // Local denial remains effective even if the remote host is
                    // offline. Server revocation and in-flight cancellation are best effort.
                    if !executorRuntime.isSettingUp { try? await synchronizeExecutorScope(session, policy: policy) }
                } else {
                    try await synchronizeExecutorScope(session, policy: policy)
                    _ = try await database.setSessionToolEnabled(.executor, enabled: true, sessionID: session)
                }
            }
            try await task.value
            return nil
        }
    }

    private func refreshExecutorInventory() async throws {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let client = try await executorClient()
        let value = try await client.call(.object(["operation": .string("inventory")]))
        let apps = try JSONDecoder().decode([ExecutorAppProfile].self, from: JSONEncoder().encode(value))
        try await database.updateExecutor(apps: apps)
    }

    func synchronizeExecutorScope(_ session: String, policy: WorkspaceSessionTools) async throws {
        guard let settings = try await dashboardStore?.database.toolSettings(), let config = settings.executor else {
            if policy.enabled.contains(.executor) { throw DefaultAgentError.message("Set up Executor in Connections first.") }; return
        }
        let profiles = config.apps.filter { policy.executorProfiles?.contains($0.id) == true }
        _ = try await executorClient().call(.object(["operation": .string("scope"), "session": .string(session),
            "enabled": .bool(policy.enabled.contains(.executor)), "profiles": try executorJSON(profiles)]))
    }

    func executorPolicy(_ session: String) async throws -> ExecutorApprovalPolicy {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        var runtime = workspaceOverview?.conversations.first { $0.id == session }?.localRuntimeKind
        if runtime == nil { runtime = try? await database.localACPSession(conversationID: session).runtimeKind }
        guard let runtime else { return .ask }
        let metadata = openCodeModel(for: session)?.metadata(session) ?? openClawGatewaySessionMetadata[session] ?? localACPSessionMetadata[session]
        // Unconfirmed, inherited and native smart modes retain manual review.
        return .resolve(runtime: runtime, mode: metadata?.permission,
            confirmed: !updatingLocalACPSessionIDs.contains(session))
    }

    func handleExecutorTool(_ session: String, command: WovenMatterToolCommand, request: WovenMatterToolRequest) async throws -> WovenMatterToolResponse {
        let fence = executorRuntime.fence(session)
        let task = executorRuntime.serialized(session) { [self] in
            try executorRuntime.check(session, fence: fence)
            return try await admitExecutorTool(session, command: command, request: request, fence: fence)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func admitExecutorTool(_ session: String, command: WovenMatterToolCommand, request: WovenMatterToolRequest, fence: UUID) async throws -> WovenMatterToolResponse {
        guard !executorRuntime.isSettingUp else { throw DefaultAgentError.message("Executor setup is still running. Wait for Connections to show the runtime is ready.") }
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        try await database.requireTool(.executor, sessionID: session)
        let policy = try await database.sessionTools(session)
        let client = try await executorClient()
        if command.action == "status" || command.action == "cancel" {
            let id = try command.required("id", allowPositional: true)
            let result = try await client.call(.object(["operation": .string(command.action), "id": .string(id), "session": .string(session)]))
            if command.action == "cancel" { executorRuntime.jobs[id]?.cancel() }
            return .init(result: result)
        }
        let config = try await database.toolSettings().executor
        let profiles = config?.apps.filter { policy.executorProfiles?.contains($0.id) == true } ?? []
        let code: String
        switch command.action {
        case "execute": code = try command.required("code")
        case "search":
            let input: GatewayJSONValue = .object(["query": .string(command.options["query"] ?? ""), "limit": .number(Double(try command.integer("limit", default: 30, range: 1...100)))])
            code = "return await tools.search(" + String(decoding: try JSONEncoder().encode(input), as: UTF8.self) + ");"
        case "skills": code = ""
        default: throw WorkspaceToolError.invalid("Unknown Executor command.")
        }
        if command.action == "execute", try await executorPolicy(session) == .deny { throw DefaultAgentError.message("This conversation’s permission mode does not permit Executor programs.") }
        try executorRuntime.check(session, fence: fence)
        let result = try await client.call(.object(["operation": .string("start"), "id": .string(request.requestID), "session": .string(session),
            "code": .string(code), "action": .string(command.action), "profiles": try executorJSON(profiles)]))
        do { try executorRuntime.check(session, fence: fence) }
        catch {
            _ = try? await client.call(.object(["operation": .string("cancel"), "id": .string(request.requestID), "session": .string(session)]))
            throw error
        }
        if executorRuntime.jobs[request.requestID] == nil, result.objectValue?["status"]?.stringValue == "awaiting-approval" {
            let id = request.requestID, readOnly = command.action != "execute"
            executorRuntime.sessions[id] = session
            executorRuntime.jobs[id] = Task { [weak self] in
                guard let self else { return }
                await self.driveExecutorJob(id, session: session, code: code, readOnly: readOnly, client: client)
                self.executorRuntime.jobs[id] = nil
                self.executorRuntime.sessions[id] = nil
            }
        }
        return .init(result: result)
    }

    private func driveExecutorJob(_ id: String, session: String, code: String, readOnly: Bool, client: ExecutorBrokerClient) async {
        func message(_ operation: String, _ extra: [String: GatewayJSONValue] = [:]) -> GatewayJSONValue {
            .object(["operation": .string(operation), "id": .string(id), "session": .string(session)].merging(extra) { _, new in new })
        }
        do {
            let initialPolicy = try await executorPolicy(session)
            while !Task.isCancelled {
                let currentPolicy = try await executorPolicy(session)
                if !readOnly && currentPolicy != initialPolicy { throw CancellationError() }
                try await dashboardStore?.database.requireTool(.executor, sessionID: session)
                let result = try await client.call(message("status"))
                let status = result.objectValue?["status"]?.stringValue ?? "interrupted"
                if ["completed", "cancelled", "interrupted"].contains(status) { return }
                if ["awaiting-approval", "approval-required", "input-required"].contains(status) {
                    let pending = try await client.call(message("interaction"))
                    let response: GatewayJSONValue
                    if status == "input-required" {
                        var answer = await executorInput(pending, session: session)
                        while !Task.isCancelled {
                            let validation = try await client.call(message("validateResponse", ["response": answer]))
                            if validation.objectValue?["valid"]?.boolValue == true { break }
                            answer = await executorInput(pending, session: session, invalid: true)
                        }
                        response = answer
                    }
                    else {
                        let current = try await executorPolicy(session)
                        let accepted: Bool
                        if readOnly && status == "awaiting-approval" { accepted = true }
                        else if current == .deny { accepted = false }
                        else if current == .full { accepted = true }
                        else {
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            let invocation = pending.objectValue?["invocation"] ?? .object([:])
                            let detail = String(decoding: (try? encoder.encode(invocation)) ?? Data(), as: UTF8.self)
                            let description = status == "awaiting-approval" ? "Run Executor program?\n" + code : "Approve Executor app action?\n" + detail
                            accepted = await requestLocalACPPermission(conversationID: session, request: .init(title: description, options: [
                                .init(id: "accept", name: "Approve", kind: "allow_once"), .init(id: "decline", name: "Decline", kind: "reject_once")])) == "accept"
                        }
                        response = .object(["action": .string(accepted ? "accept" : "decline"), "content": .object([:])])
                    }
                    try Task.checkCancellation()
                    let resume = executorRuntime.serialized(session) { [self] in
                        try Task.checkCancellation()
                        try await dashboardStore?.database.requireTool(.executor, sessionID: session)
                        let freshPolicy = try await executorPolicy(session)
                        if !readOnly && freshPolicy != initialPolicy { throw CancellationError() }
                        // Scope is rechecked by Executor again when resume admits the action.
                        _ = try await client.call(message("respond", ["response": response]))
                    }
                    try await withTaskCancellationHandler { try await resume.value } onCancel: { resume.cancel() }
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch { _ = try? await client.call(message("cancel")) }
    }

    private func executorInput(_ pending: GatewayJSONValue, session: String, invalid: Bool = false) async -> GatewayJSONValue {
        let form = pending.objectValue?["elicitation"]?.objectValue ?? [:]
        let schema = form["requestedSchema"]?.objectValue ?? [:]
        let fields = schema["properties"]?.objectValue ?? [:]
        let keys = fields.keys.sorted()
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let questions = keys.map { key in
            let field = fields[key]?.objectValue ?? [:]
            let multiple = field["type"]?.stringValue == "array"
            let choices = (multiple ? field["items"]?.objectValue?["enum"] : field["enum"])?.arrayValue ?? []
            let options = choices.compactMap { value -> LocalACPQuestionOption? in
                let text = value.stringValue ?? String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
                return text.isEmpty ? nil : .init(id: text, label: text)
            }
            let booleanOptions: [LocalACPQuestionOption] = field["type"]?.stringValue == "boolean"
                ? [.init(id: "true", label: "Yes"), .init(id: "false", label: "No")] : []
            let type = field["type"]?.stringValue ?? "string"
            let prompt = (field["title"]?.stringValue ?? key) + " (" + type + (required.contains(key) ? ", required" : ", optional") + ")"
                + (field["description"]?.stringValue.map { "\n" + $0 } ?? "")
            return LocalACPQuestion(id: key, prompt: prompt, options: options.isEmpty ? booleanOptions : options, allowsMultiple: multiple && !options.isEmpty)
        }
        let title = (form["message"]?.stringValue ?? "Executor requests input") + (invalid ? "\nCheck the required fields, types and allowed values, then try again." : "")
        if questions.isEmpty {
            let answer = await requestLocalACPPermission(conversationID: session, request: .init(title: title, options: [.init(id: "accept", name: "Continue", kind: "allow_once"), .init(id: "cancel", name: "Cancel", kind: "reject_once")]))
            return .object(["action": .string(answer == "accept" ? "accept" : "cancel"), "content": .object([:])])
        }
        let answer = await requestLocalACPInteraction(conversationID: session, request: .questions(.init(title: title, questions: questions)))
        guard case let .answers(values) = answer else { return .object(["action": .string("cancel")]) }
        func typed(_ value: String, type: String?) -> GatewayJSONValue {
            if type == "boolean", ["true", "false"].contains(value) { return .bool(value == "true") }
            if type == "number" || type == "integer", let number = Double(value), number.isFinite { return .number(number) }
            if type == "array" || type == "object", let json = try? JSONDecoder().decode(GatewayJSONValue.self, from: Data(value.utf8)) { return json }
            return .string(value)
        }
        var content: [String: GatewayJSONValue] = [:]
        for key in keys {
            let type = fields[key]?.objectValue?["type"]?.stringValue
            switch values[key] {
            case let .single(value):
                if !value.isEmpty || required.contains(key) { content[key] = typed(value, type: type) }
            case let .multiple(values):
                let itemType = fields[key]?.objectValue?["items"]?.objectValue?["type"]?.stringValue
                content[key] = .array(values.map { typed($0, type: itemType) })
            default: break
            }
        }
        return .object(["action": .string("accept"), "content": .object(content)])
    }
}
