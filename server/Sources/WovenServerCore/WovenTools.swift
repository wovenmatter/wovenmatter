import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

/// One Woven tool: what an agent sees (name, description, input schema) and
/// how this server carries it out. Adding a tool is one entry in `catalog`.
package struct WovenTool: Sendable {
  package var name: String
  package var description: String
  /// The JSON Schema of its arguments.
  package var input: JSONValue
  /// It changes nothing.
  package var readOnly = false
  /// Offered to bots too; bots have their own tools for bots and the Forum.
  package var forBots = true
  /// A session may use it when it may use one of these; none means always.
  package var groups: Set<ToolGroup> = []
  package var run: @Sendable (ToolRequest) async throws -> ToolResult

  package init(name: String, description: String, input: JSONValue, readOnly: Bool = false, forBots: Bool = true,
               groups: Set<ToolGroup> = [], run: @escaping @Sendable (ToolRequest) async throws -> ToolResult) {
    self.name = name
    self.description = description
    self.input = input
    self.readOnly = readOnly
    self.forBots = forBots
    self.groups = groups
    self.run = run
  }
}

/// One call being carried out.
package struct ToolRequest: Sendable {
  package let arguments: Arguments
  package let caller: ToolCaller
  package let tools: WovenTools
  package let name: String
  /// It came from another machine's server.
  package let forwarded: Bool

  /// Sends this same call to `machineID`'s server when it is not this
  /// machine, and returns its result; nil means carry it out here. A call
  /// that came from another server is never sent on again.
  package func forward(to machineID: String) async throws -> ToolResult? {
    try await tools.forward(self, to: machineID)
  }
}

/// A tool's arguments, read with messages an agent can act on.
package struct Arguments: Sendable {
  package let value: JSONValue

  package func string(_ key: String) throws -> String {
    guard let text = optionalString(key), !text.isEmpty else { throw ToolFailure("Give `\(key)`.") }
    return text
  }

  package func optionalString(_ key: String) -> String? { value[key]?.string }
  package func int(_ key: String) -> Int? { value[key]?.int }
  package func bool(_ key: String) -> Bool? { value[key]?.bool }
  package subscript(_ key: String) -> JSONValue? { value[key] }
}

/// What a machine adds to the Woven tools: the other machines' servers, and
/// its databases. A device has none; what needs them fails there plainly.
package protocol ToolsHost: Sendable {
  /// Carries `call` out on `owner`'s server, named `name`, and returns its result.
  func forward(_ call: ToolRequest, to owner: String, named name: String) async throws -> ToolResult
  /// What the sessions of each other machine in `machineIDs` that answers are doing now.
  func runStates(of machineIDs: Set<String>) async -> [String: [String: SessionRunState]]
  /// The databases a note or app may link to.
  func databases() async throws -> [Database]
}

/// The Woven MCP on this host: the one catalog, carried out here, with the
/// calls that concern another machine handed to `host`.
package final class WovenTools: Sendable {
  package let library: Library
  package let sessions: SessionManager
  package let host: (any ToolsHost)?
  package let catalog: [WovenTool]
  private let byName: [String: WovenTool]

  /// `catalog` is the core's tools (`coreTools`), with a machine's own.
  package init(library: Library, sessions: SessionManager, catalog: [WovenTool], host: (any ToolsHost)?) {
    self.library = library
    self.sessions = sessions
    self.host = host
    self.catalog = catalog
    byName = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
  }

  package var machineID: String { library.machineID }

  /// The catalog as MCP's `tools/list` describes it; `enabled` leaves out
  /// the tools of the other groups.
  package func listing(forBots: Bool = false, enabled: Set<ToolGroup>? = nil) -> [JSONValue] {
    offered(forBots: forBots, enabled: enabled).map { tool in
      .object(["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.input,
               "annotations": .object(["readOnlyHint": .bool(tool.readOnly)])])
    }
  }

  /// The tools of the catalog a caller is offered.
  package func offered(forBots: Bool = false, enabled: Set<ToolGroup>? = nil) -> [WovenTool] {
    catalog.filter { (!forBots || $0.forBots) && Self.allowed($0, enabled) }
  }

  /// Carries out one call. Every failure comes back as an error result.
  package func call(_ name: String, arguments: JSONValue, caller: ToolCaller, forwarded: Bool = false) async -> ToolResult {
    guard let tool = byName[name] else { return .error("Woven has no tool \(name).") }
    guard tool.forBots || caller.botID == nil else { return .error("Bots cannot use \(name).") }
    // A forwarded call was allowed by the caller's own server.
    if !forwarded, let sessionID = caller.sessionID, !Self.allowed(tool, await enabledGroups(sessionID: sessionID)),
       let group = tool.groups.min(by: { $0.rawValue < $1.rawValue }) {
      return .error("\(group.title) is disabled for this session.")
    }
    let arguments: JSONValue = if case .object = arguments { arguments } else { .object([:]) }
    let call = ToolRequest(arguments: Arguments(value: arguments), caller: caller, tools: self, name: name, forwarded: forwarded)
    do {
      return try await tool.run(call)
    } catch let failure as ToolFailure {
      return .error(failure.description)
    } catch {
      return .error(ProtocolError(error).message)
    }
  }

  /// The groups a session may use: its own choice, else its runtime's
  /// defaults for new chats on this machine or every machine, else the
  /// defaults for every new chat.
  package func enabledGroups(sessionID: String) async -> Set<ToolGroup> {
    guard let session = try? await library.session(sessionID) else { return [] }
    if let tools = session.tools { return tools }
    let runtime = session.runtime.rawValue
    let own = try? await library.setting("agentDefaults.\(runtime).\(session.machineID)")
    let shared = try? await library.setting("agentDefaults.\(runtime)")
    if let names = (own ?? shared)?.value["tools"]?.array { return Self.groups(names) }
    if let names = (try? await library.setting(ToolGroup.defaultsSetting))?.value.array { return Self.groups(names) }
    return ToolGroup.standard
  }

  package static func allowed(_ tool: WovenTool, _ enabled: Set<ToolGroup>?) -> Bool {
    guard let enabled, !tool.groups.isEmpty else { return true }
    return !tool.groups.isDisjoint(with: enabled)
  }

  private static func groups(_ names: [JSONValue]) -> Set<ToolGroup> {
    Set(names.compactMap { $0.string.flatMap(ToolGroup.init(rawValue:)) })
  }

  package func forward(_ call: ToolRequest, to owner: String) async throws -> ToolResult? {
    guard owner != machineID else { return nil }
    let machine = try? await library.machine(owner)
    let name = machine?.name ?? "That machine"
    guard !call.forwarded else {
      throw ToolFailure("This call was forwarded to the wrong machine; \(name) owns it.")
    }
    if machine?.platform.isDevice == true {
      throw ToolFailure(await notOwner(owner, "", library: library).message)
    }
    guard let host else { throw ToolFailure("That is on \(name), which cannot be reached from here.") }
    return try await host.forward(call, to: owner, named: name)
  }

  /// How the server's own handlers see a tool's request: a local caller.
  package var localCaller: Caller {
    Caller(origin: .local, hello: Hello(role: .ui, machine: Machine(id: "woven-tools", name: "Woven tools"), appVersion: ""))
  }
}

/// Where a part made before the catalog finds it once it exists.
package final class ToolsLink: Sendable {
  private let tools = Mutex<WovenTools?>(nil)
  package init() {}
  package func attach(_ value: WovenTools) { tools.withLock { $0 = value } }
  package var current: WovenTools? { tools.withLock { $0 } }
}
