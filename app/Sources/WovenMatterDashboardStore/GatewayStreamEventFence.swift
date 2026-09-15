import WovenMatterClient

/// Fences replayed and mirrored Gateway frames within one remote run. Sequence
/// numbers are source-local: `agent` and `chat` may both start at one, while
/// `session.tool` mirrors the `agent/tool` source.
struct GatewayStreamEventFence: Sendable {
  enum Decision: Equatable, Sendable {
    case accept
    case duplicate
    case gap
  }

  private var sequences: [String: Int] = [:]

  mutating func evaluate(
    _ event: OpenClawGatewayEvent,
    remoteRunID: String
  ) -> Decision {
    let payload = event.payload?.objectValue
    let name = event.name == "session.tool" ? "agent" : event.name
    let stream = payload?["stream"]?.stringValue
      ?? (event.name == "session.tool" ? "tool" : "")
    let key = "\(remoteRunID):\(name):\(stream)"
    var decision = Decision.accept
    if let sequence = payload?["seq"]?.intValue {
      if let previous = sequences[key] {
        if sequence <= previous { return .duplicate }
        if sequence > previous + 1 { decision = .gap }
      }
      sequences[key] = sequence
    }
    return decision
  }
}

/// OpenClaw can publish the same assistant stream on `agent` and `chat`.
/// Keep ordered deltas from the first source until a cumulative snapshot makes
/// `chat` authoritative. Repeated text on the owning source remains meaningful.
struct GatewayAssistantStreamSource: Sendable {
  private enum Owner { case agent, chat }
  private var owners: [String: Owner] = [:]
  private var terminalRuns: Set<String> = []

  mutating func accepts(
    _ event: OpenClawGatewayEvent,
    runID: String,
    update: OpenClawGatewayEventProjection.AssistantUpdate,
    terminal: Bool
  ) -> Bool {
    guard !terminalRuns.contains(runID) else { return false }
    if terminal {
      terminalRuns.insert(runID)
      return true
    }
    let source: Owner = event.name == "chat" ? .chat : .agent
    switch (owners[runID], source, update) {
    case (nil, _, _):
      owners[runID] = source
      return true
    case (.agent, .agent, _), (.chat, .chat, _):
      return true
    case (.agent, .chat, .replace):
      owners[runID] = .chat
      return true
    case (.agent, .chat, .append), (.chat, .agent, _):
      return false
    }
  }

  mutating func finish(runID: String) {
    terminalRuns.insert(runID)
  }
}
