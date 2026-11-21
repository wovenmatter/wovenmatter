import Foundation
import WovenLibrary
import WovenProtocol

/// The Woven tools on a machine: forwarding to the other machines' servers,
/// their run states, and this machine's databases.
struct MachineToolsHost: ToolsHost {
  let peers: PeerSync
  let databaseList: Databases

  func forward(_ call: ToolRequest, to owner: String, named name: String) async throws -> ToolResult {
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

  func runStates(of machineIDs: Set<String>) async -> [String: [String: SessionRunState]] {
    var result: [String: [String: SessionRunState]] = [:]
    for (id, client) in await peers.linked() where machineIDs.contains(id) {
      let asked = await firstOf(seconds: 5, or: [SessionRunState]?.none) {
        guard let subscription = try? await client.subscribe(SubscribeRunStates()) else { return nil }
        try? await client.unsubscribe(subscription.id)
        return subscription.reply
      }
      if let asked { result[id] = Dictionary(asked.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    return result
  }

  func databases() async throws -> [Database] {
    try await databaseList.list()
  }
}

func registerTools(_ router: inout Router, tools: WovenTools, ui: UIToolBroker) {
  router.on(CallTool.self) { request, caller in
    guard caller.hello.role == .server else { throw ProtocolError(.refused, "Only another machine's server calls tools here.") }
    return await tools.call(request.name, arguments: request.arguments, caller: request.caller, forwarded: true)
  }
  router.subscription(SubscribeUITools.self) { _, caller in
    guard case .local = caller.origin, caller.hello.role == .ui else {
      throw ProtocolError(.refused, "Only the UI on this Mac carries out its browser and computer tools.")
    }
    return (Done(), ui.subscribe().throwing)
  }
  router.on(AnswerUITool.self) { request, caller in
    guard case .local = caller.origin else { throw ProtocolError(.refused, "Only the UI on this Mac answers these.") }
    ui.answer(request.id, request.result)
    return Done()
  }
}

