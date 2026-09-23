import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite(.timeLimit(.minutes(1)))
struct ACPSessionRoutingTests {
    @Test @MainActor func composerReceivesDistinctBillingModelsThinkingAndPermissions() async throws {
        let models = ["claude-subscription/sonnet", "anthropic/sonnet", "openai-codex/fixture"]
        let fixture = try SessionRoutingFixture(bootstrapFrames: [
            update("config_option_update", fields: ["configOptions": [
                ["id": "model", "category": "model", "currentValue": models[0],
                 "options": models.map { ["value": $0, "name": $0] }],
                ["id": "thinking", "category": "thought_level", "currentValue": "high",
                 "options": [["value": "off"], ["value": "high"]]],
                ["id": "permission_mode", "currentValue": "normal",
                 "options": [["value": "normal", "name": "Ask Before Changes"], ["value": "full", "name": "Full Access"]]],
            ]]),
        ])
        defer { fixture.remove() }
        let client = try fixture.client(runtimeKind: .defaultAgent, accountCoordinator: fixtureAccounts())
        defer { Task { await client.shutdown() } }
        let configuration = try await client.initializeSession(
            workingDirectory: fixture.root, existingSessionID: nil, title: nil
        ).configuration
        #expect(configuration.model == "claude-subscription/sonnet")
        #expect(configuration.modelOptions == models)
        #expect(configuration.thinking == "high" && configuration.thinkingOptions == ["off", "high"])
        #expect(configuration.permission == "normal" && configuration.permissionOptions == ["normal", "full"])
        #expect(configuration.permissionOptionMetadata["full"]?.name == "Full Access")
        await client.shutdown()
    }

    @Test @MainActor func builtInReconnectDeliversApprovalWhileLoadingHistory() async throws {
        let fixture = try SessionRoutingFixture(bootstrapFrames: [permission(id: "resumed-approval")])
        defer { fixture.remove() }
        let client = try fixture.client(runtimeKind: .defaultAgent, accountCoordinator: fixtureAccounts())
        defer { Task { await client.shutdown() } }
        let approvals = RoutingPermissions()
        await client.setResumePermissionHandler { request in
            await approvals.record(request)
            return "allow-exact-id"
        }
        let initialized = try await client.initializeSession(
            workingDirectory: fixture.root, existingSessionID: "parent", title: nil)
        #expect(initialized.loadedExistingSession)
        #expect(await approvals.values().count == 1)
        #expect(await approvals.values().first?.options.contains(where: { $0.id == "allow-exact-id" }) == true)
        await client.shutdown()
    }

    @Test @MainActor func disconnectDismissesAnApprovalDuringBuiltInResume() async throws {
        let fixture = try SessionRoutingFixture(bootstrapFrames: [permission(id: "resumed-approval")])
        defer { fixture.remove() }
        let client = try fixture.client(runtimeKind: .defaultAgent, accountCoordinator: fixtureAccounts())
        defer { Task { await client.shutdown() } }
        let events = AsyncStream<String>.makeStream()
        await client.setResumePermissionHandler { _ in
            events.continuation.yield("opened")
            try? await Task.sleep(for: .seconds(30))
            events.continuation.yield("closed")
            return nil
        }
        let loading = Task { try await client.initializeSession(
            workingDirectory: fixture.root, existingSessionID: "parent", title: nil) }
        var iterator = events.stream.makeAsyncIterator()
        #expect(await iterator.next() == "opened")
        await client.shutdown()
        #expect(await iterator.next() == "closed")
        _ = try? await loading.value
        events.continuation.finish()
    }

    @Test @MainActor func builtInRemoteApprovalCancellationBypassesTheNotificationBarrier() async throws {
        let fixture = try SessionRoutingFixture(promptFrames: [
            permission(id: "remote-approval"),
            ["jsonrpc": "2.0", "method": "woven/permission_cancel", "params": ["requestID": "remote-approval"]],
            update("agent_message_chunk", text: "settled elsewhere"),
        ], permissionResponseCount: 1)
        defer { fixture.remove() }
        let client = try fixture.client(runtimeKind: .defaultAgent, accountCoordinator: fixtureAccounts())
        defer { Task { await client.shutdown() } }
        _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
        let events = RoutingEvents()
        let result = try await client.prompt("fixture", onEvent: { await events.record($0) }, onPermission: { _ in
            // A cancelled handler must not hold later updates behind its barrier.
            try? await Task.sleep(for: .seconds(30))
            return nil
        })
        #expect(result == .endTurn)
        #expect(await events.values() == [.assistantChunk("settled elsewhere")])
        #expect(try fixture.permissionResponses().first?["result"] != nil)
        await client.shutdown()
    }

    @Test func childSessionsDoNotInterruptParentTextReasoningToolsOrConfiguration() async throws {
        let frames: [[String: Any]] = [
            update("agent_thought_chunk", text: "parent thought one"),
            update("agent_message_chunk", session: "child-one", text: "child answer"),
            update("tool_call", session: "child-two", fields: ["toolCallId": "child-tool", "title": "Search"]),
            update("agent_thought_chunk", text: "parent thought two"),
            update("agent_message_chunk", text: "Casement, "),
            update("agent_thought_chunk", session: "child-three", text: "sources"),
            update("tool_call", session: "child-four", fields: ["toolCallId": "child-search", "title": "Search"]),
            update("agent_message_chunk", session: "child-five", text: "I will split the research"),
            update("agent_message_chunk", text: "Hardenburg, Britannica."),
            update("tool_call", fields: ["toolCallId": "parent-tool", "title": "Parent search", "kind": "search"]),
            update("tool_call_update", session: "child-six", fields: ["toolCallId": "parent-tool", "status": "failed"]),
            update("tool_call_update", fields: ["toolCallId": "parent-tool", "status": "completed"]),
            update("plan", fields: ["entries": [["content": "Parent plan", "status": "pending"]]]),
            update("plan", session: "child-one", fields: ["entries": []]),
            modelUpdate("parent-model"),
            modelUpdate("child-model", session: "child-two"),
            update("available_commands_update", fields: ["availableCommands": [["name": "parent-command"]]]),
            update("available_commands_update", session: "child-three", fields: ["availableCommands": [["name": "child-command"]]]),
            update("agent_message_chunk", session: nil, text: " legacy adapter"),
            update("agent_message_chunk", session: "", text: "empty session"),
            ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": 7, "update": ["sessionUpdate": "agent_message_chunk", "content": ["text": "invalid session"]]]],
        ]
        let fixture = try SessionRoutingFixture(promptFrames: frames)
        defer { fixture.remove() }
        let client = try fixture.client()
        defer { Task { await client.shutdown() } }
        let events = RoutingEvents()
        let configurations = RoutingConfigurations()
        _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
        await client.setConfigurationHandler { await configurations.record($0) }
        #expect(try await client.prompt("fixture", onEvent: { await events.record($0) }) == .endTurn)
        await client.shutdown()

        let delivered = await events.values()
        let text = delivered.compactMap { event -> String? in
            if case .assistantChunk(let value) = event { return value }
            return nil
        }
        #expect(text == ["Casement, ", "Hardenburg, Britannica.", " legacy adapter"])
        let activities = delivered.compactMap { event -> AgentRunActivity? in
            if case .activity(let value, _) = event { return value }
            return nil
        }
        #expect(activities.count == 5)
        let thoughts = activities.filter { $0.kind == .thought }
        #expect(thoughts.map(\.content) == ["parent thought one", "parent thought two"])
        #expect(thoughts.first?.id == thoughts.last?.id)
        #expect(activities.filter { $0.kind == .tool }.map(\.id) == ["parent-tool", "parent-tool"])
        #expect(activities.filter { $0.kind == .tool }.last?.status == "completed")
        #expect(activities.filter { $0.kind == .plan }.map(\.phase) == ["update"])
        // No child event can flush/freeze a partial assistant segment downstream.
        #expect(delivered.count == 8)
        let snapshots = await configurations.values()
        #expect(snapshots.count == 3)
        #expect(snapshots.last?.model == "parent-model")
        #expect(snapshots.last?.slashCommands.map(\.name) == ["parent-command"])
    }

    @Test(arguments: [false, true])
    func earlyNewAndLoadUpdatesKeepOnlyTheResolvedSession(loading: Bool) async throws {
        let fixture = try SessionRoutingFixture(bootstrapFrames: [
            modelUpdate("early-parent"),
            update("available_commands_update", fields: ["availableCommands": [["name": "early-parent-command"]]]),
            modelUpdate("early-child", session: "child"),
            update("available_commands_update", session: "child", fields: ["availableCommands": []]),
        ])
        defer { fixture.remove() }
        let client = try fixture.client()
        defer { Task { await client.shutdown() } }
        let initialized = try await client.initializeSession(
            workingDirectory: fixture.root, existingSessionID: loading ? "parent" : nil, title: nil
        )
        await client.shutdown()
        #expect(initialized.sessionID == "parent")
        #expect(initialized.loadedExistingSession == loading)
        #expect(initialized.configuration.model == "early-parent")
        #expect(initialized.configuration.slashCommands.map(\.name) == ["early-parent-command"])
    }

    @Test func missingLoadedSessionSwitchesRoutingToTheNewSession() async throws {
        let fixture = try SessionRoutingFixture(
            bootstrapFrames: [modelUpdate("new-parent"), modelUpdate("obsolete", session: "old")],
            promptFrames: [update("agent_message_chunk", session: "old", text: "old reply"), update("agent_message_chunk", text: "new reply")],
            missingLoadedSession: true
        )
        defer { fixture.remove() }
        let client = try fixture.client()
        defer { Task { await client.shutdown() } }
        let initialized = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: "old", title: nil)
        let events = RoutingEvents()
        #expect(try await client.prompt("fixture", onEvent: { await events.record($0) }) == .endTurn)
        await client.shutdown()
        #expect(!initialized.loadedExistingSession)
        #expect(initialized.configuration.model == "new-parent")
        #expect(await events.values() == [.assistantChunk("new reply")])
    }

    @Test func foreignPermissionsCancelWithoutCallingTheParentHandlerAndPreserveRequestIDs() async throws {
        let fixture = try SessionRoutingFixture(promptFrames: [
            permission(id: "child-approval", session: "child"),
            permission(id: 811, session: "child"),
            // A foreign request is cancelled even when its provider payload is malformed.
            ["jsonrpc": "2.0", "id": "child-malformed", "method": "session/request_permission", "params": ["sessionId": "child"]],
            permission(id: "parent-approval"),
            permission(id: 812),
            permission(id: "legacy-approval", session: nil),
        ], permissionResponseCount: 6)
        defer { fixture.remove() }
        let client = try fixture.client()
        defer { Task { await client.shutdown() } }
        _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
        let calls = RoutingPermissions()
        #expect(try await client.prompt("fixture", onPermission: { request in
            await calls.record(request)
            return "allow-exact-id"
        }) == .endTurn)
        await client.shutdown()
        #expect(await calls.values().count == 3)
        let responses = try fixture.permissionResponses()
        #expect(responses.count == 6)
        for response in responses.prefix(3) {
            #expect((response["result"] as? [String: Any])?["outcome"] as? [String: String] == ["outcome": "cancelled"])
        }
        for response in responses.suffix(3) {
            #expect((response["result"] as? [String: Any])?["outcome"] as? [String: String] == ["outcome": "selected", "optionId": "allow-exact-id"])
        }
        #expect(responses.first?["id"] as? String == "child-approval")
        #expect(responses.dropFirst().first?["id"] as? Int == 811)
        #expect(responses.dropFirst(3).first?["id"] as? String == "parent-approval")
        #expect(responses.dropFirst(4).first?["id"] as? Int == 812)
    }

    @Test(arguments: ["cancel", "invalid", "no-handler", "reject", "allow"])
    func permissionSelectionUsesOnlyAnExplicitAdvertisedOption(selection: String) async throws {
        let fixture = try SessionRoutingFixture(promptFrames: [permission(id: "approval")], permissionResponseCount: 1)
        defer { fixture.remove() }
        let client = try fixture.client()
        defer { Task { await client.shutdown() } }
        _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
        let handler: LocalACPClient.PermissionHandler? = selection == "no-handler" ? nil : { @Sendable _ in
            switch selection {
            case "cancel": nil
            case "invalid": "not-advertised"
            case "reject": "reject-exact-id"
            default: "allow-exact-id"
            }
        }
        #expect(try await client.prompt("fixture", onPermission: handler) == .endTurn)
        await client.shutdown()
        let response = try #require(fixture.permissionResponses().first)
        let outcome = (response["result"] as? [String: Any])?["outcome"] as? [String: String]
        if selection == "reject" || selection == "allow" {
            #expect(outcome == ["outcome": "selected", "optionId": selection + "-exact-id"])
        } else {
            #expect(outcome == ["outcome": "cancelled"])
        }
    }

    @Test func foreignApprovalSettlesWhileParentApprovalIsStillAwaitingSelection() async throws {
        let fixture = try SessionRoutingFixture(promptFrames: [
            permission(id: "held-parent"),
            permission(id: "independent-child", session: "child"),
            update("agent_message_chunk", text: "after parent selection"),
        ], permissionResponseCount: 2)
        defer { fixture.remove() }
        let client = try fixture.client()
        defer { Task { await client.shutdown() } }
        _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
        let selections = AsyncStream<String>.makeStream()
        defer { selections.continuation.finish() }
        let events = RoutingEvents()
        let calls = RoutingPermissions()
        let turn = Task {
            try await client.prompt("fixture", onEvent: { await events.record($0) }, onPermission: { request in
                await calls.record(request)
                var iterator = selections.stream.makeAsyncIterator()
                return await iterator.next()
            })
        }
        // Bounded wait, then release the parent even on the buggy implementation.
        // Child cancellation must not depend on that unrelated user selection.
        var childSettled = false
        for _ in 0..<100 {
            if (try? fixture.permissionResponses().contains { $0["id"] as? String == "independent-child" }) == true {
                childSettled = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(childSettled)
        #expect(await events.values().isEmpty)
        selections.continuation.yield("allow-exact-id")
        selections.continuation.finish()
        #expect(try await turn.value == .endTurn)
        await client.shutdown()
        #expect(await calls.values().count == 1)
        #expect(await events.values() == [.assistantChunk("after parent selection")])
        let responses = try fixture.permissionResponses()
        #expect(responses.count == 2)
        let child = try #require(responses.first { $0["id"] as? String == "independent-child" })
        let parent = try #require(responses.first { $0["id"] as? String == "held-parent" })
        #expect((child["result"] as? [String: Any])?["outcome"] as? [String: String] == ["outcome": "cancelled"])
        #expect((parent["result"] as? [String: Any])?["outcome"] as? [String: String] == ["outcome": "selected", "optionId": "allow-exact-id"])
    }
}

private func update(_ kind: String, session: String? = "parent", text: String? = nil, fields: [String: Any] = [:]) -> [String: Any] {
    var body = fields
    body["sessionUpdate"] = kind
    if let text { body["content"] = ["text": text] }
    var params: [String: Any] = ["update": body]
    if let session { params["sessionId"] = session }
    return ["jsonrpc": "2.0", "method": "session/update", "params": params]
}

private func modelUpdate(_ model: String, session: String = "parent") -> [String: Any] {
    update("config_option_update", session: session, fields: ["configOptions": [[
        "id": "model", "category": "model", "currentValue": model,
        "options": [["value": model]],
    ]]])
}

private func permission(id: Any, session: String? = "parent") -> [String: Any] {
    var params: [String: Any] = ["toolCall": ["title": "Read fixture"], "options": [
        ["optionId": "reject-exact-id", "kind": "reject_once", "name": "No, and tell Grok what to do differently"],
        ["optionId": "allow-exact-id", "kind": "allow_once", "name": "Yes"],
    ]]
    if let session { params["sessionId"] = session }
    return ["jsonrpc": "2.0", "id": id, "method": "session/request_permission", "params": params]
}

private actor RoutingEvents {
    private var recorded: [LocalACPEvent] = []
    func record(_ event: LocalACPEvent) { recorded.append(event) }
    func values() -> [LocalACPEvent] { recorded }
}

private actor RoutingConfigurations {
    private var recorded: [LocalACPSessionConfiguration] = []
    func record(_ configuration: LocalACPSessionConfiguration) { recorded.append(configuration) }
    func values() -> [LocalACPSessionConfiguration] { recorded }
}

private actor RoutingPermissions {
    private var recorded: [LocalACPPermissionRequest] = []
    func record(_ request: LocalACPPermissionRequest) { recorded.append(request) }
    func values() -> [LocalACPPermissionRequest] { recorded }
}

private struct SessionRoutingFixture {
    let root: URL
    let executable: URL
    let logURL: URL

    init(bootstrapFrames: [[String: Any]] = [], promptFrames: [[String: Any]] = [], permissionResponseCount: Int = 0, missingLoadedSession: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "acp-session-routing-\(UUID().uuidString)")
        executable = root.appending(path: "adapter")
        logURL = root.appending(path: "requests.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func emit(_ frames: [[String: Any]]) throws -> String {
            try frames.map { frame in
                let json = String(decoding: try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]), as: UTF8.self)
                return "printf '%s\\n' " + quoted(json)
            }.joined(separator: "\n")
        }
        let initialize = #"{"protocolVersion":2,"agentCapabilities":{"loadSession":true}}"#
        let script = """
        #!/bin/sh
        respond() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$1" "$2"; }
        while IFS= read -r request; do
          printf '%s\\n' "$request" >> \(quoted(logURL.path))
          request=$(printf '%s' "$request" | sed 's#\\\\/#/#g')
          id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          case "$request" in
            *'"method":"woven/configure"'*) respond "$id" '{}' ;;
            *'"method":"initialize"'*) respond "$id" '\(initialize)' ;;
            *'"method":"session/load"'*)
              \(missingLoadedSession ? "printf '{\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{\"code\":-32002,\"message\":\"Missing session\"}}\\n' \"$id\"" : try emit(bootstrapFrames) + "\nrespond \"$id\" '{\"sessionId\":\"parent\"}'") ;;
            *'"method":"session/new"'*)
              \(try emit(bootstrapFrames))
              respond "$id" '{"sessionId":"parent"}' ;;
            *'"method":"session/prompt"'*)
              \(try emit(promptFrames))
              remaining=\(permissionResponseCount)
              while [ "$remaining" -gt 0 ] && IFS= read -r response; do
                printf '%s\\n' "$response" >> \(quoted(logURL.path))
                remaining=$((remaining - 1))
              done
              respond "$id" '{"stopReason":"end_turn"}' ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func client(runtimeKind: AgentRuntimeKind = .grokBuild, accountCoordinator: ProviderAccountCoordinator? = nil) throws -> LocalACPClient {
        try LocalACPClient.start(launch: .init(runtimeKind: runtimeKind, executableURL: executable, arguments: []), workingDirectory: root, accountCoordinator: accountCoordinator)
    }

    func permissionResponses() throws -> [[String: Any]] {
        try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").compactMap { line in
            let value = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return value["method"] == nil ? value : nil
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor private func fixtureAccounts() -> ProviderAccountCoordinator {
    ProviderAccountCoordinator(refresh: { scopes in
        Dictionary(uniqueKeysWithValues: scopes.map { ($0, DefaultAgentPayload(config: .init(), credentials: [:], workspace: $0)) })
    }, version: { 0 })
}
