import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct ACPHarnessStreamingReviewTests {

  @Test(arguments: [AgentRuntimeKind.codex, .claudeCode, .grokBuild, .cursor], [1, 2])
  func slashCommandsPreserveArgumentsAndReuseSessionAfterEmptyOrRejectedResults(kind: AgentRuntimeKind, protocolVersion: Int) async throws {
    let fixture = try ACPHarnessFixture(kind: kind, initialize: "{\"protocolVersion\":\(protocolVersion)}",
      session: #"{"sessionId":"commands","availableCommands":[{"name":"native"}]}"#,
      extras: ["authenticate": "{}", "cursor/list_available_models": "{}"],
      promptOverride: """
        case "$request" in
          *'/native '* ) respond "$id" '{"stopReason":"end_turn"}'; continue ;;
          *'/denied'* ) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"Command rejected"}}\\n' "$id"; continue ;;
        esac
        """)
    defer { fixture.remove() }
    let client = try fixture.client()
    _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil,
      title: nil, systemPrompt: "Agent instructions")
    let input = "/native keep  spacing\nand this line"
    let events = ACPReviewEvents()
    #expect(try await client.prompt(input) { await events.record($0) } == .endTurn)
    #expect(await events.values().isEmpty)
    do {
      _ = try await client.prompt("/denied")
      Issue.record("Rejected command must report its native error")
    } catch LocalACPClientError.agent(let code, let message) {
      #expect(code == -32602 && message == "Command rejected")
    }
    #expect(try await client.prompt("ordinary message") == .endTurn)
    await client.shutdown()
    let requests = try fixture.log().split(separator: "\n").map {
      try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    let prompts = requests.filter { $0["method"] as? String == "session/prompt" }
    let params = prompts.first?["params"] as? [String: Any]
    let blocks = params?["prompt"] as? [[String: Any]]
    #expect(blocks?.first?["text"] as? String == input)
    #expect(prompts.count == 3)
    let lastParams = prompts.last?["params"] as? [String: Any]
    let lastBlocks = lastParams?["prompt"] as? [[String: Any]]
    let expectedText = protocolVersion == 1
      ? "[System]\nAgent instructions\n\nordinary message" : "ordinary message"
    #expect(lastBlocks?.first?["text"] as? String == expectedText)
    let sessions = requests.filter { $0["method"] as? String == "session/new" }
    #expect(sessions.count == 1)
    if protocolVersion == 2 {
      let sessionParams = sessions.first?["params"] as? [String: Any]
      #expect(sessionParams?["systemPrompt"] as? String == "Agent instructions")
    }
  }

  @Test func overlappingPromptsReserveInstructionsBeforeHistorySuspends() async throws {
    let fixture = try ACPHarnessFixture(kind: .cursor, initialize: #"{"protocolVersion":1}"#,
      session: #"{"sessionId":"overlap"}"#, extras: ["authenticate": "{}", "cursor/list_available_models": "{}"])
    defer { fixture.remove() }
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    defer { release.continuation.finish() }
    let client = try fixture.client { direction, data in
      guard direction == "out",
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["method"] as? String == "session/prompt" else { return }
      let params = value["params"] as? [String: Any]
      let blocks = params?["prompt"] as? [[String: Any]]
      if (blocks?.first?["text"] as? String)?.hasSuffix("first") == true {
        entered.continuation.yield(())
        var iterator = release.stream.makeAsyncIterator()
        await iterator.next()
      }
    }
    _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil,
      title: nil, systemPrompt: "Unique initial instructions")
    let events = ACPReviewEvents()
    let first = Task { try await client.prompt("first") { await events.record($0) } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    // Active input must inherit the first prompt's handlers even while its
    // outbound history is suspended, and it must not repeat the prefix.
    let second = Task { try await client.beginActiveInput("second") }
    let deadline = ContinuousClock.now + .seconds(60)
    while await client.activePromptRequestCount != 2 {
      guard ContinuousClock.now < deadline else { throw LocalACPClientError.processExited }
      try await Task.sleep(for: .milliseconds(1))
    }
    release.continuation.yield(())
    #expect(try await first.value == .endTurn)
    let receipt = try await second.value
    _ = try await receipt.completion.value
    #expect(await client.activePromptRequestCount == 0)
    #expect(await events.values().count > 0)
    await client.shutdown()
    #expect(try fixture.log().components(separatedBy: "Unique initial instructions").count - 1 == 1)
  }

  @Test func stoppedDispatchFenceNeverWritesPromptAfterHistorySuspension() async throws {
    let fixture = try ACPHarnessFixture(kind: .codex, initialize: #"{"protocolVersion":1}"#,
      session: #"{"sessionId":"stopped"}"#, extras: [:])
    defer { fixture.remove() }
    let fence = AgentDispatchFence()
    let client = try fixture.client { direction, data in
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

  @Test func rejectedHistoryWriteReleasesInitialInstructionsForRetry() async throws {
    actor Recorder {
      var reject = true
      func record(_ direction: String, _ data: Data) throws {
        guard direction == "out", reject,
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["method"] as? String == "session/prompt" else { return }
        reject = false
        throw Failure.expected
      }
    }
    enum Failure: Error { case expected }
    let fixture = try ACPHarnessFixture(kind: .codex, initialize: #"{"protocolVersion":1}"#,
      session: #"{"sessionId":"retry"}"#, extras: [:])
    defer { fixture.remove() }
    let recorder = Recorder()
    let client = try fixture.client { try await recorder.record($0, $1) }
    _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: nil,
      title: nil, systemPrompt: "Retry instructions")
    await #expect(throws: Failure.expected) { try await client.prompt("rejected") }
    #expect(await client.activePromptRequestCount == 0)
    #expect(try await client.prompt("retry") == .endTurn)
    await client.shutdown()
    #expect(try fixture.log().components(separatedBy: "Retry instructions").count - 1 == 1)
  }

  @Test(arguments: [AgentRuntimeKind.codex, .claudeCode, .grokBuild, .cursor])
  func modelAndThinkingSelectionFollowsAdvertisedOptions(kind: AgentRuntimeKind) async throws {
    let withEffort = #"{"configOptions":[{"id":"model","category":"model","currentValue":"with-effort","options":[{"value":"with-effort","name":"Same supplied label"},{"value":"no-effort","name":"Same supplied label"}]},{"id":"effort","category":"thought_level","currentValue":"low","options":[{"value":"low","name":"Low effort"},{"value":"high","name":"High effort"}]}]}"#
    let withoutEffort = #"{"configOptions":[{"id":"model","category":"model","currentValue":"no-effort","options":[{"value":"with-effort","name":"Same supplied label"},{"value":"no-effort","name":"Same supplied label"}]}]}"#
    let highEffort = withEffort.replacingOccurrences(of: #""currentValue":"low""#, with: #""currentValue":"high""#)
    let fixture = try ACPHarnessFixture(kind: kind, initialize: #"{"protocolVersion":2}"#,
      session: #"{"sessionId":"selection","configOptions":[]}"#,
      extras: ["authenticate": "{}", "cursor/list_available_models": "{}"],
      setConfigShell: """
        case "$request" in
          *'"value":{'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"Invalid params"}}\\n' "$id" ;;
          *'"value":"no-effort"'*) respond "$id" '\(withoutEffort)' ;;
          *'"value":"high"'*) respond "$id" '\(highEffort)' ;;
          *) respond "$id" '\(withEffort)' ;;
        esac
        """, initialConfiguration: withEffort)
    defer { fixture.remove() }
    let client = try fixture.client()
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

  @Test func claudeSuppliedNamesDescribeAliasesWithoutChangingTheirIDs() async throws {
    try await review(.claudeCode, initialize: #"{"protocolVersion":2}"#,
      session: #"{"sessionId":"labels","configOptions":[{"id":"model","category":"model","currentValue":"opus[1m]","options":[{"group":"aliases","options":[{"value":"sonnet","name":"Sonnet","description":"Provider-selected Sonnet alias"},{"value":"opus[1m]","name":"Opus with 1M context","description":"Provider-selected Opus alias"}]},{"value":"claude-opus-4-8","name":"Claude Opus 4.8","description":"Pinned model"}]},{"id":"effort","category":"thought_level","currentValue":"high","options":[{"value":"high","name":"High","description":"More reasoning"}]}]}"#,
      extras: [:], expected: []) { configuration in
        #expect(configuration.model == "opus[1m]")
        #expect(configuration.modelOptions == ["sonnet", "opus[1m]", "claude-opus-4-8"])
        #expect(configuration.modelOptionMetadata["opus[1m]"]?.name == "Opus with 1M context")
        #expect(configuration.modelOptionMetadata["sonnet"]?.description == "Provider-selected Sonnet alias")
        #expect(configuration.modelOptionMetadata["claude-opus-4-8"]?.name == "Opus 4.8")
        #expect(configuration.thinkingOptionMetadata["high"]?.description == "More reasoning")
        #expect(configuration.selecting(model: "sonnet").modelOptionMetadata == configuration.modelOptionMetadata)
      }
  }

  @Test func oldMetadataDecodesAndCurrentThinkingDoesNotInventSupportedOptions() throws {
    let old = Data(#"{"sessionKey":"old","model":"alias","thinking":"stale","thinkingLevels":["low"],"slashCommands":[]}"#.utf8)
    let metadata = try JSONDecoder().decode(LocalACPSessionMetadata.self, from: old)
    #expect(metadata.modelOptionMetadata == nil)
    #expect(metadata.thinking == "stale")
    #expect(metadata.selectableThinkingLevels == ["low"])
    #expect(LocalACPSessionConfiguration(thinking: "stale", thinkingOptions: []).thinkingOptions.isEmpty)
  }

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
      let client = try fixture.client()
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

  @Test func cursorUsesAuthenticationAndNativeModelDiscovery() async throws {
    try await review(
      .cursor,
      initialize: #"{"protocolVersion":2,"agentCapabilities":{"loadSession":false}}"#,
      session: #"{"sessionId":"cursor-session"}"#,
      extras: [
        "authenticate": #"{}"#,
        "cursor/list_available_models": #"{"models":[{"value":"cursor-model","name":"Cursor supplied name","description":"Native model"}]}"#,
      ],
      expected: ["authenticate", "cursor/list_available_models"]
    ) { configuration in
      #expect(configuration.model == nil)
      #expect(configuration.modelOptions == ["cursor-model"])
      #expect(configuration.modelOptionMetadata["cursor-model"]?.name == "Cursor supplied name")
    }
  }

  @Test func claudeUsesSystemPromptMetadataAndRetainsAdvertisedNativeModes() async throws {
    try await review(
      .claudeCode,
      initialize: #"{"protocolVersion":2,"agentInfo":{"name":"@agentclientprotocol/claude-agent-acp"},"agentCapabilities":{"loadSession":false}}"#,
      session: #"{"sessionId":"claude-session","configOptions":[{"id":"mode","options":[{"value":"auto"}],"currentValue":"default"}]}"#,
      extras: [:], expected: [#""systemPrompt":{"append":"System fixture"}"#]
    ) { configuration in
      #expect(configuration.permission == "default")
      #expect(configuration.permissionOptions == ["auto"])
    }
  }

  @Test func codexLoadsExistingV2SessionAndKeepsIndependentConfiguration() async throws {
    try await review(
      .codex,
      initialize: #"{"protocolVersion":2,"agentCapabilities":{"loadSession":true},"configOptions":[{"id":"model","category":"model","currentValue":"gpt","options":[{"value":"gpt"}]},{"id":"effort","category":"thought_level","currentValue":"high","options":[{"value":"high"}]}]}"#,
      session: #"{"configOptions":[{"id":"model","category":"model","currentValue":"gpt","options":[{"value":"gpt"}]},{"id":"effort","category":"thought_level","currentValue":"high","options":[{"value":"high"}]}]}"#,
      extras: [:], expected: ["session/load"], existingSessionID: "codex-existing"
    ) { configuration in
      #expect(configuration.model == "gpt")
      #expect(configuration.thinking == "high")
    }
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

  private func review(
    _ kind: AgentRuntimeKind, initialize: String, session: String,
    extras: [String: String], expected: [String], existingSessionID: String? = nil,
    check: (LocalACPSessionConfiguration) -> Void
  ) async throws {
    let fixture = try ACPHarnessFixture(kind: kind, initialize: initialize,
                                        session: session, extras: extras)
    defer { fixture.remove() }
    let client = try fixture.client()
    let initialized = try await client.initializeSession(
      workingDirectory: fixture.root, existingSessionID: existingSessionID,
      title: "Fixture", systemPrompt: "System fixture"
    )
    check(initialized.configuration)
    let events = ACPReviewEvents()
    #expect(try await client.prompt("prompt") { await events.record($0) } == .endTurn)
    await client.shutdown()
    let log = try fixture.log()
    for marker in expected { #expect(log.contains(marker)) }
    try await assertStream(events)
  }

  private func assertStream(_ events: ACPReviewEvents) async throws {
    let values = await events.values()
    let thoughts = values.compactMap { event -> AgentRunActivity? in
      guard case .activity(let activity, _) = event, activity.kind == .thought else { return nil }
      return activity
    }
    #expect(thoughts.map(\.content) == ["first ", "second"])
    #expect(thoughts.count == 2 && thoughts[0].id != thoughts[1].id)
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
      while IFS= read -r request; do
        printf '%s\\n' "$request" >> '\(logURL.path)'
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
            respond "$id" '{"stopReason":"end_turn"}' ;;
          \(configCase)
          \(extraCases)
        esac
      done
      """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  func client(historyRecorder: WorkspaceWireRecorder? = nil) throws -> LocalACPClient {
    var launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: kind, executableURL: executable, arguments: [])
    launch.historyRecorder = historyRecorder
    return try LocalACPClient.start(launch: launch, workingDirectory: root)
  }
  func log() throws -> String {
    try String(contentsOf: logURL, encoding: .utf8)
      .replacingOccurrences(of: "\\/", with: "/")
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
