import Foundation

extension NoteDocument {
  /// Validate sparse table dimensions before normalization can fill missing cells.
  public static func exportRetained(content: String, title: String, format: WorkspaceNoteExportFormat) throws -> WorkspaceNoteExportContent {
    var budget = WorkspaceExportBudget()
    try budget.consume(content)
    try budget.consume(title)
    let document: NoteDocument
    if let decoded = try? JSONDecoder().decode(NoteDocument.self, from: Data(content.utf8)) {
      try decoded.validateExportBudget(title: title)
      document = decoded.normalized()
    } else {
      document = Self.decode(content)
    }
    return try document.exported(title: title, format: format)
  }

  /// Exports retained content only; linked databases and remote resources are not queried.
  public func exported(title: String, format: WorkspaceNoteExportFormat) throws -> WorkspaceNoteExportContent {
    try validateExportBudget(title: title)
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
    return WorkspaceNoteExportContent(data: try WorkspaceExportBudget.checked(data),
      suggestedFilename: Self.exportFilename(title: title, extension: fileExtension), fileExtension: fileExtension)
  }

  private func validateExportBudget(title: String) throws {
    var budget = WorkspaceExportBudget()
    try budget.consume(title)
    try budget.consume(html)
    func link(_ link: DatabaseArtifactLink?, budget: inout WorkspaceExportBudget) throws {
      guard let link else { return }
      try budget.consume(link.sourceID); try budget.consume(link.databaseID)
      try budget.consume(link.relativePath); try budget.consume(link.sqliteQuery)
    }
    func runs(_ runs: [NoteTextRun], budget: inout WorkspaceExportBudget) throws {
      try budget.consume(bytes: 128 * min(runs.count, WorkspaceExportBudget.maximumItems + 1), items: runs.count)
      for run in runs {
        try budget.consume(run.text); try budget.consume(run.link); try budget.consume(run.fontFamily)
        try budget.consume(run.foregroundHex); try budget.consume(run.highlightHex)
      }
    }
    try link(databaseLink, budget: &budget)
    try budget.consume(items: blocks.count)
    for block in blocks {
      switch block {
      case .richText(let text):
        try budget.consume(text.id)
        try runs(text.runs, budget: &budget)
      case .table(let table):
        try budget.consume(table.id)
        try link(table.databaseLink, budget: &budget)
        let columns = max(1, table.columns.count)
        let rows = max(1, table.rows.count)
        guard columns <= WorkspaceExportBudget.maximumItems,
              rows <= budget.remainingItems / columns else { throw WorkspaceExportError.tooLarge }
        try budget.consume(items: columns * rows)
        for column in table.columns { try budget.consume(column.id) }
        for row in table.rows {
          try budget.consume(row.id)
          // Count extra stored cells as well, even though normalization drops them.
          try budget.consume(items: max(0, row.cells.count - columns))
          for cell in row.cells {
            try budget.consume(cell.id); try budget.consume(cell.backgroundHex)
            try runs(cell.runs, budget: &budget)
          }
        }
      }
    }
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
