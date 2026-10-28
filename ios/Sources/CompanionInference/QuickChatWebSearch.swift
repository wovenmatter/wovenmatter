import Foundation

public enum QuickChatSearchError: Error, LocalizedError {
  case unconfigured, invalidQuery, invalidURL, failed, responseTooLarge
  public var errorDescription: String? {
    switch self {
    case .unconfigured: "Add an Exa API key in Settings → Quick Chat → Web search."
    case .invalidQuery: "Enter a search query shorter than 4,000 characters."
    case .invalidURL: "Choose a public HTTP or HTTPS webpage."
    case .failed: "Web search failed. Check the search connection and available credits."
    case .responseTooLarge: "The search response was too large. Try a narrower query."
    }
  }
}

/// Credentials remain in the device Keychain. The destination is fixed, redirects
/// are refused by the transport, and provider error bodies never enter output.
public struct QuickChatWebSearch: Sendable {
  public static let credentialID = "quick-chat-exa"
  private let credentials: any InferenceCredentialReading
  private let transport: any InferenceHTTPTransport
  public init(credentials: any InferenceCredentialReading, transport: any InferenceHTTPTransport = InferenceURLSessionTransport()) {
    self.credentials = credentials; self.transport = transport
  }
  public func search(_ query: String) async throws -> String {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.count <= 4_000 else { throw QuickChatSearchError.invalidQuery }
    return try await lookup(path: "search", parameters: ["query": query, "numResults": 5, "contents": ["text": ["maxCharacters": 16_000]]])
  }
  public func read(_ address: String) async throws -> String {
    guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host?.lowercased(), url.user == nil, url.password == nil,
      host != "localhost", !host.hasSuffix(".ts.net"), !host.hasSuffix(".local"),
      !host.hasPrefix("127."), !host.hasPrefix("10."), !host.hasPrefix("192.168."), !host.hasPrefix("169.254."),
      !host.contains(":"), host.split(separator: ".").contains(where: { Int($0) == nil }) else { throw QuickChatSearchError.invalidURL }
    // Page retrieval runs at Exa's fixed endpoint, never against the phone's LAN
    // or Tailnet. This grants no access to local services, cookies or host tokens.
    return try await lookup(path: "contents", parameters: ["urls": [url.absoluteString], "text": ["maxCharacters": 16_000]])
  }
  private func lookup(path: String, parameters: [String: Any]) async throws -> String {
    guard let key = try await credentials.read(connectionID: Self.credentialID), !key.isEmpty else { throw QuickChatSearchError.unconfigured }
    var request = URLRequest(url: URL(string: "https://api.exa.ai/" + path)!)
    request.httpMethod = "POST"; request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "x-api-key")
    request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    var body = "", successful = false
    do {
      for try await event in try await transport.stream(request) {
        try Task.checkCancellation()
        switch event {
        case .response(let status):
          guard (200..<300).contains(status) else { throw QuickChatSearchError.failed }
          successful = true
        case .line(let line):
          guard successful, body.utf8.count + line.utf8.count < 1_048_576 else { throw QuickChatSearchError.responseTooLarge }
          body += line + "\n"
        }
      }
      guard successful, let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
        let results = object["results"] as? [[String: Any]] else { throw QuickChatSearchError.failed }
      let safe: [[String: String]] = results.prefix(5).compactMap { row in
        guard let address = row["url"] as? String, let url = URL(string: address),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return ["title": String((row["title"] as? String ?? "").prefix(1_000)), "url": address,
          "text": String((row["text"] as? String ?? "").prefix(16_000))]
      }
      return String(decoding: try JSONSerialization.data(withJSONObject: ["results": safe], options: [.sortedKeys]), as: UTF8.self)
    } catch is CancellationError { throw CancellationError() }
    catch let error as QuickChatSearchError { throw error }
    catch { throw QuickChatSearchError.failed }
  }
}
