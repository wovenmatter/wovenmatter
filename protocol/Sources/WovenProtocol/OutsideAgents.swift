import Foundation

// Agents outside Woven Matter on the same machine reach the Woven MCP the way
// Woven's own runtimes do: they start the stdio bridge to this server's tool
// socket. The socket only opens for this machine's user, so nothing more is
// needed; the switch decides whether that server answers them, and with which
// groups of tools.

/// Whether this machine's server answers outside agents, the groups of tools
/// they may use, and the stdio MCP command they start.
public struct OutsideAgentAccess: Codable, Sendable, Hashable {
  public var isEnabled: Bool
  public var groups: Set<ToolGroup>
  /// A shell command line: Node, the bridge and the tool socket.
  public var command: String

  public init(isEnabled: Bool, groups: Set<ToolGroup>, command: String) {
    self.isEnabled = isEnabled
    self.groups = groups
    self.command = command
  }
}

/// Reads this machine's outside-agent access. Only the UI on this machine asks.
public struct GetOutsideAgentAccess: Request {
  public static let method = "tools.outside"
  public typealias Reply = OutsideAgentAccess
  public init() {}
}

/// Sets this machine's outside-agent access: on or off, and the groups.
public struct SetOutsideAgentAccess: Request {
  public static let method = "tools.outside.set"
  public typealias Reply = OutsideAgentAccess
  public var isEnabled: Bool
  public var groups: Set<ToolGroup>
  public init(isEnabled: Bool, groups: Set<ToolGroup>) {
    self.isEnabled = isEnabled
    self.groups = groups
  }
}
