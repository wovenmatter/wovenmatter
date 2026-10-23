import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite(.timeLimit(.minutes(1)))
struct ACPSessionRoutingTests {

    @Test @MainActor func disconnectDismissesAnApprovalDuringNativeResume() async throws {
        let fixture = try SessionRoutingFixture(bootstrapFrames: [
            permission(id: "resumed-approval"), update("agent_message_chunk", text: "queued after approval"),
        ])
        defer { fixture.remove() }
        let events = AsyncStream<String>.makeStream()
        let client = try fixture.client(historyRecorder: { direction, data in
            // The load response follows both notifications on the reader. This
            // proves shutdown cancels the queued tail while an earlier dialog waits.
            if direction == "in", String(decoding: data, as: UTF8.self).contains(#""result":{"sessionId":"parent"}"#) {
                events.continuation.yield("queued")
            }
        }, durableRemoteACP: true)
        defer { Task { await client.shutdown() } }
        await client.setResumePermissionHandler { _ in
            events.continuation.yield("opened")
            try? await Task.sleep(for: .seconds(30))
            events.continuation.yield("closed")
            return nil
        }
        let loading = Task { try await client.initializeSession(
            workingDirectory: fixture.root, existingSessionID: "parent", title: nil) }
        var iterator = events.stream.makeAsyncIterator(), observed = Set<String>()
        while observed != ["opened", "queued"] { observed.insert(try #require(await iterator.next())) }
        await client.shutdown()
        #expect(await iterator.next() == "closed")
        _ = try? await loading.value
        events.continuation.finish()
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

actor RoutingEvents {
    private var recorded: [LocalACPEvent] = []
    func record(_ event: LocalACPEvent) { recorded.append(event) }
    func values() -> [LocalACPEvent] { recorded }
}

private actor RoutingPermissions {
    private var recorded: [LocalACPPermissionRequest] = []
    func record(_ request: LocalACPPermissionRequest) { recorded.append(request) }
    func values() -> [LocalACPPermissionRequest] { recorded }
}

struct SessionRoutingFixture {
    let root: URL
    let executable: URL
    let logURL: URL

    init(bootstrapFrames: [[String: Any]] = [], promptFrames: [[String: Any]] = [], permissionResponseCount: Int = 0,
         missingLoadedSession: Bool = false, historyPages: [String] = [], idleFrames: [[String: Any]] = [],
         idleResult: String? = nil) throws {
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
        page=0
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
            *'"method":"woven/history"'*)
              if [ "$page" -eq 0 ]; then respond "$id" \(quoted(historyPages.first ?? "{}")); else respond "$id" \(quoted(historyPages.last ?? "{}")); fi
              page=$((page + 1)) ;;
            *'"method":"woven/idle"'*)
              \(try emit(idleFrames))
              \(idleResult.map { "respond \"$id\" " + quoted($0) } ?? "printf '{\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{\"code\":-32601,\"message\":\"Unsupported fixture method\"}}\\n' \"$id\"") ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func client(runtimeKind: AgentRuntimeKind = .grokBuild, accountCoordinator: ProviderAccountCoordinator? = nil,
                historyRecorder: WorkspaceWireRecorder? = nil, durableRemoteACP: Bool = false) throws -> LocalACPClient {
        var launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: runtimeKind, executableURL: executable, arguments: [],
            environment: durableRemoteACP ? ["WOVEN_DURABLE_REMOTE_ACP": "1"] : [:])
        launch.historyRecorder = historyRecorder
        return try LocalACPClient.start(launch: launch, workingDirectory: root, accountCoordinator: accountCoordinator)
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
    }, version: { 0 }, configurationVersion: { 0 }, scopeVersion: { 0 }, reconfigure: { $0 })
}
