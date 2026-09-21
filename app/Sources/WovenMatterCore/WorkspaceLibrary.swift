import Foundation

public enum LibraryItemKind: String, Codable, CaseIterable, Sendable {
  case file, link, photo
  public var title: String { switch self { case .file: "Files"; case .link: "Links"; case .photo: "Photos" } }
}

public enum LibrarySender: String, Codable, CaseIterable, Sendable {
  case me, agent
  public var title: String { self == .me ? "Sent by me" : "Sent by agents" }
}

public enum LibraryDateRange: String, CaseIterable, Identifiable, Sendable {
  case today, week, month, quarter, all
  public var id: String { rawValue }
  public var title: String {
    switch self { case .today: "Today"; case .week: "Last 7 days"; case .month: "Last 30 days"; case .quarter: "Last 90 days"; case .all: "All time" }
  }
  public func start(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date? {
    let days: Int
    switch self { case .today: days = 0; case .week: days = 6; case .month: days = 29; case .quarter: days = 89; case .all: return nil }
    return calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))
  }
}

public struct LibraryQuery: Equatable, Sendable {
  // nil means all; an empty selection deliberately matches nothing.
  public var workspaces: Set<String>?
  public var harnesses: Set<String>?
  public var agents: Set<String>?
  public var sender: LibrarySender?
  public var kind: LibraryItemKind?
  public var since: Date?
  public var until: Date?
  public var search = ""
  public var oldestFirst = false
  public init() {}
}

public struct WorkspaceLibraryItem: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let conversationID: String
  public let messageID: String
  public let conversationTitle: String
  public let workspaceID: String
  public let workspaceName: String
  public let harness: String
  public let agentID: String
  public let agentName: String
  public let sender: LibrarySender
  public let kind: LibraryItemKind
  public let title: String
  public let source: String
  public let sentAt: String
  public let contentHash: String?
  public let mimeType: String?
  public let sizeBytes: Int64?
  public let storage: String
  public let error: String?
  public var sentDate: Date? { dashboardDate(from: sentAt) }
  public var isWebLink: Bool { ["http", "https"].contains(URL(string: source)?.scheme?.lowercased() ?? "") }
}

public struct LibraryFacet: Codable, Equatable, Identifiable, Sendable {
  public let workspaceID: String
  public let workspaceName: String
  public let harness: String
  public let agentID: String
  public let agentName: String
  public var id: String { workspaceID + ":" + agentID }
}

public struct LibraryAsset: Equatable, Sendable {
  public let source: String
  public let title: String
  public let kind: LibraryItemKind
  public let mimeType: String?
  public let data: Data?
  public init(source: String, title: String, kind: LibraryItemKind, mimeType: String? = nil, data: Data? = nil) {
    self.source = source; self.title = title; self.kind = kind; self.mimeType = mimeType; self.data = data
  }
}

/// Discovers explicitly shared links, not every path mentioned in prose or tool traces.
public enum LibraryLinkDiscovery {
  public static let maximumItemsPerMessage = 200
  private static let photos: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "svg"]
  private static let files: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "zip", "txt", "md", "rtf", "json", "mp3", "mp4", "mov", "wav"]

  public static func kind(source: String, mimeType: String? = nil) -> LibraryItemKind {
    let ext = URL(string: source)?.pathExtension.lowercased() ?? (source as NSString).pathExtension.lowercased()
    if mimeType?.hasPrefix("image/") == true || photos.contains(ext) { return .photo }
    if isFileReference(source) || files.contains(ext) { return .file }
    return .link
  }
  public static func isFileReference(_ source: String) -> Bool {
    source.hasPrefix("/") || source.hasPrefix("~/") || source.hasPrefix("./") || source.hasPrefix("../")
      || source.hasPrefix("file:") || source.hasPrefix("sandbox:") || URL(string: source)?.scheme == nil
  }
  public static func links(in content: String) -> [LibraryAsset] {
    // Code examples are not handbacks. Bound parsing without rescanning the transcript.
    let text = String(content.prefix(1_000_000)).replacingOccurrences(
      of: #"(?s)```.*?```|~~~.*?~~~"#, with: "", options: .regularExpression)
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    var results: [LibraryAsset] = [], seen = Set<String>(), markdownRanges: [NSRange] = []
    func append(_ raw: String, title: String?) {
      let source = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
      guard !source.isEmpty, source.utf8.count <= 8192, !source.contains("\n"),
            results.count < maximumItemsPerMessage, seen.insert(source).inserted else { return }
      let scheme = URL(string: source)?.scheme?.lowercased()
      guard scheme == nil || ["http", "https", "file", "sandbox"].contains(scheme!) else { return }
      if scheme == nil, !source.contains("/"), (source as NSString).pathExtension.isEmpty { return }
      let fallback = URL(string: source)?.lastPathComponent.removingPercentEncoding
      let label = title?.trimmingCharacters(in: .whitespacesAndNewlines)
      results.append(.init(source: source, title: String((label?.isEmpty == false ? label! : (fallback?.isEmpty == false ? fallback! : source)).prefix(512)), kind: kind(source: source)))
    }
    let pattern = #"!?\[([^\]\n]*)\]\((<[^>\n]+>|(?:[^\s()]|\([^()]*\))+)(?:\s+\"[^\"]*\")?\)"#
    if let regex = try? NSRegularExpression(pattern: pattern) {
      for match in regex.matches(in: text, range: full) {
        guard let label = Range(match.range(at: 1), in: text), let source = Range(match.range(at: 2), in: text) else { continue }
        append(String(text[source]), title: String(text[label])); markdownRanges.append(match.range)
      }
    }
    // Reference-style citations, including footnotes, retain their destination URLs.
    if let regex = try? NSRegularExpression(pattern: #"(?im)^\s*\[[^\]]+\]:\s*(\S+)"#) {
      for match in regex.matches(in: text, range: full) {
        if let range = Range(match.range(at: 1), in: text) { append(String(text[range]), title: nil) }
      }
    }
    if let regex = try? NSRegularExpression(pattern: #"(?i)\b(?:https?://|file:///|sandbox:/)[^\s<>\[\]"']+"#) {
      for match in regex.matches(in: text, range: full) {
        guard !markdownRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }), let range = Range(match.range, in: text) else { continue }
        var source = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
        while source.last == ")", source.filter({ $0 == ")" }).count > source.filter({ $0 == "(" }).count { source.removeLast() }
        append(source, title: nil)
      }
    }
    if let regex = try? NSRegularExpression(pattern: #"(?m)(?:^|\s)MEDIA:\s*([^\s]+)"#) {
      for match in regex.matches(in: text, range: full) {
        if let range = Range(match.range(at: 1), in: text) { append(String(text[range]), title: nil) }
      }
    }
    return results
  }
}
