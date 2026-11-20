import Foundation
import WovenProtocol

/// Requests about the model servers Pi Durable uses on this machine. Each is
/// checked from here, since its address may only be reachable from here.
func registerLocalModelServers(_ router: inout Router, sessions: SessionManager, secrets: Secrets) {
  /// At most this many servers per machine.
  let limit = 12

  router.on(ListLocalModelServers.self) { _, _ in
    try await secrets.localModelServers().map(\.server)
  }
  router.on(ConnectLocalModelServer.self) { request, _ in
    guard let pi = await sessions.runtime(.piDurable) as? PiDurableRuntime else {
      throw ProtocolError(.badRequest, "This machine has no Pi Durable runtime.")
    }
    var saved = try await secrets.localModelServers()
    let existing = request.replacing.flatMap { id in saved.firstIndex { $0.server.id == id } }
    if request.replacing != nil && existing == nil { throw ProtocolError(.notFound, "That model server is no longer connected.") }
    if existing == nil && saved.count >= limit { throw ProtocolError(.badRequest, "You can connect up to \(limit) local model servers.") }
    let entered = request.key.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = entered.isEmpty ? existing.map { saved[$0].key } ?? "" : entered
    let url = existing.map { saved[$0].server.url } ?? request.url
    let probed = try await pi.control(.object(["action": .string("probe-local-server"), "url": .string(url), "key": .string(key)]),
                                      events: { _ in }, answers: nil)
    guard let checked = probed["url"]?.string, let models = probed["models"]?.array?.compactMap(\.string) else {
      throw ProtocolError(.failed, "Pi Durable could not check the server.")
    }
    let server = LocalModelServer(id: existing.map { saved[$0].server.id } ?? "local-server-" + UUID().uuidString.lowercased(),
                                  url: checked, models: models, verifiedAt: Date())
    if let existing { saved[existing] = .init(server: server, key: key) } else { saved.append(.init(server: server, key: key)) }
    try await secrets.setLocalModelServers(saved)
    return server
  }
  router.on(RemoveLocalModelServer.self) { request, _ in
    try await secrets.setLocalModelServers(try await secrets.localModelServers().filter { $0.server.id != request.id })
    return Done()
  }
}
