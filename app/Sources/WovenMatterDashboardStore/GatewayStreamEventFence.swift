import WovenMatterClient

/// Sequence numbers belong to a source stream and remote run, not to the UI's
/// combined transcript. Mirrored tool events share one fence. Connection-level
/// sequence numbers are deliberately not retained across reconnects.
struct GatewayStreamEventFence: Sendable {
  private var sequences: [String: Int] = [:]
  private var terminalRuns: Set<String> = []

  mutating func accept(_ event: OpenClawGatewayEvent, remoteRunID: String, terminal: Bool) -> Bool {
    guard !terminalRuns.contains(remoteRunID) else { return false }
    let payload = event.payload?.objectValue
    let name = event.name == "session.tool" ? "agent" : event.name
    let stream = payload?["stream"]?.stringValue ?? (event.name == "session.tool" ? "tool" : "")
    let key = "\(remoteRunID):\(name):\(stream)"
    if let sequence = payload?["seq"]?.intValue {
      if let previous = sequences[key], sequence < previous || (sequence == previous && !terminal) { return false }
      sequences[key] = sequence
    }
    if terminal { terminalRuns.insert(remoteRunID) }
    return true
  }
}

/// A Gateway can mirror assistant output on both surfaces. Prefer cumulative
/// chat snapshots once available; never append mirrored agent/chat deltas twice.
struct GatewayAssistantStreamSource: Sendable {
  private var owners: [String: String] = [:]

  mutating func accepts(_ event: OpenClawGatewayEvent, runID: String,
                       update: OpenClawGatewayEventProjection.AssistantUpdate,
                       terminal: Bool) -> Bool {
    if terminal { return true }
    let source = event.name == "chat" ? "chat" : "agent"
    if source == "agent", owners[runID] == "chat" { return false }
    if source == "chat", owners[runID] == "agent", case .append = update {
      // Without a cumulative snapshot there is no safe correlation of mirrored
      // deltas. Keep the already-owned agent source until chat can repair it.
      return false
    }
    owners[runID] = source
    return true
  }
}
