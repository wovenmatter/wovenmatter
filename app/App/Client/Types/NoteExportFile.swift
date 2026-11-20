import Foundation
import WovenProtocol

/// An artifact as a file to save: a note as Markdown, a sheet as CSV, an app
/// as its HTML, a page as its document. `.document` is always the document.
enum NoteExportFile {
    static func contents(of document: NoteDocument, title: String,
                         format: WorkspaceNoteExportFormat) throws -> (Data, String) {
        if format == .document || document.kind == .canvas {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return (try encoder.encode(document), "json")
        }
        switch document.kind {
        case .canvas:
            return (Data(), "json")
        case .html:
            return (Data(document.html.utf8), "html")
        case .spreadsheet:
            let rows = document.blocks.flatMap { block -> [[String]] in
                switch block {
                case .richText(let text): text.plainText.isEmpty ? [] : [[text.plainText]]
                case .table(let table): table.rows.map { $0.cells.map(\.plainText) }
                }
            }
            return (Data((rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8), "csv")
        case .note:
            let body = document.blocks.map { block -> String in
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
                        var value = markdown(run.text)
                        if run.bold { value = "**" + value + "**" }
                        if run.italic { value = "*" + value + "*" }
                        if let link = run.link, !link.isEmpty,
                           let destination = link.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlFragmentAllowed
                               .subtracting(CharacterSet(charactersIn: "()<>\" \t\r\n\\"))) {
                            value = "[" + value + "](" + destination + ")"
                        }
                        return value
                    }.joined()
                case .table(let table):
                    let rows = table.rows.map { $0.cells.map { markdown($0.plainText).replacingOccurrences(of: "\n", with: "<br>") } }
                    let columns = table.columns.count
                    let header = table.headerRowCount > 0 ? rows.first ?? [] : Array(repeating: "", count: columns)
                    let body = table.headerRowCount > 0 ? Array(rows.dropFirst()) : rows
                    func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
                    return ([row(header), row(Array(repeating: "---", count: columns))] + body.map(row)).joined(separator: "\n")
                }
            }.joined(separator: "\n\n")
            return (Data(("# " + markdown(title) + "\n\n" + body + "\n").utf8), "md")
        }
    }

    /// A title reduced to a file name; "Note" when nothing usable remains.
    static func basename(_ title: String) -> String {
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let name = String(clean.prefix(100))
        return name.isEmpty ? "Note" : name
    }

    private static func markdown(_ value: String) -> String {
        var result = ""
        for character in value {
            if "\\`*_{}[]<>#|".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Cells are text, never a formula for a spreadsheet to run.
    private static func csvCell(_ value: String) -> String {
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let protected = first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
