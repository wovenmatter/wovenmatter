import Foundation

/// Markdown boundaries used by T3 Code's paragraph streaming. Capture stays
/// lossless; only the presentation waits for a stable paragraph, list item or
/// closing fence. Adapted from T3 Code 611132c, assistantStreaming.ts.
/// Copyright (c) 2026 T3 Tools Inc. See ThirdPartyNotices.txt (MIT).
public enum AssistantStreamingText {
  private static let list = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]"#)
  private static let title = try! NSRegularExpression(pattern: #"^ {0,3}(?:#{1,6}(?:[ \t]|$)|\*\*(?:[^*]|\*(?!\*))+\*\*:?$)"#)
  private static let heading = try! NSRegularExpression(pattern: #"^#{1,6}(?:[ \t]|$)"#)

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

  private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
    expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }
}
