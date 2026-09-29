import Foundation

extension NoteDocument {
  /// Exports retained content only; linked databases and remote resources are not queried.
  public func exported(title: String, format: WorkspaceNoteExportFormat) throws -> WorkspaceNoteExportContent {
    let data: Data
    let fileExtension: String
    if format == .document {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      data = try encoder.encode(self)
      fileExtension = "json"
    } else {
      switch kind {
      case .html:
        data = Data(html.utf8)
        fileExtension = "html"
      case .spreadsheet:
        let rows = blocks.flatMap { block -> [[String]] in
          switch block {
          case .richText(let text): return text.plainText.isEmpty ? [] : [[text.plainText]]
          case .table(let table): return table.rows.map { $0.cells.map(\.plainText) }
          }
        }
        data = Data((rows.map { $0.map(Self.csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
        fileExtension = "csv"
      case .note:
        let body = blocks.map { block -> String in
          switch block {
          case .richText(let text):
            let prefix: String = switch text.style {
            case .paragraph: ""
            case .heading1: "# "
            case .heading2: "## "
            case .heading3: "### "
            case .heading4: "#### "
            case .heading5: "##### "
            case .heading6: "###### "
            case .bulletedList: "- "
            case .numberedList: "1. "
            }
            return prefix + text.runs.map { run in
              var value = Self.markdownText(run.text)
              if run.bold { value = "**" + value + "**" }
              if run.italic { value = "*" + value + "*" }
              if let link = run.link, !link.isEmpty {
                let allowed = CharacterSet.urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "()<>\" \t\r\n\\"))
                if let destination = link.addingPercentEncoding(withAllowedCharacters: allowed) {
                  value = "[" + value + "](" + destination + ")"
                }
              }
              return value
            }.joined()
          case .table(let table):
            let rows = table.rows.map { $0.cells.map { Self.markdownText($0.plainText).replacingOccurrences(of: "\n", with: "<br>") } }
            let columns = table.columns.count
            let header = table.headerRowCount > 0 ? rows.first ?? [] : Array(repeating: "", count: columns)
            let body = table.headerRowCount > 0 ? Array(rows.dropFirst()) : rows
            func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
            return ([row(header), row(Array(repeating: "---", count: columns))] + body.map(row)).joined(separator: "\n")
          }
        }.joined(separator: "\n\n")
        data = Data(("# " + Self.markdownText(title) + "\n\n" + body + "\n").utf8)
        fileExtension = "md"
      }
    }
    return WorkspaceNoteExportContent(data: data,
      suggestedFilename: Self.exportFilename(title: title, extension: fileExtension), fileExtension: fileExtension)
  }

  private static func markdownText(_ value: String) -> String {
    var result = ""
    for character in value {
      if "\\`*_{}[]<>#|".contains(character) { result.append("\\") }
      result.append(character)
    }
    return result
  }

  private static func csvCell(_ value: String) -> String {
    // Cells are retained text, never an instruction to execute a spreadsheet formula.
    let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
    let protected = first.map { "=+-@".contains($0) } == true ? "'" + value : value
    return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private static func exportFilename(title: String, extension suffix: String) -> String {
    let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")
      .union(.controlCharacters)).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    var name = ""
    var bytes = 0
    for character in clean.prefix(100) {
      let count = String(character).decomposedStringWithCanonicalMapping.utf8.count
      guard bytes + count <= 200 else { break }
      name.append(character); bytes += count
    }
    return (name.isEmpty ? "Note" : name) + "." + suffix
  }
}
