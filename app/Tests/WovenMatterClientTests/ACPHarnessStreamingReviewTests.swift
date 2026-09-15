import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct ACPHarnessStreamingReviewTests {
  @Test func cursorUsesAuthenticationAndNativeModelDiscovery() async throws {
    try await review(
      .cursor,
      initialize: #"{"protocolVersion":2,"agentCapabilities":{"loadSession":false}}"#,
      session: #"{"sessionId":"cursor-session"}"#,
      extras: [
        "authenticate": #"{}"#,
        "cursor/list_available_models": #"{"models":[{"value":"cursor-model"}]}"#,
      ],
      expected: ["authenticate", "cursor/list_available_models"]
    ) { configuration in
      #expect(configuration.model == "cursor-model")
      #expect(configuration.modelOptions == ["cursor-model"])
    }
  }

  @Test func claudeUsesSystemPromptMetadataAndAdvertisedAutoMode() async throws {
    try await review(
      .claudeCode,
      initialize: #"{"protocolVersion":2,"agentInfo":{"name":"@agentclientprotocol/claude-agent-acp"},"agentCapabilities":{"loadSession":false}}"#,
      session: #"{"sessionId":"claude-session","configOptions":[{"id":"mode","options":[{"value":"auto"}],"currentValue":"default"}]}"#,
      extras: ["session/set_config_option": #"{"configOptions":[{"id":"mode","options":[{"value":"auto"}],"currentValue":"auto"}]}"#],
      expected: ["session/set_config_option", #""systemPrompt":{"append":"System fixture"}"#]
    ) { _ in }
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

  @Test func grokCapturesVendorStateAndUsesInterjection() async throws {
    let fixture = try ACPHarnessFixture(
      kind: .grokBuild,
      initialize: #"{"protocolVersion":2,"agentCapabilities":{"loadSession":false}}"#,
      session: #"{"sessionId":"grok-session","modelState":{"currentModelId":"grok","currentReasoningEffort":"high","availableModels":[{"modelId":"grok"}]}}"#,
      extras: [:], holdPromptForInterjection: true
    )
    defer { fixture.remove() }
    let client = try fixture.client()
    let initialized = try await client.initializeSession(workingDirectory: fixture.root,
                                                           existingSessionID: nil, title: nil)
    #expect(initialized.configuration.model == "grok")
    #expect(initialized.configuration.thinking == "high")
    let events = ACPReviewEvents()
    let prompt = Task { try await client.prompt("start") { await events.record($0) } }
    try await fixture.waitFor("session/prompt")
    _ = try await client.beginActiveInput("steer")
    #expect(try await prompt.value == .endTurn)
    await client.shutdown()
    #expect(try fixture.log().contains("_x.ai/interject"))
    try await assertStream(events)
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
       extras: [String: String], holdPromptForInterjection: Bool = false) throws {
    self.kind = kind
    root = FileManager.default.temporaryDirectory.appending(path: "acp-harness-\(UUID())")
    executable = root.appending(path: "adapter")
    logURL = root.appending(path: "requests.log")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let extraCases = extras.map { method, response in
      "*'\"method\":\"\(method)\"'*) respond \"$id\" '\(response)' ;;"
    }.joined(separator: "\n")
    let promptFinish = holdPromptForInterjection ? "" : "respond \"$id\" '{\"stopReason\":\"end_turn\"}'"
    let script = """
      #!/bin/sh
      respond() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$1" "$2"; }
      while IFS= read -r request; do
        printf '%s\\n' "$request" >> '\(logURL.path)'
        request=$(printf '%s' "$request" | sed 's#\\\\/#/#g')
        id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        case "$request" in
          *'"method":"initialize"'*) respond "$id" '\(initialize)' ;;
          *'"method":"session/new"'*|*'"method":"session/load"'*) respond "$id" '\(session)' ;;
          *'"method":"session/prompt"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"first "}}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"tool","kind":"shell","title":"Shell"}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"tool","kind":"shell","status":"completed","content":[{"type":"content","content":{"text":" result "}}]}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"second"}}}}'
            \(promptFinish) ;;
          \(extraCases)
          *'"method":"_x.ai/interject"'*) respond "$id" '{}'; respond "$((id-1))" '{"stopReason":"end_turn"}' ;;
        esac
      done
      """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  }

  func client() throws -> LocalACPClient {
    try LocalACPClient.start(launch: .init(runtimeKind: kind, executableURL: executable, arguments: []),
                             workingDirectory: root)
  }
  func log() throws -> String {
    try String(contentsOf: logURL, encoding: .utf8)
      .replacingOccurrences(of: "\\/", with: "/")
  }
  func waitFor(_ marker: String) async throws {
    for _ in 0..<200 {
      if (try? log().contains(marker)) == true { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw LocalACPClientError.processExited
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
