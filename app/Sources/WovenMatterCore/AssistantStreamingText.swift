import Foundation

/// Markdown boundaries used by T3 Code's paragraph streaming. Capture stays
/// lossless; only the presentation waits for a stable paragraph, list item or
/// closing fence. Adapted from T3 Code 611132c, assistantStreaming.ts.
/// Copyright (c) 2026 T3 Tools Inc. See ThirdPartyNotices.txt (MIT).
public enum AssistantStreamingText {
  private static let list = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]"#)
  private static let title = try! NSRegularExpression(pattern: #"^ {0,3}(?:#{1,6}(?:[ \t]|$)|\*\*(?:[^*]|\*(?!\*))+\*\*:?$)"#)
  private static let heading = try! NSRegularExpression(pattern: #"^#{1,6}(?:[ \t]|$)"#)

  /// A terminal run always releases its partial paragraph, even when the last
  /// message update still carries the provider's earlier streaming flag.
  public static func isStreaming(messageStatus: String?, runStatus: String?) -> Bool {
    messageStatus == "streaming" && (runStatus == nil || runStatus == "running")
  }

  public static func readyPrefix(of text: String) -> String {
    var fence: (marker: Character, length: Int, indent: Int)?
    var boundary: String.Index?
    var start = text.startIndex
    var titleAwaitingContent = false
    while true {
      let newline = text[start...].firstIndex(of: "\n")
      var line = String(text[start..<(newline ?? text.endIndex)])
      while let last = line.last, last == " " || last == "\t" || last == "\r" { line.removeLast() }
      if fence == nil, start > text.startIndex, !titleAwaitingContent, matches(list, line) { boundary = start }
      guard let newline else { break }
      let indent = line.prefix { $0 == " " }.count
      let unindented = line.dropFirst(indent)
      let marker = unindented.first
      let markerLength = marker == "`" || marker == "~" ? unindented.prefix { $0 == marker }.count : 0
      if let marker, markerLength >= 3 {
        if let open = fence {
          if marker == open.marker, markerLength >= open.length, indent <= open.indent + 3,
             unindented.count == markerLength {
            fence = nil
            boundary = text.index(after: newline)
          }
        } else {
          fence = (marker, markerLength, indent)
          titleAwaitingContent = false
        }
      } else if fence == nil, line.allSatisfy({ $0 == " " || $0 == "\t" }), start > text.startIndex {
        if !titleAwaitingContent { boundary = text.index(after: newline) }
      } else if fence == nil {
        if start > text.startIndex, !titleAwaitingContent, matches(heading, line) { boundary = start }
        titleAwaitingContent = matches(title, line)
      }
      start = text.index(after: newline)
    }
    return boundary.map { String(text[..<$0]) } ?? ""
  }

  /// T3's compact live reasoning line: prefer a supplied bold heading, then
  /// the first sentence. The expanded trace always retains the original text.
  /// Adapted from T3 Code 68339a0, work-log/presentation.ts (MIT).
  public static func reasoningPreview(of markdown: String) -> String {
    // Preview work stays bounded even for a very long native reasoning trace.
    let source = String(markdown.prefix(2_000))
    let heading = source.range(of: #"^\s*\*\*([^*\r\n]+)\*\*[ \t]*\r?(?:\n|$)"#,
      options: .regularExpression).map { String(source[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
    var text = heading ?? source
    for (pattern, replacement) in [
      (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
      (#"(?m)^[ \t]*(?:#{1,6}|[-*+]|\d+\.)[ \t]+"#, ""),
      (#"`+|\*\*|~~"#, ""),
      (#"(^|[^\w*])[*_]([^*_\n]+)[*_](?![\w*])"#, "$1$2"),
    ] {
      text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if heading == nil, let end = text.range(of: #"[.?!][\"'”’)]?(?=\s)"#, options: .regularExpression) {
      text = String(text[..<end.upperBound])
    }
    return text
  }

  private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
    expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }
}
