import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

/// One Woven tool: what an agent sees (name, description, input schema) and
/// how this server carries it out. Adding a tool is one entry in `catalog`.
struct WovenTool: Sendable {
  var name: String
  var description: String
  /// The JSON Schema of its arguments.
  var input: JSONValue
  /// It changes nothing.
  var readOnly = false
  /// Offered to bots too; bots have their own tools for bots and the Forum.
  var forBots = true
  /// A session may use it when it may use one of these; none means always.
  var groups: Set<ToolGroup> = []
  var run: @Sendable (ToolRequest) async throws -> ToolResult
}

/// One call being carried out.
struct ToolRequest: Sendable {
  let arguments: Arguments
  let caller: ToolCaller
  let tools: WovenTools
  let name: String
  /// It came from another machine's server.
  let forwarded: Bool

  /// Sends this same call to `machineID`'s server when it is not this
  /// machine, and returns its result; nil means carry it out here. A call
  /// that came from another server is never sent on again.
  func forward(to machineID: String) async throws -> ToolResult? {
    try await tools.forward(self, to: machineID)
  }
}

/// A tool's arguments, read with messages an agent can act on.
struct Arguments: Sendable {
  let value: JSONValue

  func string(_ key: String) throws -> String {
    guard let text = optionalString(key), !text.isEmpty else { throw ToolFailure("Give `\(key)`.") }
    return text
  }

  func optionalString(_ key: String) -> String? { value[key]?.string }
  func int(_ key: String) -> Int? { value[key]?.int }
  func bool(_ key: String) -> Bool? { value[key]?.bool }
  subscript(_ key: String) -> JSONValue? { value[key] }
}

/// A failure the agent reads as the tool's result.
struct ToolFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// The Woven MCP on this server: the one catalog, carried out here, with the
/// calls that concern another machine forwarded to that machine's server and
/// the browser and computer-use calls handed to this Mac's UI.
final class WovenTools: Sendable {
  let library: Library
  let sessions: SessionManager
  let databases: Databases
  let peers: PeerSync
  let bots: BotsHost
  let ui = UIToolBroker()
  let catalog: [WovenTool]
  private let byName: [String: WovenTool]

  init(library: Library, sessions: SessionManager, databases: Databases, peers: PeerSync, bots: BotsHost) {
    self.library = library
    self.sessions = sessions
    self.databases = databases
    self.peers = peers
    self.bots = bots
    catalog = wovenToolCatalog()
    byName = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
  }

  var machineID: String { library.machineID }

  /// The catalog as MCP's `tools/list` describes it; `enabled` leaves out
  /// the tools of the other groups.
  func listing(forBots: Bool = false, enabled: Set<ToolGroup>? = nil) -> [JSONValue] {
    catalog.filter { (!forBots || $0.forBots) && Self.allowed($0, enabled) }.map { tool in
      .object(["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.input,
               "annotations": .object(["readOnlyHint": .bool(tool.readOnly)])])
    }
  }

  /// Carries out one call. Every failure comes back as an error result.
  func call(_ name: String, arguments: JSONValue, caller: ToolCaller, forwarded: Bool = false) async -> ToolResult {
    guard let tool = byName[name] else { return .error("Woven has no tool \(name).") }
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
  func enabledGroups(sessionID: String) async -> Set<ToolGroup> {
    guard let session = try? await library.session(sessionID) else { return [] }
    if let tools = session.tools { return tools }
    let runtime = session.runtime.rawValue
    let own = try? await library.setting("agentDefaults.\(runtime).\(session.machineID)")
    let shared = try? await library.setting("agentDefaults.\(runtime)")
    if let names = (own ?? shared)?.value["tools"]?.array { return Self.groups(names) }
    if let names = (try? await library.setting(ToolGroup.defaultsSetting))?.value.array { return Self.groups(names) }
    return ToolGroup.standard
  }

  private static func allowed(_ tool: WovenTool, _ enabled: Set<ToolGroup>?) -> Bool {
    guard let enabled, !tool.groups.isEmpty else { return true }
    return !tool.groups.isDisjoint(with: enabled)
  }

  private static func groups(_ names: [JSONValue]) -> Set<ToolGroup> {
    Set(names.compactMap { $0.string.flatMap(ToolGroup.init(rawValue:)) })
  }

  func forward(_ call: ToolRequest, to owner: String) async throws -> ToolResult? {
    guard owner != machineID else { return nil }
    let name = (try? await library.machine(owner))?.name ?? "That machine"
    guard !call.forwarded else {
      throw ToolFailure("This call was forwarded to the wrong machine; \(name) owns it.")
    }
    guard let client = await peers.client(for: owner) else {
      throw ToolFailure("\(name) is not reachable right now, so this cannot be done until it is back.")
    }
    do {
      return try await client.call(CallTool(name: call.name, arguments: call.arguments.value, caller: call.caller))
    } catch let error as ProtocolError {
      throw ToolFailure(error.message)
    } catch {
      throw ToolFailure("\(name) is not reachable right now, so this cannot be done until it is back.")
    }
  }

  /// How the server's own handlers see a tool's request: a local caller.
  var localCaller: Caller {
    Caller(origin: .local, hello: Hello(role: .ui, machine: Machine(id: "woven-tools", name: "Woven tools"), appVersion: ""))
  }
}

func registerTools(_ router: inout Router, tools: WovenTools) {
  router.on(CallTool.self) { request, caller in
    guard caller.hello.role == .server else { throw ProtocolError(.refused, "Only another machine's server calls tools here.") }
    return await tools.call(request.name, arguments: request.arguments, caller: request.caller, forwarded: true)
  }
  router.subscription(SubscribeUITools.self) { _, caller in
    guard case .local = caller.origin, caller.hello.role == .ui else {
      throw ProtocolError(.refused, "Only the UI on this Mac carries out its browser and computer tools.")
    }
    return (Done(), tools.ui.subscribe().throwing)
  }
  router.on(AnswerUITool.self) { request, caller in
    guard case .local = caller.origin else { throw ProtocolError(.refused, "Only the UI on this Mac answers these.") }
    tools.ui.answer(request.id, request.result)
    return Done()
  }
}

/// Where a part made before the catalog finds it once it exists.
final class ToolsLink: Sendable {
  private let tools = Mutex<WovenTools?>(nil)
  func attach(_ value: WovenTools) { tools.withLock { $0 = value } }
  var current: WovenTools? { tools.withLock { $0 } }
}
