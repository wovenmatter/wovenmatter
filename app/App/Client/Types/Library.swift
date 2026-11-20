import CryptoKit
import Foundation

/// What the Library page filters by.
enum LibraryItemKind: String, Codable, CaseIterable, Sendable {
  case file, link, photo
  var title: String {
    switch self {
    case .file: "Files"
    case .link: "Links"
    case .photo: "Photos"
    }
  }
}

enum LibrarySender: String, Codable, CaseIterable, Sendable {
  case me, agent
  var title: String { self == .me ? "Sent by me" : "Sent by agents" }
}

enum LibraryDateRange: String, CaseIterable, Identifiable, Sendable {
  case today, week, month, quarter, all
  var id: String { rawValue }
  var title: String {
    switch self {
    case .today: "Today"
    case .week: "Last 7 days"
    case .month: "Last 30 days"
    case .quarter: "Last 90 days"
    case .all: "All time"
    }
  }
  func start(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date? {
    let days: Int
    switch self {
    case .today: days = 0
    case .week: days = 6
    case .month: days = 29
    case .quarter: days = 89
    case .all: return nil
    }
    return calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))
  }
}

/// A Library filter and search. `nil` means all; an empty set matches nothing.
struct LibraryQuery: Equatable, Sendable {
  var machines: Set<String>?
  var harnesses: Set<String>?
  var agents: Set<String>?
  var sender: LibrarySender?
  var kind: LibraryItemKind?
  var since: Date?
  var until: Date?
  var search = ""
  var oldestFirst = false
  init() {}
}

/// Where a Library item's content is.
enum LibraryStorage: String, Codable, Sendable {
  case link, pending, attachment, retained, unavailable, unsupported
}

/// A file, link or photo exchanged in a chat, as the Library lists it.
struct WorkspaceLibraryItem: Equatable, Identifiable, Sendable {
  /// The same item, from the message it was sent in and its source, on every machine.
  static func identifier(messageID: String, source: String) -> String {
    SHA256.hash(data: Data((messageID + "\u{0}" + source).utf8)).map { String(format: "%02x", $0) }.joined()
  }

  let id: String
  let conversationID: String
  let messageID: String
  let conversationTitle: String
  /// The machine whose session sent or received it.
  let machineID: String
  let machineName: String
  let harness: String
  let agentID: String
  let agentName: String
  let sender: LibrarySender
  let kind: LibraryItemKind
  let title: String
  let source: String
  let sentAt: Date
  let hasContent: Bool
  let storage: LibraryStorage
  let error: String?
  var canOpen: Bool { (storage == .link && isWebLink) || hasContent }
  var isWebLink: Bool { ["http", "https"].contains(URL(string: source)?.scheme?.lowercased() ?? "") }
}

/// One agent on one machine that has Library items, for the filters.
struct LibraryFacet: Equatable, Identifiable, Sendable {
  let machineID: String
  let machineName: String
  let harness: String
  let agentID: String
  let agentName: String
  var id: String { machineID + ":" + agentID }
}

/// A file an agent saved from a machine, as Saved Artifacts lists it.
struct SavedArtifactLibraryItem: Equatable, Identifiable, Sendable {
  let id: String
  let title: String
  let mediaType: String
  let byteCount: Int64
  let machineID: String
  let machineName: String
}

/// A link or file found in a message.
struct LibraryAsset: Equatable, Sendable {
  let source: String
  let title: String
  let kind: LibraryItemKind
  let mimeType: String?
  let data: Data?
  init(source: String, title: String, kind: LibraryItemKind, mimeType: String? = nil, data: Data? = nil) {
    self.source = source
    let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
    self.title = label.isEmpty ? "Attachment" : label
    self.kind = kind
    self.mimeType = mimeType
    self.data = data
  }
}

/// Decode a shared file URI once, preserving its original URL in the catalog.
enum LibraryFileReference {
  static func path(_ source: String) -> String? {
    guard !source.contains("\0"), let url = URL(string: source),
      [nil, "file", "sandbox"].contains(url.scheme?.lowercased()),
      url.host == nil || url.host == "" || url.host == "localhost"
    else { return nil }
    let path = url.path
    guard !path.isEmpty, !path.contains("\0") else { return nil }
    return path
  }
}

enum LibraryLinkDiscovery {
  static let maximumItemsPerMessage = 200
  private static let photos: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "svg",
  ]
  private static let files: Set<String> = [
    "pdf", "doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "zip", "txt", "md", "rtf", "json", "mp3", "mp4", "mov",
    "wav",
  ]

  static func kind(source: String, mimeType: String? = nil) -> LibraryItemKind {
    let ext = URL(string: source)?.pathExtension.lowercased() ?? (source as NSString).pathExtension.lowercased()
    if mimeType?.hasPrefix("image/") == true || photos.contains(ext) { return .photo }
    if isFileReference(source) || files.contains(ext) { return .file }
    return .link
  }
  static func isFileReference(_ source: String) -> Bool {
    [nil, "file", "sandbox"].contains(URL(string: source)?.scheme?.lowercased())
  }
  static func links(in content: String) -> [LibraryAsset] {
    // Code examples are not handbacks. Bound parsing without rescanning the transcript.
    let text = String(content.prefix(1_000_000)).replacingOccurrences(
      of: #"(?s)```.*?```|~~~.*?~~~"#, with: "", options: .regularExpression)
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    var results: [LibraryAsset] = []
    var seen = Set<String>()
    var markdownRanges: [NSRange] = []
    func append(_ raw: String, title: String?) {
      let source = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
      guard !source.isEmpty, source.utf8.count <= 8192, !source.contains("\n"),
        results.count < maximumItemsPerMessage, seen.insert(source).inserted
      else { return }
      let scheme = URL(string: source)?.scheme?.lowercased()
      guard scheme == nil || ["http", "https", "file", "sandbox"].contains(scheme!) else { return }
      if scheme == nil, !source.contains("/"), (source as NSString).pathExtension.isEmpty { return }
      let fallback = URL(string: source)?.lastPathComponent.removingPercentEncoding
      let label = title?.trimmingCharacters(in: .whitespacesAndNewlines)
      results.append(
        .init(
          source: source,
          title: String(
            (label?.isEmpty == false ? label! : (fallback?.isEmpty == false ? fallback! : source)).prefix(512)),
          kind: kind(source: source)))
    }
    func matches(_ pattern: String, visit: (NSTextCheckingResult) -> Void) {
      guard results.count < maximumItemsPerMessage,
        let regex = try? NSRegularExpression(pattern: pattern)
      else { return }
      // Linux Foundation declares this enumeration callback as escaping.
      withoutActuallyEscaping(visit) { visit in
        regex.enumerateMatches(in: text, range: full) { match, _, stop in
          if let match { visit(match) }
          if results.count == maximumItemsPerMessage { stop.pointee = true }
        }
      }
    }
    matches(#"!?\[([^\[\]\n]*)\]\((<[^>\n]+>|(?:[^\s()]|\([^()]*\))+)(?:\s+\"[^\"]*\")?\)"#) { match in
      guard let label = Range(match.range(at: 1), in: text), let source = Range(match.range(at: 2), in: text) else {
        return
      }
      append(String(text[source]), title: String(text[label]))
      markdownRanges.append(match.range)
    }
    // Reference-style citations, including footnotes, retain their destination URLs.
    matches(#"(?im)^[ \t]*\[[^\[\]\r\n]+\]:[ \t]*(\S+)"#) { match in
      if let range = Range(match.range(at: 1), in: text) { append(String(text[range]), title: nil) }
    }
    // Both match streams are ordered. Advance through Markdown spans once instead
    // of rescanning every span for each URL in a large/repetitive message.
    var markdownIndex = 0
    matches(#"(?i)\b(?:https?://|file:///|sandbox:/)[^\s<>\[\]"']+"#) { match in
      while markdownIndex < markdownRanges.count, NSMaxRange(markdownRanges[markdownIndex]) <= match.range.location {
        markdownIndex += 1
      }
      guard markdownIndex == markdownRanges.count
        || NSIntersectionRange(markdownRanges[markdownIndex], match.range).length == 0,
        let range = Range(match.range, in: text)
      else { return }
      var source = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
      var extraClosing = source.reduce(0) { count, character in
        count + (character == ")" ? 1 : character == "(" ? -1 : 0)
      }
      while source.last == ")", extraClosing > 0 {
        source.removeLast()
        extraClosing -= 1
      }
      append(source, title: nil)
    }
    matches(#"(?m)(?:^|\s)MEDIA:\s*([^\s]+)"#) { match in
      if let range = Range(match.range(at: 1), in: text) { append(String(text[range]), title: nil) }
    }
    return results
  }
}
