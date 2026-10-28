import Foundation
import WovenMatterCompanion

/// Edits only the addressed field in the original JSON tree. Unchanged tables,
/// links, block IDs and future extension fields never pass through a flattening conversion.
public enum RichDocumentEditing {
  public enum Failure: Error, LocalizedError {
    case unsupported, missingBlock, invalidRange, documentLimit
    public var errorDescription: String? {
      switch self {
      case .unsupported: "This document uses a format this iPhone cannot edit. Its original data is preserved."
      case .missingBlock: "The selected paragraph no longer exists."
      case .invalidRange: "The selected text changed. Select it again."
      case .documentLimit: "This edit exceeds the document size or structure limit. The change was not inserted; your saved writing is unchanged."
      }
    }
  }

  public static func document(_ content: String) -> NoteDocument? {
    guard let data = content.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (raw["version"] as? Int) == NoteDocument.currentVersion,
          let decoded = try? JSONDecoder().decode(NoteDocument.self, from: data) else { return nil }
    return decoded
  }

  public static func canEdit(_ content: String) -> Bool {
    guard document(content) != nil, let document = try? NoteDocument.editableDocument(from: content), document.kind == .note else { return false }
    return true
  }

  public static func replacingText(in content: String, blockID: String, range: NSRange,
                                    replacement: String) throws -> String {
    try changeBlock(content, blockID: blockID) { raw, block in
      let length = (block.plainText as NSString).length
      guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= length else { throw Failure.invalidRange }
      // String ranges must align to Unicode scalar boundaries; NSString replacement
      // otherwise permits splitting a surrogate pair into corrupt document content.
      let units = Array(block.plainText.utf16)
      for boundary in [range.location, NSMaxRange(range)] where boundary > 0 && boundary < units.count {
        if (0xDC00...0xDFFF).contains(units[boundary]) && (0xD800...0xDBFF).contains(units[boundary - 1]) { throw Failure.invalidRange }
      }
      var newRuns: [NoteTextRun] = []
      var offset = 0
      var inserted = false
      for run in block.runs {
        let count = (run.text as NSString).length
        let start = offset, end = offset + count
        if end <= range.location {
          newRuns.append(run)
        } else if start >= NSMaxRange(range), inserted {
          newRuns.append(run)
        } else {
          if start < range.location {
            var prefix = run
            prefix.text = (run.text as NSString).substring(to: range.location - start)
            newRuns.append(prefix)
          }
          if !inserted {
            var addition = run
            addition.text = replacement
            if !addition.text.isEmpty { newRuns.append(addition) }
            inserted = true
          }
          if end > NSMaxRange(range) {
            var suffix = run
            suffix.text = (run.text as NSString).substring(from: max(0, NSMaxRange(range) - start))
            if !suffix.text.isEmpty { newRuns.append(suffix) }
          }
        }
        offset = end
      }
      if !inserted, !replacement.isEmpty {
        var addition = block.runs.last ?? NoteTextRun(text: "")
        addition.text = replacement
        newRuns.append(addition)
      }
      raw["runs"] = try runsJSON(newRuns)
    }
  }

  public static func settingStyle(in content: String, blockID: String, style: NoteParagraphStyle) throws -> String {
    try changeBlock(content, blockID: blockID) { raw, _ in raw["style"] = style.rawValue }
  }

  public static func togglingBold(in content: String, blockID: String) throws -> String {
    try changeBlock(content, blockID: blockID) { raw, block in
      let enabled = !block.runs.allSatisfy(\.bold)
      raw["runs"] = try runsJSON(block.runs.map { var run = $0; run.bold = enabled; return run })
    }
  }

  public enum TextFormat: Sendable {
    case bold, italic, underline
    case highlight(String?), fontFamily(String?), fontSize(Double), link(String?)
  }

  /// Apply only to the selection. With a caret, format its current paragraph.
  public static func formattingText(in content: String, blockID: String, range: NSRange?, format: TextFormat) throws -> String {
    if case .link(let value) = format, let value {
      guard let url = URL(string: value), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { throw Failure.invalidRange }
    }
    return try changeBlock(content, blockID: blockID) { raw, block in
      let length = block.plainText.utf16.count
      let target = range.flatMap { $0.length > 0 ? $0 : nil } ?? NSRange(location: 0, length: length)
      guard target.location >= 0, target.length >= 0, NSMaxRange(target) <= length,
            Range(target, in: block.plainText) != nil else { throw Failure.invalidRange }
      let units = Array(block.plainText.utf16)
      for boundary in [target.location, NSMaxRange(target)] where boundary > 0 && boundary < units.count {
        if (0xDC00...0xDFFF).contains(units[boundary]) && (0xD800...0xDBFF).contains(units[boundary - 1]) { throw Failure.invalidRange }
      }
      var offset = 0
      let selected = block.runs.filter { run in
        defer { offset += run.text.utf16.count }
        return NSIntersectionRange(NSRange(location: offset, length: run.text.utf16.count), target).length > 0
      }
      let enabled: Bool = switch format {
      case .bold: !selected.allSatisfy(\.bold)
      case .italic: !selected.allSatisfy(\.italic)
      case .underline: !selected.allSatisfy(\.underline)
      default: true
      }
      var output: [NoteTextRun] = []; offset = 0
      for run in block.runs {
        let count = run.text.utf16.count
        let overlap = NSIntersectionRange(NSRange(location: offset, length: count), target)
        defer { offset += count }
        guard overlap.length > 0 else { output.append(run); continue }
        let start = overlap.location - offset, end = NSMaxRange(overlap) - offset
        if start > 0 { var prefix = run; prefix.text = (run.text as NSString).substring(to: start); output.append(prefix) }
        var value = run; value.text = (run.text as NSString).substring(with: NSRange(location: start, length: end - start))
        switch format {
        case .bold: value.bold = enabled
        case .italic: value.italic = enabled
        case .underline: value.underline = enabled
        case .highlight(let hex): value.highlightHex = hex
        case .fontFamily(let family): value.fontFamily = family
        case .fontSize(let size): value.fontSize = size
        case .link(let url): value.link = url
        }
        output.append(value)
        if end < count { var suffix = run; suffix.text = (run.text as NSString).substring(from: end); output.append(suffix) }
      }
      raw["runs"] = try runsJSON(output)
    }
  }

  public static func appendingParagraph(to content: String) throws -> String {
    guard canEdit(content), var raw = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
          var blocks = raw["blocks"] as? [[String: Any]] else { throw Failure.unsupported }
    let block = NoteBlock.richText(NoteRichTextBlock())
    blocks.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as! [String: Any])
    raw["blocks"] = blocks
    return try serialize(raw)
  }

  private static func changeBlock(_ content: String, blockID: String,
                                   change: (inout [String: Any], NoteRichTextBlock) throws -> Void) throws -> String {
    guard canEdit(content), let document = document(content),
          var raw = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
          var blocks = raw["blocks"] as? [[String: Any]],
          let index = document.blocks.firstIndex(where: { $0.id == blockID }),
          case .richText(let block) = document.blocks[index],
          var value = blocks[index]["value"] as? [String: Any] else { throw Failure.missingBlock }
    // Preserve unfamiliar run fields by refusing text edits, instead of silently
    // re-encoding and erasing their semantics. Other raw fields remain untouched.
    let runKeys: Set<String> = ["text", "fontFamily", "fontSize", "bold", "italic", "underline", "foregroundHex", "highlightHex", "link"]
    if let runs = value["runs"] as? [[String: Any]], runs.contains(where: { !Set($0.keys).isSubset(of: runKeys) }) {
      throw Failure.unsupported
    }
    try change(&value, block)
    blocks[index]["value"] = value
    raw["blocks"] = blocks
    return try serialize(raw)
  }

  private static func runsJSON(_ runs: [NoteTextRun]) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(runs))
  }
  private static func serialize(_ raw: [String: Any]) throws -> String {
    let candidate = String(decoding: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    // UIKit must reject an oversized paste before accepting native text. The
    // exact same shared validation also protects toolbar changes and block count.
    guard canEdit(candidate) else { throw Failure.documentLimit }
    return candidate
  }
}

public struct MobileNoteTextStatistics: Equatable, Sendable {
  public let words: Int
  public let characters: Int
  public init(document: NoteDocument) {
    let text = document.plainText
    var count = 0
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
    words = count; characters = text.count
  }
  public var wordLabel: String { "\(words.formatted()) \(words == 1 ? "word" : "words")" }
  public var characterLabel: String { "\(characters.formatted()) \(characters == 1 ? "character" : "characters")" }
}
