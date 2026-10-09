import Foundation

/// Window/workspace state only. Never persisted or associated with a chat.
public struct WorkspaceAssetTabs: Equatable, Sendable {
  public enum Tab: Hashable, Identifiable, Sendable {
    case note(String)
    case browser(UUID)
    public var id: String {
      switch self {
      case .note(let id): "note:" + id
      case .browser(let id): "browser:" + id.uuidString
      }
    }
  }
  public static let maximumNotes = 4
  public static let maximumBrowsers = 8
  public private(set) var tabs: [Tab] = []
  public private(set) var selected: Tab?
  public private(set) var isPresented = false
  public init() {}
  public var noteIDs: [String] { tabs.compactMap { if case .note(let id) = $0 { id } else { nil } } }
  public var browserIDs: [UUID] { tabs.compactMap { if case .browser(let id) = $0 { id } else { nil } } }
  public var selectedNoteID: String? { if case .note(let id) = selected { id } else { nil } }

  public mutating func open(_ tab: Tab) throws {
    if !tabs.contains(tab) {
      switch tab {
      case .note where noteIDs.count >= Self.maximumNotes: throw Capacity.notes
      case .browser where browserIDs.count >= Self.maximumBrowsers: throw Capacity.browsers
      default: tabs.append(tab)
      }
    }
    select(tab)
  }
  public mutating func select(_ tab: Tab) {
    guard tabs.contains(tab) else { return }
    selected = tab; isPresented = true
  }
  public mutating func close(_ tab: Tab) {
    guard let index = tabs.firstIndex(of: tab) else { return }
    tabs.remove(at: index)
    if selected == tab { selected = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)] }
    if tabs.isEmpty { isPresented = false }
  }
  public mutating func hide() { isPresented = false }
  public enum Capacity: LocalizedError {
    case notes, browsers
    public var errorDescription: String? {
      switch self {
      case .notes: "You have 4 assets open. Close an asset tab before opening another."
      case .browsers: "You have 8 browser tabs open. Close a browser tab before opening another."
      }
    }
  }
}

public enum BrowserAddress {
  /// Explicit non-web schemes never become accidental searches or app launches.
  public static func destination(for input: String) -> URL? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if value == "about:blank" { return URL(string: value) }
    let hasSpace = value.contains(where: \.isWhitespace)
    let isHostPort = value.range(of: #"^(localhost|[a-zA-Z0-9.-]+):[0-9]+(?:/|$)"#, options: .regularExpression) != nil
    if !hasSpace, let parts = URLComponents(string: value), let scheme = parts.scheme, !isHostPort {
      guard ["http", "https"].contains(scheme.lowercased()), parts.host?.isEmpty == false else { return nil }
      return parts.url
    }
    if !hasSpace && (value.contains(".") || value.hasPrefix("localhost") || isHostPort) {
      let scheme = value.hasPrefix("localhost") || value.hasPrefix("127.0.0.1") ? "http" : "https"
      if let url = URL(string: scheme + "://" + value), url.host != nil { return url }
    }
    var search = URLComponents(string: "https://www.google.com/search")!
    search.queryItems = [URLQueryItem(name: "q", value: value)]
    return search.url
  }
}
