import Foundation
import WovenProtocol

/// Artifacts as an agent reads and writes them: a note as plain lines, an
/// app as its HTML, a page as an outline of components with their ids and
/// revisions.
enum DocumentText {
  // MARK: Notes

  /// A note from plain text: `# ` to `###### ` headings, `- ` or `* `
  /// bullets, `1. ` numbered items, and a paragraph per other line.
  static func note(_ text: String) -> NoteDocument {
    var blocks: [NoteBlock] = []
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
      var line = String(raw)
      var style = NoteParagraphStyle.paragraph
      if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"),
         line[hashes] == " ", line.distance(from: line.startIndex, to: hashes) <= 6 {
        let level = line.distance(from: line.startIndex, to: hashes)
        style = [.heading1, .heading2, .heading3, .heading4, .heading5, .heading6][level - 1]
        line = String(line[line.index(after: hashes)...])
      } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
        style = .bulletedList
        line = String(line.dropFirst(2))
      } else if let dot = line.firstIndex(of: "."), dot > line.startIndex, line[..<dot].allSatisfy(\.isNumber),
                line[line.index(after: dot)...].hasPrefix(" ") {
        style = .numberedList
        line = String(line[line.index(dot, offsetBy: 2)...])
      }
      blocks.append(.richText(NoteRichTextBlock(style: style, text: line, list: listFormatting(style))))
    }
    return NoteDocument(kind: .note, blocks: blocks)
  }

  private static func listFormatting(_ style: NoteParagraphStyle) -> NoteListFormatting? {
    let marker: String
    switch style {
    case .bulletedList: marker = "{disc}"
    case .numberedList: marker = "{decimal}."
    default: return nil
    }
    return NoteListFormatting(levels: [NoteTextList(markerFormat: marker)], headIndent: 36, firstLineHeadIndent: 0,
                              tabStops: [NoteListTabStop(alignment: 0, location: 36)], defaultTabInterval: 36)
  }

  /// A note's text in the same form `note(_:)` reads; tables as rows of cells.
  static func text(of document: NoteDocument) -> String {
    var number = 0
    return document.blocks.map { block -> String in
      switch block {
      case .richText(let paragraph):
        let text = paragraph.plainText
        if paragraph.style != .numberedList { number = 0 }
        switch paragraph.style {
        case .heading1: return "# " + text
        case .heading2: return "## " + text
        case .heading3: return "### " + text
        case .heading4: return "#### " + text
        case .heading5: return "##### " + text
        case .heading6: return "###### " + text
        case .bulletedList: return "- " + text
        case .numberedList:
          number += 1
          return "\(number). " + text
        case .paragraph: return text
        }
      case .table(let table):
        number = 0
        return table.rows.map { row in "| " + row.cells.map(\.plainText).joined(separator: " | ") + " |" }
          .joined(separator: "\n")
      }
    }.joined(separator: "\n")
  }

  // MARK: Pages

  /// A page as an outline: each component on its own line with its kind,
  /// id and revision, indented by depth, then its text.
  static func outline(of document: NoteDocument) -> String {
    let page = document.materializedPage()
    var lines: [String] = []
    if let purpose = page.boardPurpose, !purpose.isEmpty { lines.append("Purpose: \(purpose)") }
    let blocks = Dictionary(page.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func line(_ depth: Int, _ kind: String, _ id: String, _ text: String) {
      let indent = String(repeating: "  ", count: depth)
      lines.append("\(indent)[\(kind) id=\(id) revision=\(page.boardItemRevision(for: id))] \(text)")
    }
    for segment in page.pageSegments {
      switch segment {
      case .section(let id, _, let depth):
        line(depth, "section", id, blocks[id]?.plainText ?? "")
      case .task(let id, _, let depth):
        let task = page.boardItems?[id]?.task
        var text = blocks[id]?.plainText ?? ""
        if let task {
          text += " (status: \(task.status.rawValue))"
          if !task.details.isEmpty { text += "\n" + String(repeating: "  ", count: depth + 1) + "details: " + task.details }
          if !task.outcome.isEmpty { text += "\n" + String(repeating: "  ", count: depth + 1) + "outcome: " + task.outcome }
        }
        line(depth, "task", id, text)
      case .asset(let id, let assetID, _, let depth):
        line(depth, "artifact", id, "embeds artifact \(assetID)")
      case .image(let id, _, let depth):
        line(depth, "image", id, "")
      case .flow(_, _, _, let depth, let ids):
        for id in ids {
          guard let block = blocks[id] else { continue }
          if case .table = block { line(depth, "table", id, block.plainText) } else { line(depth, "text", id, block.plainText) }
        }
      }
    }
    return lines.isEmpty ? "(The page is empty.)" : lines.joined(separator: "\n")
  }
}
