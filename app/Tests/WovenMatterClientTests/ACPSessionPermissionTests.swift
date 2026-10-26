import Darwin
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite(.timeLimit(.minutes(1)))
struct ACPSessionPermissionTests {

    @Test(arguments: [String?.none, "existing-parent"])
    func earlyConfigurationUpdatesWaitForSessionIdentity(existingID: String?) async throws {
        let parent = notification(configuration(permission: "default").merging(["sessionUpdate": "config_option_update"]) { _, new in new }, session: existingID ?? "permission-session")
        let child = notification(configuration(permission: "full").merging(["sessionUpdate": "config_option_update"]) { _, new in new }, session: "child-session")
        try await withClient(state: [:], existingID: existingID, sessionPrelude: parent + "\n" + child) { client, _, initialized async throws in
            #expect(initialized.configuration.permission == "default")
            #expect(initialized.configuration.permissionOptions == ["default", "full"])
            #expect(initialized.loadedExistingSession == (existingID != nil))
            #expect(await client.sessionConfiguration() == initialized.configuration)
        }
    }


    @Test(arguments: [AgentRuntimeKind.codex, .claudeCode], ["mode", "permission_mode", "approval_mode"])
    func nativeSelectionsPreserveLabelsAndRemovedOptionsBecomeUnavailable(kind: AgentRuntimeKind, id: String) async throws {
        let state = configuration(permission: "default", id: id)
        let selected = configuration(permission: "full", id: id)
        var removed = selected
        removed["configOptions"] = (removed["configOptions"] as? [[String: Any]])?.filter { $0["id"] as? String != id }
        try await withClient(kind: kind, state: state, handlers: [
            "session/set_config_option": """
                case "$request" in
                  *'"value":"other"'*) \(respond(removed)) ;;
                  *) \(respond(selected)) ;;
                esac
                """,
        ]) { client, fixture, initialized async throws in
            let initial = initialized.configuration
            #expect(initial.permission == "default")
            #expect(initial.permissionOptions == ["default", "full"])
            #expect(initial.permissionOptionMetadata["full"]?.name == "Native full label")
            #expect(initial.permissionOptionMetadata["full"]?.description == "Native full description")
            #expect(initial.selecting(model: "other", thinking: "high").permission == "default")
            #expect(initial.selecting(permission: "full").model == "fixture-model")
            #expect(initial.selecting(permission: "full").thinking == "low")
            let result = try await client.setSessionPermission("full")
            #expect(result.permission == "full")
            #expect(result.model == "fixture-model" && result.thinking == "low")
            let requests = try fixture.requests(method: "session/set_config_option")
            #expect(requests.count == 1)
            let params = requests.first?["params"] as? [String: Any]
            #expect(params?["sessionId"] as? String == "permission-session")
            #expect(params?["configId"] as? String == id)
            #expect(params?["value"] as? String == "full")
            let withoutPermission = try await client.setSessionConfiguration(model: "other")
            #expect(withoutPermission.permission == nil && withoutPermission.permissionOptions.isEmpty)
            #expect(withoutPermission.permissionOptionMetadata.isEmpty)
            do {
                _ = try await client.setSessionPermission("full")
                Issue.record("Removed permission options remained selectable")
            } catch LocalACPClientError.unsupportedConfiguration { }
        }
    }

    @Test(arguments: [true, false], ["plan", "dontAsk"])
    func claudeSavedNativePolicyCanBeRestored(modern: Bool, saved: String) async throws {
        let options = ["default", "auto", "acceptEdits", "bypassPermissions", "plan", "dontAsk"].map {
            [modern ? "value" : "id": $0, "name": "Native " + $0]
        }
        func state(_ current: String) -> [String: Any] {
            modern
                ? ["configOptions": [["id": "mode", "category": "mode", "currentValue": current, "options": options]]]
                : ["modes": ["currentModeId": current, "availableModes": options]]
        }
        try await withClient(kind: .claudeCode, state: state("default"), handlers: [
            modern ? "session/set_config_option" : "session/set_mode": respond(state(saved)),
        ], existingID: "existing-claude", requestedPermission: saved) { client, fixture, initialized async throws in
            #expect(initialized.configuration.permission == "default")
            let restored = try await client.setSessionPermission(saved)
            #expect(restored.permission == saved)
            #expect(restored.permissionOptions == ["default", "auto", "acceptEdits", "bypassPermissions", "plan", "dontAsk"])
            #expect(try await client.setSessionPermission(saved).permission == saved)
            #expect(try fixture.requests(method: modern ? "session/set_config_option" : "session/set_mode").count == 1)
        }
    }

    @Test func notificationsPreserveCommandsAndAuthoritativeModelClamp() async throws {
        let clamped = configuration(permission: "default", model: "changed-model")
        let update = notification(["sessionUpdate": "current_mode_update", "currentModeId": "full"])
        let commands = notification(["sessionUpdate": "available_commands_update", "availableCommands": [["name": "review"]]])
        try await withClient(state: configuration(permission: "default"), handlers: [
            "session/set_config_option": update + "\n" + respond(configuration(permission: "full")),
            "session/prompt": commands + "\n" + notification(clamped.merging(["sessionUpdate": "config_option_update"]) { _, new in new })
                + "\n" + respond(["stopReason": "end_turn"]),
        ]) { client, _, _ async throws in
            let snapshots = PermissionSnapshots()
            await client.setConfigurationHandler { await snapshots.append($0) }
            _ = try await client.setSessionPermission("full")
            #expect(await snapshots.values().map(\.permission) == ["default", "full"])
            _ = try await client.prompt("fixture")
            let result = await client.sessionConfiguration()
            #expect(result.permission == "default")
            #expect(result.model == "changed-model")
            #expect(result.slashCommands.map(\.name) == ["review"])
            #expect(await snapshots.values().map(\.permission) == ["default", "full", "full", "default"])
        }
    }

    @Test func grokLaunchReplacesConflictingFlagsWithoutChangingOtherHarnesses() throws {
        let arguments = ["--no-auto-update", "--permission-mode=bypassPermissions", "agent", "--always-approve", "--leader", "stdio"]
        #expect(try LocalACPSessionPermissions.launchArguments(arguments, runtimeKind: .grokBuild, permission: "default") ==
            ["--permission-mode", "default", "--no-auto-update", "agent", "--no-leader", "stdio"])
        #expect(try LocalACPSessionPermissions.launchArguments(["--permission-mode", "auto", "agent", "--no-leader", "stdio"], runtimeKind: .grokBuild, permission: "dontAsk") ==
            ["--permission-mode", "dontAsk", "agent", "--no-leader", "stdio"])
        #expect(try LocalACPSessionPermissions.launchArguments(arguments, runtimeKind: .codex, permission: "normal") == arguments)
        #expect(LocalACPSessionPermissions.explicitGrokPermission(in: ["agent", "--always-approve", "stdio"]) == "bypassPermissions")
        #expect(LocalACPSessionPermissions.explicitGrokPermission(in: ["--permission-mode", "auto", "agent", "stdio"]) == "auto")
        #expect(LocalACPSessionPermissions.explicitGrokPermission(in: ["--permission-mode=default", "agent", "stdio"]) == "default")
        #expect(LocalACPSessionPermissions.explicitGrokPermission(in: ["agent", "stdio"]) == nil)
        #expect(throws: LocalACPClientError.self) {
            try LocalACPSessionPermissions.launchArguments(["agent", "stdio"], runtimeKind: .grokBuild, permission: "invented")
        }
    }

    @Test(arguments: [AgentRuntimeKind.codex, .claudeCode], [false, true])
    func fullRootWorkspaceConfirmsNativePermissionBeforePrompt(kind: AgentRuntimeKind, loading: Bool) async throws {
        let target = kind == .codex ? "agent-full-access" : "bypassPermissions"
        func mode(_ selected: String) -> [String: Any] {
            ["configOptions": [["id": "mode", "category": "mode", "currentValue": selected,
                "options": [["value": "default"], ["value": target]]]]]
        }
        try await withClient(kind: kind, state: mode("default"), handlers: [
            "session/set_config_option": respond(mode(target)),
            "session/prompt": respond(["stopReason": "end_turn"]),
        ], existingID: loading ? "existing" : nil, requestedPermission: target,
        environment: ["WOVENMATTER_HOST_ACCESS_MODE": "fullRoot"]) { client, fixture, initialized in
            #expect(initialized.configuration.permission == target)
            let setting = try #require(fixture.requests(method: "session/set_config_option").first)
            #expect((setting["params"] as? [String: Any])?["value"] as? String == target)
            #expect(try fixture.requests(method: "session/prompt").isEmpty)
            #expect(try await client.setSessionPermission("default").permission == target)
            #expect(try fixture.requests(method: "session/set_config_option").count == 1)
            _ = try await client.prompt("provider-free fixture")
            #expect(try fixture.requests(method: "session/prompt").count == 1)
        }
    }

    @Test func fullRootWorkspaceCannotSilentlyAcceptClampedPermission() async throws {
        let state = configuration(permission: "default")
        let fixture = try PermissionFixture(kind: .codex, state: state,
            handlers: ["session/set_config_option": respond(state)], sessionPrelude: "")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = try fixture.client(requestedPermission: "full", environment: ["WOVENMATTER_HOST_ACCESS_MODE": "fullRoot"])
        do {
            await #expect(throws: LocalACPClientError.self) {
                try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
            }
            #expect(try fixture.requests(method: "session/prompt").isEmpty)
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }

    @Test func remoteGrokPolicyRewritesOnlyStructuredHarnessArguments() throws {
        let resolved = try RemoteHarnessLaunchResolver.resolve(
            configuration: .init(name: "Fixture", workspaceID: "permission-fixture", hostName: "fixture.invalid"),
            runtimeKind: .grokBuild, processWorkingDirectory: URL(filePath: "/private/tmp"), tailnetSSHOptions: { _ in [] }
        ).launch
        let wrapped = try #require(resolved.wrappedCommand)
        let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: resolved.runtimeKind,
            executableURL: resolved.executableURL, arguments: resolved.arguments,
            processWorkingDirectoryURL: resolved.processWorkingDirectoryURL,
            requestedPermission: "default", wrappedCommand: wrapped)
        let prepared = try LocalACPSessionPermissions.prepareLaunch(launch)
        #expect(launch.executableURL.path == "/usr/bin/ssh")
        #expect(prepared.arguments.dropLast() == resolved.arguments.dropLast())
        #expect(prepared.explicitPermission == "default")
        let command = try shellTokens(prepared.arguments[wrapped.argumentIndex])
        #expect(Array(command.prefix(wrapped.harnessArgumentsStartIndex)) == Array(wrapped.command.prefix(wrapped.harnessArgumentsStartIndex)))
        #expect(Array(command.dropFirst(wrapped.harnessArgumentsStartIndex)) == ["--permission-mode", "default", "agent", "--no-leader", "stdio"])
        #expect(command.contains("HOME=/home"))
        #expect(command.contains(where: { $0.contains("flock --shared --nonblock 9") }))
        // A launch without an override remains byte-for-byte identical.
        #expect(try LocalACPSessionPermissions.prepareLaunch(resolved).arguments == resolved.arguments)
    }


    @Test(arguments: [false, true]) func codexReceivesSessionBoundWovenHTTPMCP(loading: Bool) async throws {
        let fixture = try PermissionFixture(kind: .codex, state: configuration(permission: "default"), handlers: [:], sessionPrelude: "")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .codex, executableURL: fixture.executable, arguments: [])
        launch.mcpConnection = .init(endpointURL: "http://127.0.0.1:43129/mcp", bearerToken: "fixture-session-bearer", captureID: "input")
        let client = try LocalACPClient.start(launch: launch, workingDirectory: fixture.root)
        do {
            _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: loading ? "existing" : nil, title: nil)
            let request = try #require(fixture.requests(method: loading ? "session/load" : "session/new").first)
            let params = try #require(request["params"] as? [String: Any])
            let servers = try #require(params["mcpServers"] as? [[String: Any]])
            let server = try #require(servers.first)
            #expect(servers.count == 1 && server["type"] as? String == "http")
            #expect(server["name"] as? String == "woven")
            #expect(server["url"] as? String == "http://127.0.0.1:43129/mcp")
            let headers = try #require(server["headers"] as? [[String: String]])
            #expect(headers.contains(["name": "Authorization", "value": "Bearer fixture-session-bearer"]))
            #expect(server["command"] == nil && server["args"] == nil && server["env"] == nil)
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }

    @Test(arguments: [true, false])
    func codexSmartReviewRequiresNativeClassification(modern: Bool) async throws {
        let idKey = modern ? "value" : "id"
        let options: [[String: Any]] = [
            [idKey: "read-only", "name": "Read only"],
            [idKey: "agent", "name": "Auto", "_meta": ["kind": "auto_review"]],
            [idKey: "agent-full-access", "name": "Bypass"],
            [idKey: "future-policy", "name": "Native future mode", "description": "Native future behavior"],
        ]
        let state: [String: Any] = modern
            ? ["configOptions": [["id": "mode", "category": "mode", "currentValue": "agent", "options": options]]]
            : ["modes": ["currentModeId": "agent", "availableModes": options]]
        try await withClient(state: state) { _, fixture, initialized async throws in
            let value = initialized.configuration
            #expect(value.permission == "agent")
            #expect(value.permissionOptions == ["read-only", "agent", "agent-full-access", "future-policy"])
            #expect(value.permissionOptionMetadata["read-only"]?.name == "Read only")
            #expect(value.permissionOptionMetadata["agent"]?.name == "Approve for me")
            #expect(value.permissionOptionMetadata["agent-full-access"]?.name == "Full access")
            #expect(value.permissionOptionMetadata["future-policy"]?.name == "Native future mode")
            #expect(value.permissionOptionMetadata["future-policy"]?.description == "Native future behavior")
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
            #expect(try fixture.requests(method: "session/set_mode").isEmpty)
        }
    }

    // Captured from Codex ACP 2.2.2 with Woven's ordinary client capabilities.
    // The separate workspace-write preset identifies agent as auto review;
    // this response does not carry the older _meta.kind classification.
    @Test(arguments: [false, true])
    func codexSeparateWorkspacePresetIdentifiesAutoReview(modern: Bool) async throws {
        let idKey = modern ? "value" : "id"
        let options: [[String: Any]] = [
            [idKey: "read-only", "name": "Read-only"],
            [idKey: "workspace-write", "name": "Workspace access"],
            [idKey: "agent", "name": "Auto review"],
            [idKey: "agent-full-access", "name": "Full access"],
        ]
        let state: [String: Any] = modern
            ? ["configOptions": [["id": "mode", "category": "mode", "type": "select", "currentValue": "agent", "options": options]]]
            : ["modes": ["currentModeId": "agent", "availableModes": options]]
        try await withClient(state: state) { _, fixture, initialized async throws in
            let value = initialized.configuration
            #expect(value.permission == "agent")
            #expect(value.permissionOptions == ["read-only", "workspace-write", "agent", "agent-full-access"])
            #expect(value.permissionOptionMetadata["workspace-write"]?.name == "Workspace access")
            #expect(value.permissionOptionMetadata["agent"]?.name == "Approve for me")
            #expect(value.permissionOptionMetadata["agent"]?.description == "Only ask for actions detected as potentially unsafe.")
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
            #expect(try fixture.requests(method: "session/set_mode").isEmpty)
        }
    }

    @Test func nativeErrorAndUnknownValuesNeverEscalate() async throws {
        try await withClient(state: configuration(permission: "default"), handlers: [
            "session/set_config_option": #"printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"Policy rejects full"}}\n' "$id""#,
        ]) { client, fixture, _ async throws in
            do {
                _ = try await client.setSessionPermission("unadvertised")
                Issue.record("An unadvertised permission value was accepted")
            } catch LocalACPClientError.invalidConfigurationValue { }
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
            do {
                _ = try await client.setSessionPermission("full")
                Issue.record("A rejected native change was accepted")
            } catch LocalACPClientError.agent(let code, _) { #expect(code == -32602) }
            #expect(await client.sessionConfiguration().permission == "default")
        }
    }

    @Test func foreignConfigurationCannotConfirmPermissionChange() async throws {
        let childMode = notification(["sessionUpdate": "current_mode_update", "currentModeId": "full"], session: "child-session")
        let childOptions = notification(configuration(permission: "full").merging(["sessionUpdate": "config_option_update"]) { _, new in new }, session: "child-session")
        try await withClient(state: configuration(permission: "default"), handlers: [
            "session/set_config_option": childMode + "\n" + childOptions + "\n" + respond([:]),
        ]) { client, _, initialized async throws in
            let snapshots = PermissionSnapshots()
            await client.setConfigurationHandler { await snapshots.append($0) }
            do {
                _ = try await client.setSessionPermission("full")
                Issue.record("A child session's mode falsely confirmed the parent setter")
            } catch LocalACPClientError.configurationNotConfirmed { }
            #expect(await client.sessionConfiguration() == initialized.configuration)
            #expect(await snapshots.values() == [initialized.configuration])
        }
    }

    @Test func claudeLoadedSessionNeverResetsToAuto() async throws {
        try await withClient(kind: .claudeCode, state: claudeState(), existingID: "existing-claude") { client, fixture, initialized async throws in
            #expect(initialized.loadedExistingSession)
            #expect(initialized.configuration.permission == "default")
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
            #expect(try fixture.requests(method: "session/new").isEmpty)
            #expect(await client.sessionConfiguration().permissionOptions == ["default", "auto"])
        }
    }

    @Test(arguments: [String?.none, "default", "auto", "bypassPermissions"])
    func grokLaunchPolicyRequiresReconnectAndPreservesNativeSession(permission: String?) async throws {
        try await withClient(kind: .grokBuild, state: configuration(permission: "unused"),
            existingID: "existing-grok", requestedPermission: permission) { client, fixture, initialized async throws in
            #expect(initialized.loadedExistingSession && initialized.sessionID == "existing-grok")
            #expect(initialized.configuration.permission == permission)
            #expect(initialized.configuration.permissionOptions == LocalACPSessionPermissions.grokOptions)
            #expect(initialized.configuration.model == "fixture-model")
            if let permission {
                #expect(try await client.setSessionPermission(permission).permission == permission)
                #expect(try fixture.launchArguments() == ["--permission-mode", permission, "agent", "--no-leader", "stdio"])
            } else {
                #expect(try fixture.launchArguments() == ["agent", "stdio"])
            }
            do {
                _ = try await client.setSessionPermission(permission == "default" ? "auto" : "default")
                Issue.record("Grok's no-op mode setter was used as a live policy setter")
            } catch LocalACPClientError.permissionChangeRequiresRestart { }
            #expect(try fixture.requests(method: "session/new").isEmpty)
            #expect(try fixture.requests(method: "session/set_mode").isEmpty)
            #expect(try fixture.requests(method: "session/set_config_option").isEmpty)
        }
    }

    @Test func wrappedLaunchRetainsLiteralArgumentsAndRejectsInvalidOffsets() throws {
        let prefix = ["docker", "exec", "container", "env", "LITERAL=$(printf forbidden)", "bash", "-c", "exec \"$@\"", "wrapper", "/path/with 'quotes'/grok"]
        let inner = ["--permission-mode", "bypassPermissions", "agent", "--always-approve", "stdio", "--debug-file", "/tmp/it's `literal`.log"]
        let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .grokBuild, executableURL: URL(filePath: "/usr/bin/ssh"),
            arguments: ["-T", "fixture.invalid", "unused"], requestedPermission: "auto",
            wrappedCommand: .init(argumentIndex: 2, command: prefix + inner, harnessArgumentsStartIndex: prefix.count))
        let prepared = try LocalACPSessionPermissions.prepareLaunch(launch)
        #expect(try shellTokens(prepared.arguments[2]) == prefix + ["--permission-mode", "auto", "agent", "--no-leader", "stdio", "--debug-file", "/tmp/it's `literal`.log"])
        let invalid = LocalACPRuntimeLaunchConfiguration(runtimeKind: .grokBuild, executableURL: launch.executableURL,
            arguments: launch.arguments, requestedPermission: "auto",
            wrappedCommand: .init(argumentIndex: 99, command: [], harnessArgumentsStartIndex: 0))
        #expect(throws: LocalACPClientError.self) { try LocalACPSessionPermissions.prepareLaunch(invalid) }
    }

    private func shellTokens(_ quotedCommand: String) throws -> [String] {
        // Parse into positional parameters only; never execute the remote command.
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "set -- " + quotedCommand + "; printf '%s\\0' \"$@\""]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    private func withClient(
        kind: AgentRuntimeKind = .codex,
        state: [String: Any],
        handlers: [String: String] = [:],
        existingID: String? = nil,
        requestedPermission: String? = nil,
        environment: [String: String] = [:],
        sessionPrelude: String = "",
        body: (LocalACPClient, PermissionFixture, LocalACPInitializedSession) async throws -> Void
    ) async throws {
        let fixture = try PermissionFixture(kind: kind, state: state, handlers: handlers, sessionPrelude: sessionPrelude)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = try fixture.client(requestedPermission: requestedPermission, environment: environment)
        // The suite owns the test deadline. A separate wall-clock lifetime can
        // kill a healthy fake peer while its client waits for executor time or
        // an interactive answer, then misreport that as a transport failure.
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let initialized = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: existingID, title: nil)
                try await body(client, fixture, initialized)
                try Task.checkCancellation()
                await client.shutdown()
            } catch {
                await client.shutdown()
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            Task { await client.shutdown() }
        }
    }

    private func configuration(permission: String, id: String = "mode", model: String = "fixture-model") -> [String: Any] {
        ["configOptions": [
            ["id": id, "category": "mode", "currentValue": permission, "options": [
                ["value": "default", "name": "Native default label"],
                ["value": "full", "name": "Native full label", "description": "Native full description"],
            ]],
            ["id": "model", "category": "model", "currentValue": model, "options": [["value": "fixture-model"], ["value": "other"], ["value": "changed-model"]]],
            ["id": "effort", "category": "thought_level", "currentValue": "low", "options": [["value": "low"], ["value": "high"]]],
        ]]
    }

    private func legacyModes() -> [String: Any] {
        ["modes": ["currentModeId": "default", "availableModes": [
            ["id": "default", "name": "Native default label"],
            ["id": "full", "name": "Native full label"],
        ]]]
    }

    private func claudeState() -> [String: Any] {
        ["configOptions": [["id": "mode", "currentValue": "default", "options": [["value": "default"], ["value": "auto"]]]]]
    }

    private func respond(_ result: [String: Any]) -> String {
        "respond \"$id\" \(PermissionFixture.quotedJSON(result))"
    }

    private func notification(_ update: [String: Any], session: String? = "permission-session") -> String {
        var params: [String: Any] = ["update": update]
        if let session { params["sessionId"] = session }
        let frame: [String: Any] = ["jsonrpc": "2.0", "method": "session/update", "params": params]
        return "printf '%s\\n' \(PermissionFixture.quotedJSON(frame))"
    }

    private func permissionRequest(session: String? = "permission-session", offersOnce: Bool = true) -> String {
        var options = [["optionId": "always-id", "kind": "allow_always"], ["optionId": "reject-this-request", "kind": "reject_once"]]
        if offersOnce { options.append(["optionId": "native-once-id", "kind": "allow_once"]) }
        var params: [String: Any] = ["options": options, "toolCall": ["title": "Fixture shell", "kind": "execute"]]
        if let session { params["sessionId"] = session }
        return receiveResponse(to: ["jsonrpc": "2.0", "id": "native-permission-id", "method": "session/request_permission", "params": params])
    }

    private func receiveResponse(to frame: [String: Any]) -> String {
        """
        printf '%s\\n' \(PermissionFixture.quotedJSON(frame))
        IFS= read -r reply
        printf '%s\\n' "$reply" >> "$response_log"
        """
    }
}

private actor PermissionHandlerCalls {
    private var titles: [String] = []
    func append(_ title: String) { titles.append(title) }
    func count() -> Int { titles.count }
}

private actor PermissionSnapshots {
    private var configurations: [LocalACPSessionConfiguration] = []
    func append(_ configuration: LocalACPSessionConfiguration) { configurations.append(configuration) }
    func values() -> [LocalACPSessionConfiguration] { configurations }
}

private struct PermissionFixture {
    let root: URL
    let kind: AgentRuntimeKind
    let executable: URL

    init(kind: AgentRuntimeKind, state: [String: Any], handlers: [String: String], sessionPrelude: String) throws {
        self.kind = kind
        root = FileManager.default.temporaryDirectory.appending(path: "acp-permission-\(UUID())")
        executable = root.appending(path: "adapter")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var session = state
        session["sessionId"] = "permission-session"
        let cases = handlers.map { method, body in "*'\"method\":\"\(method)\"'*) \(body) ;;" }.joined(separator: "\n")
        let script = """
        #!/bin/sh
        response_log='\(root.appending(path: "responses").path)'
        printf '%s\\n' "$@" > '\(root.appending(path: "arguments").path)'
        respond() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$1" "$2"; }
        while IFS= read -r request; do
          printf '%s\\n' "$request" >> '\(root.appending(path: "requests").path)'
          request=$(printf '%s' "$request" | sed 's#\\\\/#/#g')
          id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          case "$request" in
            *'"method":"initialize"'*) respond "$id" '{"protocolVersion":2,"agentCapabilities":{"loadSession":true}}' ;;
            *'"method":"session/new"'*|*'"method":"session/load"'*)
              \(sessionPrelude)
              respond "$id" \(Self.quotedJSON(session)) ;;
            *'"method":"authenticate"'*) respond "$id" '{}' ;;
            \(cases)
            *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Unexpected fixture method"}}\\n' "$id" ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func client(requestedPermission: String?, environment: [String: String] = [:]) throws -> LocalACPClient {
        try LocalACPClient.start(launch: .init(runtimeKind: kind, executableURL: executable,
            arguments: kind == .grokBuild ? ["agent", "stdio"] : [], environment: environment,
            requestedPermission: requestedPermission), workingDirectory: root)
    }

    func requests(method: String) throws -> [[String: Any]] {
        try String(contentsOf: root.appending(path: "requests"), encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter { $0["method"] as? String == method }
    }

    func launchArguments() throws -> [String] {
        try String(contentsOf: root.appending(path: "arguments"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func responses() throws -> [[String: Any]] {
        try String(contentsOf: root.appending(path: "responses"), encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    static func quotedJSON(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return "'" + String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
