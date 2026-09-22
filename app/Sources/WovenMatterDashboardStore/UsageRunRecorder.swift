import Foundation
import WovenMatterCore

/// Fast path for turns executed by Woven Matter itself. Provider transcript
/// scans remain the backfill path; a shared dedupe key makes the more exact
/// observation win when both are present.
actor UsageRunRecorder {
  struct Observation: Sendable {
    let runID: String
    let timestamp: Date
    let runtimeKind: AgentRuntimeKind
    let sessionID: String
    let model: String?
    let reasoningLevel: String?
    let agent: String?
    let workspace: String?
    let tokens: UsageTokenCounts
    let costUSD: Double?
  }

  private let store: UsageStore
  private var sequence: Int64

  init(databaseURL: URL) throws {
    store = try UsageStore(databaseURL: databaseURL)
    let wallClock = Int64(Date().timeIntervalSince1970 * 1_000_000)
    let persisted = try store.runtimeSyncState(endpoint: "wovenmatter://local")
      .flatMap { Int64($0.cursor) } ?? 0
    sequence = max(wallClock, persisted)
  }

  func record(_ observation: Observation) throws {
    let next = sequence.addingReportingOverflow(1)
    guard !next.overflow else {
      throw UsageStoreError.step("Woven usage sequence is exhausted")
    }
    sequence = next.partialValue
    let route = Self.route(for: observation.runtimeKind, model: observation.model)
    let event = UsageIngestionEvent(
      id: "\(observation.sessionID):\(observation.runID)",
      sequence: sequence,
      timestamp: observation.timestamp,
      provider: route.provider,
      accountLabel: "Unknown",
      billingProvider: route.billingProvider,
      billingRoute: route.billingRoute,
      model: observation.model ?? "Unknown model",
      reasoningLevel: observation.reasoningLevel,
      harness: observation.runtimeKind.displayName,
      application: "Woven Matter",
      agent: observation.agent,
      workspace: observation.workspace,
      sessionID: observation.sessionID,
      runID: observation.runID,
      tokens: observation.tokens,
      costUSD: observation.costUSD,
      attributionConfidence: observation.model == nil ? .derived : .exact,
      granularity: .turn,
      dedupeKey: "\(observation.sessionID):\(observation.runID)"
    )
    let source = UsageIngestionSource(
      id: "wovenmatter:local",
      displayName: "Woven Matter live runs",
      kind: .wovenMatter,
      location: "This Mac",
      installationID: "wovenmatter-local"
    )
    try store.ingest(
      page: UsageIngestionPage(
        source: source,
        events: [event],
        nextCursor: String(sequence),
        hasMore: false,
        generatedAt: observation.timestamp
      ),
      endpoint: "wovenmatter://local",
      importedAt: observation.timestamp
    )
  }

  private static func route(
    for runtime: AgentRuntimeKind, model: String?
  ) -> (provider: ProviderKind, billingProvider: String, billingRoute: String) {
    if runtime == .defaultAgent {
      switch model?.split(separator: "/").first {
      case "claude-subscription": return (.claude, "Anthropic", "Claude subscription")
      case "anthropic": return (.claude, "Anthropic", "Claude API key")
      case "openai-codex": return (.codex, "OpenAI", "ChatGPT subscription")
      case "openai": return (.codex, "OpenAI", "OpenAI API key")
      case "xai": return (.grok, "xAI", "Grok subscription")
      case "openrouter": return (.openRouter, "OpenRouter", "API key")
      case "opencode-go": return (.openCodeGo, "OpenCode", "OpenCode Go API key")
      default: break
      }
    }
    return switch runtime {
    case .codex: (.codex, "OpenAI", "Codex subscription")
    case .claudeCode: (.claude, "Anthropic", "Claude account")
    case .grokBuild: (.grok, "xAI", "Grok account")
    case .cursor: (.cursor, "Cursor", "Cursor subscription")
    // OpenCode, Pi, OpenClaw, and Hermes are harnesses rather than billing
    // authorities. Their durable histories provide the actual provider route.
    case .defaultAgent, .opencode, .openclaw, .pi, .hermes: (.unknown, "Unknown", "Unknown")
    }
  }
}
