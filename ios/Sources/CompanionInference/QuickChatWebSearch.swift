import Foundation

/// The web-search connections Quick Chat can use. These match the desktop's
/// `ProviderConnectionID.searchProviders` and request shapes in
/// default-agent/src/search.mjs. Brave can search but not read pages.
public enum QuickChatSearchProvider: String, CaseIterable, Identifiable, Sendable {
  case exa, brave, firecrawl
  public var id: String { rawValue }
  public var name: String {
    switch self { case .exa: "Exa"; case .brave: "Brave Search"; case .firecrawl: "Firecrawl" }
  }
  public var canRead: Bool { self != .brave }
  /// Each key is a separate device-only Keychain item, alongside the model connections.
  public var credentialID: String { "quick-chat-search-" + rawValue }
}

public enum QuickChatSearchError: Error, LocalizedError, Equatable {
  case unconfigured, readUnavailable, invalidQuery, invalidURL, failed(String), responseTooLarge
  public var errorDescription: String? {
    switch self {
    case .unconfigured: "Connect Exa, Brave Search or Firecrawl in Settings, under Connections → Web search."
    case .readUnavailable: "Brave Search can search but not read webpages. Connect Exa or Firecrawl to read pages."
    case .invalidQuery: "Enter a search query shorter than 4,000 characters."
    case .invalidURL: "Choose a public HTTP or HTTPS webpage."
    case .failed(let name): "\(name) request failed. Check the search connection and available credits."
    case .responseTooLarge: "The search response was too large. Try a narrower query."
    }
  }
}

/// Credentials remain in the device Keychain. Each provider's destination is
/// fixed, redirects are refused by the transport, and provider error bodies never
/// enter output.
public struct QuickChatWebSearch: Sendable {
  public static let maximumText = 16_000
  public let provider: QuickChatSearchProvider
  private let credentials: any InferenceCredentialReading
  private let transport: any InferenceHTTPTransport
  public init(provider: QuickChatSearchProvider, credentials: any InferenceCredentialReading,
              transport: any InferenceHTTPTransport = InferenceURLSessionTransport()) {
    self.provider = provider; self.credentials = credentials; self.transport = transport
  }
  /// The connected providers, in the user's preferred order: the chosen provider
  /// first, then Exa, Brave Search and Firecrawl.
  public static func connected(credentials: any InferenceCredentialReading, preferred: String? = nil) async -> [QuickChatSearchProvider] {
    var result: [QuickChatSearchProvider] = []
    for provider in QuickChatSearchProvider.allCases {
      if let key = try? await credentials.read(connectionID: provider.credentialID), !key.isEmpty { result.append(provider) }
    }
    if let preferred, let index = result.firstIndex(where: { $0.rawValue == preferred }) { result.insert(result.remove(at: index), at: 0) }
    return result
  }
  /// The service for a search or a page read, using the preferred connection that supports it.
  public static func service(reading: Bool, credentials: any InferenceCredentialReading, preferred: String? = nil,
                             transport: any InferenceHTTPTransport = InferenceURLSessionTransport()) async throws -> QuickChatWebSearch {
    let connected = await connected(credentials: credentials, preferred: preferred)
    guard !connected.isEmpty else { throw QuickChatSearchError.unconfigured }
    guard let provider = reading ? connected.first(where: \.canRead) : connected.first else { throw QuickChatSearchError.readUnavailable }
    return .init(provider: provider, credentials: credentials, transport: transport)
  }

  public func search(_ query: String, limit: Int = 5) async throws -> String {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.count <= 4_000 else { throw QuickChatSearchError.invalidQuery }
    let limit = min(10, max(1, limit))
    switch provider {
    case .exa:
      return try await lookup("https://api.exa.ai/search", ["query": query, "numResults": limit, "contents": ["text": ["maxCharacters": Self.maximumText]]], limit: limit) { data in
        data["results"] as? [[String: Any]]
      }
    case .brave:
      return try await lookup("https://api.search.brave.com/res/v1/llm/context", ["q": query, "count": limit, "maximum_number_of_urls": limit,
        "maximum_number_of_tokens": 8192, "maximum_number_of_tokens_per_url": 4096], limit: limit) { data in
        ((data["grounding"] as? [String: Any])?["generic"] as? [[String: Any]])?.map { row in
          var row = row; row["text"] = (row["snippets"] as? [String])?.joined(separator: "\n\n"); return row
        }
      }
    case .firecrawl:
      return try await lookup("https://api.firecrawl.dev/v2/search", ["query": query, "limit": limit, "sources": ["web"], "scrapeOptions": ["formats": ["markdown"]]], limit: limit) { data in
        ((data["data"] as? [String: Any])?["web"] as? [[String: Any]])?.map { row in
          var row = row; row["text"] = row["markdown"] ?? row["description"]; return row
        }
      }
    }
  }
  public func read(_ address: String) async throws -> String {
    guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
      let host = url.host?.lowercased(), url.user == nil, url.password == nil,
      host != "localhost", !host.hasSuffix(".ts.net"), !host.hasSuffix(".local"),
      !host.hasPrefix("127."), !host.hasPrefix("10."), !host.hasPrefix("192.168."), !host.hasPrefix("169.254."),
      !host.contains(":"), host.split(separator: ".").contains(where: { Int($0) == nil }) else { throw QuickChatSearchError.invalidURL }
    // Page retrieval runs at the provider's fixed endpoint, never against the phone's
    // LAN or Tailnet. This grants no access to local services, cookies or host tokens.
    switch provider {
    case .exa:
      return try await lookup("https://api.exa.ai/contents", ["urls": [url.absoluteString], "text": ["maxCharacters": Self.maximumText]], limit: 1) { data in
        data["results"] as? [[String: Any]]
      }
    case .firecrawl:
      return try await lookup("https://api.firecrawl.dev/v2/scrape", ["url": url.absoluteString, "formats": ["markdown"]], limit: 1) { data in
        let page = data["data"] as? [String: Any]
        return [["title": (page?["metadata"] as? [String: Any])?["title"] ?? "", "url": url.absoluteString, "text": page?["markdown"] ?? ""]]
      }
    case .brave: throw QuickChatSearchError.readUnavailable
    }
  }
  private func header(_ key: String) -> (String, String) {
    switch provider {
    case .exa: ("x-api-key", key)
    case .brave: ("X-Subscription-Token", key)
    case .firecrawl: ("Authorization", "Bearer " + key)
    }
  }
  private func lookup(_ endpoint: String, _ parameters: [String: Any], limit: Int,
                      results: ([String: Any]) -> [[String: Any]]?) async throws -> String {
    guard let key = try await credentials.read(connectionID: provider.credentialID), !key.isEmpty else { throw QuickChatSearchError.unconfigured }
    var request = URLRequest(url: URL(string: endpoint)!)
    request.httpMethod = "POST"; request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (field, value) = header(key)
    request.setValue(value, forHTTPHeaderField: field)
    request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    var body = "", successful = false
    do {
      for try await event in try await transport.stream(request) {
        try Task.checkCancellation()
        switch event {
        case .response(let status):
          guard (200..<300).contains(status) else { throw QuickChatSearchError.failed(provider.name) }
          successful = true
        case .line(let line):
          guard successful, body.utf8.count + line.utf8.count < 4 * 1_048_576 else { throw QuickChatSearchError.responseTooLarge }
          body += line + "\n"
        }
      }
      guard successful, let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
        object["success"] as? Bool != false, let rows = results(object) else { throw QuickChatSearchError.failed(provider.name) }
      let safe: [[String: String]] = rows.prefix(limit).compactMap { row in
        guard let address = row["url"] as? String, let url = URL(string: address),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return ["title": String((row["title"] as? String ?? "").prefix(1_000)), "url": address,
          "text": String((row["text"] as? String ?? "").prefix(Self.maximumText))]
      }
      return String(decoding: try JSONSerialization.data(withJSONObject: ["results": safe], options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    } catch is CancellationError { throw CancellationError() }
    catch let error as QuickChatSearchError { throw error }
    catch { throw QuickChatSearchError.failed(provider.name) }
  }
}

/// Distinguishes pages the user chose from addresses composed by the model. A page
/// named in the user's own messages or returned by a search in the same chat is
/// expected; any other address may carry note contents to an outside server, so
/// Ask for Approval shows the exact address before the provider fetches it.
public enum QuickChatWebReadProvenance {
  public static func isExpected(_ address: String, userMessages: [String], searchResults: Set<String>) -> Bool {
    guard let target = normalized(address) else { return false }
    if searchResults.contains(where: { normalized($0) == target }) { return true }
    return userMessages.contains { message in links(in: message).contains { normalized($0) == target } }
  }
  /// URLs returned by `QuickChatWebSearch.search`.
  public static func resultURLs(_ output: String) -> Set<String> {
    guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
      let results = object["results"] as? [[String: Any]] else { return [] }
    return Set(results.compactMap { $0["url"] as? String })
  }
  static func links(in text: String) -> [String] {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
    return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { $0.url?.absoluteString }
  }
  /// Scheme and host compare case-insensitively; path, query and fragment must match exactly.
  static func normalized(_ address: String) -> String? {
    guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = components.host?.lowercased() else { return nil }
    components.scheme = scheme; components.host = host
    if components.path.isEmpty { components.path = "/" }
    return components.string
  }
}
