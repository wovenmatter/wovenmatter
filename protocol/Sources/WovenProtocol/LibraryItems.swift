import Foundation

// The library page: files, photos and links exchanged in chats. A file sent
// with a message is in the content store by digest; links are found in the
// message text.

/// What the library page filters by.
public enum LibraryItemKind: String, Codable, CaseIterable, Sendable {
  case file, link, photo
}

/// An agent on a machine: a runtime there.
public struct LibraryAgent: Codable, Sendable, Hashable {
  public var machineID: String
  public var runtime: RuntimeKind

  public init(machineID: String, runtime: RuntimeKind) {
    self.machineID = machineID
    self.runtime = runtime
  }
}

/// A file, photo or link sent in a chat.
public struct LibraryItem: Codable, Sendable, Hashable, Identifiable {
  /// The same on every machine: the session item and the item's place in it.
  public var id: String
  public var sessionID: String
  /// The session item it was sent in.
  public var sessionItemID: String
  public var sessionTitle: String
  public var agent: LibraryAgent
  /// Sent by the person rather than the agent.
  public var fromPerson: Bool
  public var kind: LibraryItemKind
  public var title: String
  /// A link's address, or an attachment's file name.
  public var source: String
  public var sentAt: Date
  /// The file, when it was sent as an attachment; its content is in the content store.
  public var attachment: Attachment?

  public init(id: String, sessionID: String, sessionItemID: String, sessionTitle: String, agent: LibraryAgent,
              fromPerson: Bool, kind: LibraryItemKind, title: String, source: String, sentAt: Date, attachment: Attachment?) {
    self.id = id
    self.sessionID = sessionID
    self.sessionItemID = sessionItemID
    self.sessionTitle = sessionTitle
    self.agent = agent
    self.fromPerson = fromPerson
    self.kind = kind
    self.title = title
    self.source = source
    self.sentAt = sentAt
    self.attachment = attachment
  }
}

public struct LibraryItemsPage: Codable, Sendable, Hashable {
  public var items: [LibraryItem]
  /// Every agent with items, whatever the filters, for choosing filters.
  public var agents: [LibraryAgent]
  /// More items match beyond this page.
  public var more: Bool

  public init(items: [LibraryItem], agents: [LibraryAgent], more: Bool) {
    self.items = items
    self.agents = agents
    self.more = more
  }
}

/// Library items matching the filters, newest first unless `oldestFirst`.
/// A nil filter matches everything.
public struct ListLibraryItems: Request {
  public static let method = "library.items"
  public typealias Reply = LibraryItemsPage
  public var machineIDs: [String]?
  public var runtimes: [RuntimeKind]?
  public var agents: [LibraryAgent]?
  public var fromPerson: Bool?
  public var kind: LibraryItemKind?
  public var since: Date?
  public var until: Date?
  public var search: String
  public var oldestFirst: Bool
  public var offset: Int
  public var limit: Int

  public init(machineIDs: [String]? = nil, runtimes: [RuntimeKind]? = nil, agents: [LibraryAgent]? = nil,
              fromPerson: Bool? = nil, kind: LibraryItemKind? = nil, since: Date? = nil, until: Date? = nil,
              search: String = "", oldestFirst: Bool = false, offset: Int = 0, limit: Int = 100) {
    self.machineIDs = machineIDs
    self.runtimes = runtimes
    self.agents = agents
    self.fromPerson = fromPerson
    self.kind = kind
    self.since = since
    self.until = until
    self.search = search
    self.oldestFirst = oldestFirst
    self.offset = offset
    self.limit = limit
  }
}

/// A link or file found in a message.
public struct LibraryAsset: Equatable, Sendable {
  public let source: String
  public let title: String
  public let kind: LibraryItemKind
  public let mimeType: String?
  public let data: Data?
  public init(source: String, title: String, kind: LibraryItemKind, mimeType: String? = nil, data: Data? = nil) {
    self.source = source
    let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
    self.title = label.isEmpty ? "Attachment" : label
    self.kind = kind
    self.mimeType = mimeType
    self.data = data
  }
}

/// Decode a shared file URI once, preserving its original URL in the catalog.
public enum LibraryFileReference {
  public static func path(_ source: String) -> String? {
    guard !source.contains("\0"), let url = URL(string: source),
      [nil, "file", "sandbox"].contains(url.scheme?.lowercased()),
      url.host == nil || url.host == "" || url.host == "localhost"
    else { return nil }
    let path = url.path
    guard !path.isEmpty, !path.contains("\0") else { return nil }
    return path
  }
}

public enum LibraryLinkDiscovery {
  public static let maximumItemsPerMessage = 200
  private static let photos: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "svg",
  ]
  private static let files: Set<String> = [
    "pdf", "doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "zip", "txt", "md", "rtf", "json", "mp3", "mp4", "mov",
    "wav",
  ]

  public static func kind(source: String, mimeType: String? = nil) -> LibraryItemKind {
    let ext = URL(string: source)?.pathExtension.lowercased() ?? (source as NSString).pathExtension.lowercased()
    if mimeType?.hasPrefix("image/") == true || photos.contains(ext) { return .photo }
    if isFileReference(source) || files.contains(ext) { return .file }
    return .link
  }
  public static func isFileReference(_ source: String) -> Bool {
    [nil, "file", "sandbox"].contains(URL(string: source)?.scheme?.lowercased())
  }
  public static func links(in content: String) -> [LibraryAsset] {
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
