import Foundation
import MobileInference
import WovenProtocol

/// OpenAI Responses-compatible model servers on the tailnet that Quick Chat
/// on this device uses. They are listed in a file in the data folder; each
/// key is a device-only Keychain item named by the server's id.
actor ModelServers {
  static let prefix = "local-server-"

  private let file: URL

  init(file: URL) {
    self.file = file
  }

  func list() -> [LocalModelServer] {
    (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([LocalModelServer].self, from: $0) } ?? []
  }

  private func save(_ servers: [LocalModelServer]) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(servers).write(to: file, options: .atomic)
  }

  /// Checks a server's model list with its key and saves it. With
  /// `replacing`, that server is checked again; an empty key keeps its own.
  func connect(url address: String, key: String, replacing: String?, credentials: any InferenceCredentialWriting,
               transport: any InferenceHTTPTransport) async throws -> LocalModelServer {
    var trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard (try? InferenceURLPolicy.tailnet(trimmed)) != nil else {
      throw ProtocolError(.badRequest, "Use the model server's Tailscale address and port, with a path ending in /v1.")
    }
    let id = replacing ?? Self.prefix + UUID().uuidString.lowercased()
    var secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if secret.isEmpty, replacing != nil { secret = (try await credentials.read(connectionID: id)) ?? "" }
    guard !secret.isEmpty else { throw ProtocolError(.badRequest, "Enter the server API key.") }
    let models = try await Self.models(at: trimmed, key: secret, transport: transport)
    try await credentials.save(secret, connectionID: id)
    let server = LocalModelServer(id: id, url: trimmed, models: models, verifiedAt: Date())
    try save(list().filter { $0.id != id } + [server])
    return server
  }

  func remove(_ id: String, credentials: any InferenceCredentialWriting) async throws {
    try save(list().filter { $0.id != id })
    try await credentials.remove(connectionID: id)
  }

  /// The ids `GET /models` lists.
  private static func models(at base: String, key: String, transport: any InferenceHTTPTransport) async throws -> [String] {
    guard let url = URL(string: base + "/models") else { throw ProtocolError(.badRequest, "That is not a server address.") }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 20
    var body = ""
    var status = 0
    do {
      for try await event in try await transport.stream(request) {
        switch event {
        case .response(let code): status = code
        case .line(let line): body += line + "\n"
        }
      }
    } catch {
      throw ProtocolError(.failed, "The server could not be reached. Check the address, the server and Tailscale.")
    }
    if [401, 403].contains(status) { throw ProtocolError(.failed, "The server rejected this API key.") }
    guard (200..<300).contains(status) else { throw ProtocolError(.failed, "The server answered HTTP \(status) for /models.") }
    let listed = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])?["data"] as? [[String: Any]] ?? []
    var seen = Set<String>()
    let ids = listed.compactMap { $0["id"] as? String }.filter { !$0.isEmpty && $0.count <= 256 && seen.insert($0).inserted }
    guard !ids.isEmpty, ids.count <= 1000 else { throw ProtocolError(.failed, "The server did not list a usable model.") }
    return ids
  }
}
