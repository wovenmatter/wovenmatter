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
                                    replacement: String, attributes: NoteTextRun? = nil) throws -> String {
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
            var addition = attributes ?? run
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
        var addition = attributes ?? block.runs.last ?? NoteTextRun(text: "")
        addition.text = replacement
        newRuns.append(addition)
      }
      raw["runs"] = try runsJSON(newRuns)
    }
  }

  public static func settingStyle(in content: String, blockID: String, style: NoteParagraphStyle) throws -> String {
    // A saved native list belongs to the previous style; a bullet list's marker must not label numbered items.
    try changeBlock(content, blockID: blockID) { raw, block in
      if block.style != style { raw.removeValue(forKey: "list") }
      raw["style"] = style.rawValue
    }
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

  /// Where editing continues after a structural change, in UTF-16 units of that block.
  public struct Caret: Equatable, Sendable {
    public var blockID: String
    public var location: Int
    public init(blockID: String, location: Int) { self.blockID = blockID; self.location = location }
    init(_ blockID: String, _ location: Int) { self.init(blockID: blockID, location: location) }
  }

  public static func containsParagraphBreak(_ text: String) -> Bool {
    text.unicodeScalars.contains { ["\n", "\r", "\u{2028}", "\u{2029}"].contains($0) }
  }

  /// Replaces the selection like typing does, but each line break starts a new
  /// paragraph block. Return in an empty list item leaves the list instead.
  public static func editing(_ content: String, blockID: String, range: NSRange, replacement: String,
                             attributes: NoteTextRun? = nil,
                             newBlockID: () -> String = { UUID().uuidString.lowercased() }) throws -> (content: String, caret: Caret) {
    let text = replacement.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
    let lines = text.components(separatedBy: "\n")
    guard lines.count > 1 else {
      let next = try replacingText(in: content, blockID: blockID, range: range, replacement: replacement, attributes: attributes)
      return (next, Caret(blockID, range.location + replacement.utf16.count))
    }
    let block = try richBlock(content, blockID: blockID)
    if text == "\n", range.length == 0, block.plainText.isEmpty, block.style == .bulletedList || block.style == .numberedList {
      let next = try changeBlock(content, blockID: blockID) { raw, _ in raw["style"] = NoteParagraphStyle.paragraph.rawValue; raw.removeValue(forKey: "list") }
      return (next, Caret(blockID, 0))
    }
    // A paste of thousands of lines is one parse and one serialization, not one per line.
    guard document(content).map({ $0.blocks.count + lines.count - 1 <= maximumBlocks }) == true,
          content.utf8.count + text.utf8.count <= CompanionProtocol.maximumNoteBytes else { throw Failure.documentLimit }
    guard range.length >= 0 else { throw Failure.invalidRange }
    try requireBoundary(range.location, in: block.plainText)
    try requireBoundary(NSMaxRange(range), in: block.plainText)
    // Text after the break keeps the formatting in effect at the caret.
    let inherited = attributes ?? run(in: block, before: range.location) ?? NoteTextRun(text: "")
    func runs(_ line: String) -> [NoteTextRun] { line.isEmpty ? [] : [{ var run = inherited; run.text = line; return run }()] }
    let head = split(block.runs, at: range.location).0, tail = split(block.runs, at: NSMaxRange(range)).1
    let list = block.style == .bulletedList || block.style == .numberedList
    let style: NoteParagraphStyle = block.style.rawValue.hasPrefix("heading") && tail.allSatisfy(\.text.isEmpty) ? .paragraph : block.style
    let ids = lines.dropFirst().map { _ in newBlockID() }
    let next = try changeBlocks(content, blockID: blockID) { blocks, index, _ in
      guard var value = blocks[index]["value"] as? [String: Any] else { throw Failure.missingBlock }
      value["runs"] = try runsJSON(head + runs(lines[0]))
      blocks[index]["value"] = value
      var created: [[String: Any]] = []
      for (offset, line) in lines.dropFirst().enumerated() {
        var paragraph: [String: Any] = ["id": ids[offset], "style": style.rawValue,
                                        "runs": try runsJSON(runs(line) + (offset == ids.count - 1 ? tail : []))]
        if list, let format = value["list"] { paragraph["list"] = format }
        created.append(["type": "richText", "value": paragraph])
      }
      blocks.insert(contentsOf: created, at: index + 1)
    }
    return (next, Caret(ids[ids.count - 1], lines[lines.count - 1].utf16.count))
  }

  /// The block count an editable document may hold; see `NoteDocument.validateEditableShape`.
  public static let maximumBlocks = 10_000

  /// The item number each list paragraph displays, matching the Mac's native lists:
  /// paragraphs with saved list identity share that list wherever it continues;
  /// earlier flat paragraphs share one list while the same style continues.
  public static func listItemNumbers(_ document: NoteDocument) -> [String: Int] {
    enum Identity: Hashable { case native(NoteTextList), flat(Int) }
    var numbers: [String: Int] = [:]
    var previousStyle: NoteParagraphStyle?, previousList: Identity?
    // Items counted so far in each list's current run. A paragraph outside a
    // list, including body text and tables, ends that list's run. One pass.
    var running: [Identity: Int] = [:]
    for (index, block) in document.blocks.enumerated() {
      guard case .richText(let text) = block else { running = [:]; previousStyle = nil; previousList = nil; continue }
      var chain: [Identity] = []
      if let levels = text.list?.levels, !levels.isEmpty, text.style == .bulletedList || text.style == .numberedList {
        chain = levels.map(Identity.native)
      } else if text.style == .bulletedList || text.style == .numberedList {
        chain = [previousStyle == text.style ? previousList ?? .flat(index) : .flat(index)]
      }
      previousStyle = text.style; previousList = chain.first
      running = running.filter { chain.contains($0.key) }
      guard let own = chain.last else { continue }
      let count = running[own, default: 0]
      running[own] = count + 1
      let start = if case .native(let list) = own { list.startingItemNumber } else { 1 }
      numbers[text.id] = start + count
    }
    return numbers
  }

  /// Delete at the start of a paragraph: a list item or heading first becomes
  /// body text; body text joins the preceding paragraph. Returns nil when
  /// nothing precedes it that can be joined, such as a table.
  public static func mergingBackward(_ content: String, blockID: String) throws -> (content: String, caret: Caret)? {
    let block = try richBlock(content, blockID: blockID)
    if block.style != .paragraph {
      let next = try changeBlock(content, blockID: blockID) { raw, _ in raw["style"] = NoteParagraphStyle.paragraph.rawValue; raw.removeValue(forKey: "list") }
      return (next, Caret(blockID, 0))
    }
    guard let document = document(content), let index = document.blocks.firstIndex(where: { $0.id == blockID }), index > 0,
      case .richText(let previous) = document.blocks[index - 1] else { return nil }
    var caret = Caret(previous.id, previous.plainText.utf16.count)
    let next = try changeBlocks(content, blockID: previous.id) { blocks, previousIndex, previous in
      // Removing a block must never discard data this device does not understand.
      guard Set(blocks[previousIndex + 1].keys).isSubset(of: ["type", "value"]),
        let removed = blocks[previousIndex + 1]["value"] as? [String: Any],
        Set(removed.keys).isSubset(of: ["id", "style", "runs", "list"]) else { throw Failure.unsupported }
      guard var value = blocks[previousIndex]["value"] as? [String: Any] else { throw Failure.missingBlock }
      try validateRuns(removed)
      value["runs"] = try runsJSON(previous.runs + block.runs)
      blocks[previousIndex]["value"] = value
      blocks.remove(at: previousIndex + 1)
      caret = Caret(previous.id, previous.plainText.utf16.count)
    }
    return (next, caret)
  }

  /// Formatting in effect at a caret, for text typed into a paragraph that starts empty.
  public static func typingFormat(in content: String, blockID: String, at location: Int) -> NoteTextRun? {
    (try? richBlock(content, blockID: blockID)).flatMap { run(in: $0, before: location) }
  }
  private static func richBlock(_ content: String, blockID: String) throws -> NoteRichTextBlock {
    guard canEdit(content), let document = document(content) else { throw Failure.unsupported }
    guard let block = document.blocks.first(where: { $0.id == blockID }), case .richText(let value) = block else { throw Failure.missingBlock }
    return value
  }
  private static func run(in block: NoteRichTextBlock, before location: Int) -> NoteTextRun? {
    var offset = 0
    for run in block.runs {
      offset += run.text.utf16.count
      if location <= offset { var value = run; value.text = ""; return value }
    }
    return block.runs.last.map { var value = $0; value.text = ""; return value }
  }
  private static func split(_ runs: [NoteTextRun], at location: Int) -> ([NoteTextRun], [NoteTextRun]) {
    var prefix: [NoteTextRun] = [], suffix: [NoteTextRun] = [], offset = 0
    for run in runs {
      let count = run.text.utf16.count
      if offset + count <= location { prefix.append(run) }
      else if offset >= location { suffix.append(run) }
      else {
        var head = run, tail = run
        head.text = (run.text as NSString).substring(to: location - offset)
        tail.text = (run.text as NSString).substring(from: location - offset)
        prefix.append(head); suffix.append(tail)
      }
      offset += count
    }
    return (prefix, suffix)
  }
  private static func requireBoundary(_ location: Int, in text: String) throws {
    let units = Array(text.utf16)
    guard location >= 0, location <= units.count else { throw Failure.invalidRange }
    if location > 0 && location < units.count, (0xDC00...0xDFFF).contains(units[location]), (0xD800...0xDBFF).contains(units[location - 1]) { throw Failure.invalidRange }
  }

  /// Appends an empty body paragraph, for example to continue writing after a final table.
  public static func appendingParagraph(to content: String, id: String = UUID().uuidString.lowercased()) throws -> String {
    guard canEdit(content), var raw = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
          var blocks = raw["blocks"] as? [[String: Any]] else { throw Failure.unsupported }
    let block = NoteBlock.richText(NoteRichTextBlock(id: id))
    blocks.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as! [String: Any])
    raw["blocks"] = blocks
    return try serialize(raw)
  }

  private static func changeBlock(_ content: String, blockID: String,
                                   change: (inout [String: Any], NoteRichTextBlock) throws -> Void) throws -> String {
    try changeBlocks(content, blockID: blockID) { blocks, index, block in
      guard var value = blocks[index]["value"] as? [String: Any] else { throw Failure.missingBlock }
      try change(&value, block)
      blocks[index]["value"] = value
    }
  }
  /// Structural edits address the raw block list so untouched blocks keep every field.
  private static func changeBlocks(_ content: String, blockID: String,
                                    change: (inout [[String: Any]], Int, NoteRichTextBlock) throws -> Void) throws -> String {
    guard canEdit(content), let document = document(content),
          var raw = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
          var blocks = raw["blocks"] as? [[String: Any]], blocks.count == document.blocks.count,
          let index = document.blocks.firstIndex(where: { $0.id == blockID }),
          case .richText(let block) = document.blocks[index],
          let value = blocks[index]["value"] as? [String: Any] else { throw Failure.missingBlock }
    try validateRuns(value)
    try change(&blocks, index, block)
    raw["blocks"] = blocks
    return try serialize(raw)
  }
  /// Preserve unfamiliar run fields by refusing text edits, instead of silently
  /// re-encoding and erasing their semantics. Other raw fields remain untouched.
  private static func validateRuns(_ value: [String: Any]) throws {
    let runKeys: Set<String> = ["text", "fontFamily", "fontSize", "bold", "italic", "underline", "foregroundHex", "highlightHex", "link"]
    if let runs = value["runs"] as? [[String: Any]], runs.contains(where: { !Set($0.keys).isSubset(of: runKeys) }) {
      throw Failure.unsupported
    }
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
