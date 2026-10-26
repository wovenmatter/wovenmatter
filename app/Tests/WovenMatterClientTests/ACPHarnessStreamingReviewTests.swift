import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct ACPHarnessStreamingReviewTests {

  @Test(arguments: [false, true])
  func claudeContextVariantsSharePresentationButKeepExactSelections(legacy: Bool) async throws {
    let rows: [(String, String, String)] = [
      ("default", "Default (recommended)", "Sonnet"),
      ("sonnet", "Sonnet 5", "Sonnet 5"),
      ("claude-fable-5-1[1m]", "Fable 5.1", "Fable 5.1"),
      ("opus[1m]", "Opus (1M context)", "Opus 5 with 1M context"),
      ("haiku", "Haiku 4.5", "Haiku 4.5"),
      ("opus", "Opus", "Opus 5"),
      ("claude-opus-4-8", "Opus 4.8", "Opus 4.8"),
      ("claude-opus-4-8-20260101", "Opus 4.8", "Pinned Opus 4.8 snapshot")
    ]
    let options = rows.map { [legacy ? "modelId" : "value": $0.0, "name": $0.1, "description": $0.2] }
    let state: [String: Any] = legacy
      ? ["models": ["currentModelId": "opus[1m]", "availableModels": options]]
      : ["configOptions": [["id": "model", "category": "model", "currentValue": "opus[1m]", "options": options]]]
    var payload = state
    payload["sessionId"] = "context-selection"
    let session = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    for runtime in [AgentRuntimeKind.claudeCode, .codex] {
      let fixture = try ACPHarnessFixture(kind: runtime, initialize: #"{"protocolVersion":2}"#,
        session: session, extras: [:])
      defer { fixture.remove() }
      let client = try await fixture.client()
      let initialized = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
      let config = initialized.configuration
      #expect(config.model == "opus[1m]")
      #expect(config.modelOptions == rows.map(\.0))
      func metadata(selected: String) -> LocalACPSessionMetadata {
        LocalACPSessionMetadata(sessionKey: "fixture", model: selected, thinking: nil,
          modelOptions: config.modelOptions, modelOptionMetadata: config.modelOptionMetadata)
      }
      if runtime == .claudeCode {
        let current = metadata(selected: "opus[1m]")
        #expect(current.selectableModels == ["default", "sonnet", "claude-fable-5-1[1m]", "opus[1m]", "haiku", "claude-opus-4-8", "claude-opus-4-8-20260101"])
        #expect(current.selectableModels.map { config.modelOptionMetadata[$0]?.name } ==
          ["default", "Sonnet 5", "Fable 5.1", "Opus 5", "Haiku 4.5", "Opus 4.8", "Opus 4.8"])
        #expect(metadata(selected: "sonnet").selectableModels[3] == "opus")
        #expect(config.modelOptionMetadata["opus"]?.modelGroup != config.modelOptionMetadata["claude-opus-4-8"]?.modelGroup)
      } else {
        #expect(metadata(selected: "opus[1m]").selectableModels == rows.map(\.0))
        #expect(config.modelOptionMetadata["opus[1m]"]?.name == "Opus (1M context)")
      }
      await client.shutdown()
      #expect(!(try fixture.log()).contains("session/set_"))
    }
  }


  @Test(arguments: [AgentRuntimeKind.codex, .claudeCode, .grokBuild])
  func modelAndThinkingSelectionFollowsAdvertisedOptions(kind: AgentRuntimeKind) async throws {
    let withEffort = #"{"configOptions":[{"id":"model","category":"model","currentValue":"with-effort","options":[{"value":"with-effort","name":"Same supplied label"},{"value":"no-effort","name":"Same supplied label"}]},{"id":"effort","category":"thought_level","currentValue":"low","options":[{"value":"low","name":"Low effort"},{"value":"high","name":"High effort"}]}]}"#
    let withoutEffort = #"{"configOptions":[{"id":"model","category":"model","currentValue":"no-effort","options":[{"value":"with-effort","name":"Same supplied label"},{"value":"no-effort","name":"Same supplied label"}]}]}"#
    let highEffort = withEffort.replacingOccurrences(of: #""currentValue":"low""#, with: #""currentValue":"high""#)
    let fixture = try ACPHarnessFixture(kind: kind, initialize: #"{"protocolVersion":2}"#,
      session: #"{"sessionId":"selection","configOptions":[]}"#,
      extras: [:],
      setConfigShell: """
        case "$request" in
          *'"value":{'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"Invalid params"}}\\n' "$id" ;;
          *'"value":"no-effort"'*) respond "$id" '\(withoutEffort)' ;;
          *'"value":"high"'*) respond "$id" '\(highEffort)' ;;
          *) respond "$id" '\(withEffort)' ;;
        esac
        """, initialConfiguration: withEffort)
    defer { fixture.remove() }
    let client = try await fixture.client()
    _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
    let noEffort = try await client.setSessionConfiguration(model: "no-effort")
    #expect(noEffort.model == "no-effort")
    #expect(noEffort.thinking == nil && noEffort.thinkingOptions.isEmpty)
    #expect(noEffort.thinkingOptionMetadata.isEmpty)
    #expect(noEffort.modelOptionMetadata["no-effort"]?.name == "Same supplied label")
    do {
      _ = try await client.setSessionConfiguration(thinking: "high")
      Issue.record("A removed thinking option remained writable")
    } catch LocalACPClientError.unsupportedConfiguration { }
    let restored = try await client.setSessionConfiguration(model: "with-effort", thinking: "high")
    #expect(restored.model == "with-effort" && restored.thinking == "high")
    #expect(restored.thinkingOptions == ["low", "high"])
    #expect(restored.thinkingOptionMetadata["high"]?.name == "High effort")
    #expect(restored.modelOptionMetadata.keys.sorted() == ["no-effort", "with-effort"])
    await client.shutdown()
    let log = try fixture.log()
    // Verified against Grok 1.0.24's executable: unlike its installed docs,
    // the wire schema uses a plain string, as do the other ACP adapters.
    #expect(log.contains(#""value":"high""#))
    #expect(!log.contains(#""value":{"#))
  }

  @Test func grokCapturesVendorState() async throws {
    try await review(
      .grokBuild,
      initialize: #"{"protocolVersion":2,"agentCapabilities":{"loadSession":false}}"#,
      session: #"{"sessionId":"grok-session","modelState":{"currentModelId":"grok","currentReasoningEffort":"high","availableModels":[{"modelId":"grok"}]}}"#,
      extras: [:], expected: []
    ) { configuration in
      #expect(configuration.model == "grok")
      #expect(configuration.thinking == "high")
    }
  }


  @Test("built-in replacement chunks are assembled before admission and preserve boundaries")
  func builtInSnapshotWireReplay() async throws {
    let fixture = try ACPHarnessFixture(kind: .defaultAgent,
      initialize: #"{"protocolVersion":2}"#, session: #"{"sessionId":"snapshots"}"#, extras: ["woven/configure": "{}"], promptOverride: """
        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"abc"}}}}'
        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"x"},"_meta":{"wovenAssistantSnapshot":true,"wovenSnapshotStart":true,"wovenSnapshotEnd":false}}}}'
        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"yz"},"_meta":{"wovenAssistantSnapshot":true,"wovenSnapshotStart":false,"wovenSnapshotEnd":true}}}}'
        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"old thought"},"_meta":{"wovenThoughtID":"thought"}}}}'
        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":""},"_meta":{"wovenThoughtID":"thought","wovenThoughtSnapshot":true,"wovenSnapshotStart":true,"wovenSnapshotEnd":true}}}}'
        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"woven_assistant_boundary"}}}'
        respond "$id" '{"stopReason":"end_turn"}'; continue
        """)
    defer { fixture.remove() }
    let client = try await fixture.client()
    _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil,
      title: nil, systemPrompt: nil)
    let events = ACPReviewEvents()
    #expect(try await client.prompt("Replay") { await events.record($0) } == .endTurn)
    await client.shutdown()
    let values = await events.values()
    let snapshots = values.compactMap { event -> String? in
      if case .assistantSnapshot(let text) = event { return text }; return nil
    }
    #expect(snapshots == ["xyz"])
    #expect(values.contains { if case .assistantBoundary = $0 { return true }; return false })
    let thoughts = values.compactMap { event -> AgentRunActivity? in
      if case .activity(let activity, _) = event, activity.kind == .thought { return activity }; return nil
    }
    #expect(thoughts.count == 3)
    #expect(thoughts[1].content == "")
    #expect(thoughts[1].contentIsDelta == false)
    #expect(thoughts.first?.merging(thoughts[1]).content == "")
    #expect(thoughts.last?.status == "completed")
    #expect(thoughts.last?.id == thoughts.first?.id)
  }

  @Test func stoppedDispatchFenceNeverWritesPromptAfterHistorySuspension() async throws {
    let fixture = try ACPHarnessFixture(kind: .codex, initialize: #"{"protocolVersion":1}"#,
      session: #"{"sessionId":"stopped"}"#, extras: [:])
    defer { fixture.remove() }
    let fence = AgentDispatchFence()
    let client = try await fixture.client { direction, data in
      guard direction == "out",
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["method"] as? String == "session/prompt" else { return }
      fence.cancel()
    }
    _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
    do {
      _ = try await client.prompt("Never send", dispatchFence: fence)
      Issue.record("A stopped dispatch fence must reject the prompt before transport")
    } catch LocalACPClientError.activeInputUnsupported { }
    #expect(!fence.hasDispatched)
    #expect(await client.activePromptRequestCount == 0)
    await client.shutdown()
    #expect(!(try fixture.log()).contains(#""method":"session/prompt""#))
  }

  private func review(
    _ kind: AgentRuntimeKind, initialize: String, session: String,
    extras: [String: String], expected: [String], existingSessionID: String? = nil,
    check: (LocalACPSessionConfiguration) -> Void
  ) async throws {
    let fixture = try ACPHarnessFixture(kind: kind, initialize: initialize,
                                        session: session, extras: extras)
    defer { fixture.remove() }
    let client = try await fixture.client()
    let initialized = try await client.initializeSession(
      workingDirectory: fixture.root, existingSessionID: existingSessionID,
      title: "Fixture", systemPrompt: "System fixture"
    )
    check(initialized.configuration)
    let events = ACPReviewEvents()
    #expect(try await client.prompt("prompt") { await events.record($0) } == .endTurn)
    let streamed = await events.values()
    guard case .activity(let trailing, let appends)? = streamed.last else {
      Issue.record("The prompt should leave its trailing reasoning phase open until run settlement")
      await client.shutdown()
      return
    }
    #expect(trailing.kind == .thought && trailing.phase == "update" && trailing.status == "running")
    #expect(appends)
    let settled = streamed + [.activity(AgentRunActivity(
      id: trailing.id, kind: .thought, phase: "end", title: "Thinking", status: "completed"
    ), appendsContent: false)]
    await client.finishRun()
    #expect(await events.values() == settled)
    await client.finishRun()
    #expect(await events.values() == settled)
    await client.shutdown()
    #expect(await events.values() == settled)
    let log = try fixture.log()
    for marker in expected { #expect(log.contains(marker)) }
    try await assertStream(events)
  }

  @Test(arguments: [AgentRuntimeKind.defaultAgent, .codex, .claudeCode, .grokBuild])
  func liveToolOutputArrivesBeforePromptCompletion(kind: AgentRuntimeKind) async throws {
    let gate = FileManager.default.temporaryDirectory.appending(path: "acp-stream-release-\(UUID())")
    defer { try? FileManager.default.removeItem(at: gate) }
    let fixture = try ACPHarnessFixture(kind: kind, initialize: #"{"protocolVersion":2}"#,
      session: #"{"sessionId":"streaming"}"#, extras: ["woven/configure": "{}"], promptOverride: """
        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"shell","kind":"execute","title":"Shell"}}}'
        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"shell","status":"in_progress","content":[{"type":"content","content":{"type":"text","text":"progress one 🧵"}}]}}}'
        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"shell","status":"in_progress","content":[]}}}'
        while [ ! -f '\(gate.path)' ]; do sleep 0.02; done
        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"shell","status":"completed","content":[{"type":"content","content":{"type":"text","text":"progress two"}}]}}}'
        respond "$id" '{"stopReason":"end_turn"}'; continue
        """)
    defer { fixture.remove() }
    let client = try await fixture.client()
    _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil, title: nil)
    let events = ACPReviewEvents()
    let run = Task { try await client.prompt("Stream fixture output") { await events.record($0) } }
    let deadline = Date().addingTimeInterval(3)
    var tools: [AgentRunActivity] = []
    repeat {
      tools = await events.values().compactMap { event in
        if case .activity(let activity, _) = event, activity.kind == .tool { return activity }; return nil
      }
      if tools.count >= 3 { break }
      try await Task.sleep(for: .milliseconds(10))
    } while Date() < deadline
    // Release before assertions/cleanup, even if live delivery regresses.
    try Data().write(to: gate)
    #expect(tools.contains { $0.status == "in_progress" && $0.content == "progress one 🧵" })
    #expect(!tools.contains { $0.status == "completed" })
    #expect(tools.last?.content == "")
    if tools.count >= 3 { #expect(tools[1].merging(tools[2]).content == "") }
    #expect(try await run.value == .endTurn)
    await client.shutdown()
  }


  private func assertStream(_ events: ACPReviewEvents) async throws {
    let values = await events.values()
    let thoughts = values.compactMap { event -> AgentRunActivity? in
      guard case .activity(let activity, _) = event, activity.kind == .thought else { return nil }
      return activity
    }
    let chunks = thoughts.filter { $0.phase != "end" }
    #expect(chunks.map(\.content) == ["first ", "second", " trailing\n"])
    #expect(Set(chunks.map(\.id)).count == 3)
    #expect(thoughts.map(\.phase) == ["update", "end", "update", "end", "update", "end"])
    #expect(Set(thoughts.filter { $0.phase == "end" }.map(\.id)) == Set(chunks.map(\.id)))
    let tools = values.compactMap { event -> AgentRunActivity? in
      guard case .activity(let activity, _) = event, activity.kind == .tool else { return nil }
      return activity
    }
    #expect(tools.map(\.phase) == ["start", "end"])
    #expect(tools.last?.content == " result ")
    let plans = values.compactMap { event -> AgentRunActivity? in
      guard case .activity(let activity, _) = event, activity.kind == .plan else { return nil }
      return activity
    }
    #expect(plans.map(\.phase) == ["update", "clear"])
    #expect(plans.count == 2 && plans[0].merging(plans[1]).planEntries.isEmpty)
  }
}

private actor ACPReviewEvents {
  private var events: [LocalACPEvent] = []
  func record(_ event: LocalACPEvent) { events.append(event) }
  func values() -> [LocalACPEvent] { events }
}

private struct ACPHarnessFixture {
  let root: URL
  let executable: URL
  let logURL: URL
  let kind: AgentRuntimeKind

  init(kind: AgentRuntimeKind, initialize: String, session: String,
       extras: [String: String],
       setConfigShell: String? = nil, initialConfiguration: String? = nil,
       promptOverride: String? = nil) throws {
    self.kind = kind
    root = FileManager.default.temporaryDirectory.appending(path: "acp-harness-\(UUID())")
    executable = root.appending(path: "adapter")
    logURL = root.appending(path: "requests.log")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let extraCases = extras.map { method, response in
      "*'\"method\":\"\(method)\"'*) respond \"$id\" '\(response)' ;;"
    }.joined(separator: "\n")
    let sessionResponse = initialConfiguration.map {
      $0.replacingOccurrences(of: "{", with: #"{"sessionId":"selection","#,
        options: [.anchored])
    } ?? session
    let configCase = setConfigShell.map { "*'\"method\":\"session/set_config_option\"'*) " + $0 + " ;;" } ?? ""
    let script = """
      #!/bin/sh
      respond() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$1" "$2"; }
      record_request() { printf '%s\\n' "$1" >> '\(logURL.path)'; }
      while IFS= read -r request; do
        record_request "$request"
        request=$(printf '%s' "$request" | sed 's#\\\\/#/#g')
        id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        case "$request" in
          *'"method":"initialize"'*) respond "$id" '\(initialize)' ;;
          *'"method":"session/new"'*|*'"method":"session/load"'*) respond "$id" '\(sessionResponse)' ;;
          *'"method":"session/prompt"'*)
            \(promptOverride ?? "")
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"config_option_update","configOptions":[{"id":"model","category":"model","currentValue":"changed-model","options":[{"value":"changed-model"}]}]}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review changes"}]}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review changes"}]}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"first "}}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"tool","kind":"shell","title":"Shell"}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"tool","kind":"shell","status":"completed","content":[{"type":"content","content":{"text":" result "}}]}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"second"}}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"plan","entries":[{"content":"Inspect","status":"pending"}]}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"plan","entries":[]}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":" trailing\\n"}}}}'
            respond "$id" '{"stopReason":"end_turn"}' ;;
          \(configCase)
          \(extraCases)
        esac
      done
      """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  @MainActor func client(historyRecorder: WorkspaceWireRecorder? = nil) throws -> LocalACPClient {
    var launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: kind, executableURL: executable, arguments: [])
    launch.historyRecorder = historyRecorder
    let accounts = ProviderAccountCoordinator(refresh: { scopes in
      Dictionary(uniqueKeysWithValues: scopes.map {
        ($0, DefaultAgentPayload(config: .init(), credentials: [:], workspace: $0))
      })
    }, version: { 0 }, configurationVersion: { 0 }, scopeVersion: { 0 }, reconfigure: { $0 })
    return try LocalACPClient.start(launch: launch, workingDirectory: root, accountCoordinator: accounts)
  }
  func log() throws -> String {
    try String(contentsOf: logURL, encoding: .utf8)
      .replacingOccurrences(of: "\\/", with: "/")
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
