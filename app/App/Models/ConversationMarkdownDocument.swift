import Foundation

struct ConversationMarkdownDocument: Sendable {
    static let safeExternalLinkSchemes = Set(["http", "https", "mailto", "tel"])

    static func isSafeExternalLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return safeExternalLinkSchemes.contains(scheme)
    }

    struct InlineText: Sendable {
        let source: String
        let attributed: AttributedString
        let renderedLines: [AttributedString]
        let rendered: AttributedString

        var plainText: String {
            String(attributed.characters)
        }

        init(_ source: String) {
            self.source = source
            attributed = Self.render(source)
            let lines = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { Self.renderLine(String($0)) }
            renderedLines = lines
            rendered = lines.enumerated().reduce(into: AttributedString()) { result, element in
                if element.offset > 0 {
                    result.append(AttributedString("\n"))
                }
                result.append(element.element)
            }
        }

        private static func render(_ source: String) -> AttributedString {
            var rendered = (
                try? AttributedString(
                    markdown: source,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )
            ) ?? AttributedString(source)
            let unsafeLinkRanges: [Range<AttributedString.Index>] = rendered.runs.compactMap { run in
                guard let link = run.link,
                      ConversationMarkdownDocument.isSafeExternalLink(link) == false else {
                    return nil
                }
                return run.range
            }
            for range in unsafeLinkRanges {
                rendered[range].link = nil
            }
            return rendered
        }

        private static func renderLine(_ source: String) -> AttributedString {
            var visibleSource = source
            while visibleSource.last == " " || visibleSource.last == "\t" {
                visibleSource.removeLast()
            }
            let trailingBackslashes = visibleSource.reversed().prefix(while: { $0 == "\\" }).count
            if trailingBackslashes.isMultiple(of: 2) == false {
                visibleSource.removeLast()
            }
            return render(visibleSource)
        }
    }

    struct ListItem: Sendable {
        let depth: Int
        let marker: String
        let checked: Bool?
        let source: String
        let blocks: [Block]

        var content: InlineText {
            InlineText(source)
        }
    }

    enum TableAlignment: Sendable {
        case leading
        case center
        case trailing
    }

    struct Table: Sendable {
        let header: [InlineText]
        let alignments: [TableAlignment]
        let rows: [[InlineText]]
    }

    indirect enum Block: Sendable {
        case paragraph(InlineText)
        case heading(level: Int, content: InlineText)
        case list([ListItem])
        case quote([Block])
        case code(language: String?, content: String)
        case table(Table)
        case divider
    }

    let rawContent: String
    let blocks: [Block]

    init(_ rawContent: String) {
        self.rawContent = rawContent
        var parser = Parser(rawContent)
        blocks = parser.parse()
    }

    static func preview(_ rawContent: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let document = ConversationMarkdownDocument(rawContent)
        var result = ""
        var needsSpace = false

        func append(_ value: String) {
            for character in value {
                if character.isWhitespace {
                    needsSpace = result.isEmpty == false
                    continue
                }
                if needsSpace {
                    result.append(" ")
                    needsSpace = false
                }
                result.append(character)
                if result.count >= limit { return }
            }
            needsSpace = result.isEmpty == false
        }

        func append(_ blocks: [Block]) {
            for block in blocks where result.count < limit {
                switch block {
                case let .paragraph(content), let .heading(_, content):
                    append(content.plainText)
                case let .list(items):
                    for item in items where result.count < limit {
                        append(item.blocks)
                    }
                case let .quote(quotedBlocks):
                    append(quotedBlocks)
                case let .code(_, content):
                    append(content)
                case let .table(table):
                    for cell in table.header where result.count < limit {
                        append(cell.plainText)
                    }
                    for row in table.rows where result.count < limit {
                        for cell in row where result.count < limit {
                            append(cell.plainText)
                        }
                    }
                case .divider:
                    continue
                }
                needsSpace = result.isEmpty == false
            }
        }

        append(document.blocks)
        if result.count > limit {
            result = String(result.prefix(limit))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension ConversationMarkdownDocument {
    struct ListItemSeed {
        let depth: Int
        let marker: String
        let checked: Bool?
        let continuationIndent: Int
        var content: String
    }

    struct ListMarker {
        let depth: Int
        let marker: String
        let checked: Bool?
        let continuationIndent: Int
        let content: String
    }

    struct Fence {
        let character: Character
        let length: Int
        let language: String?
    }

    struct Parser {
        let lines: [String]
        var index = 0

        init(_ source: String) {
            let normalized = source
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }

        mutating func parse() -> [Block] {
            var result: [Block] = []
            while index < lines.count {
                if Self.isBlank(lines[index]) {
                    index += 1
                } else if Self.isIndentedCode(lines[index]) {
                    result.append(parseIndentedCode())
                } else if let fence = Self.fenceOpening(lines[index]) {
                    result.append(parseFencedCode(fence))
                } else if let heading = Self.heading(lines[index]) {
                    result.append(.heading(level: heading.level, content: InlineText(heading.content)))
                    index += 1
                } else if let setextLevel = setextHeadingLevel() {
                    result.append(.heading(level: setextLevel, content: InlineText(lines[index])))
                    index += 2
                } else if let table = parseTableIfPresent() {
                    result.append(.table(table))
                } else if Self.isThematicBreak(lines[index]) {
                    result.append(.divider)
                    index += 1
                } else if Self.listMarker(lines[index]) != nil {
                    result.append(parseList())
                } else if Self.isQuote(lines[index]) {
                    result.append(parseQuote())
                } else {
                    result.append(parseParagraph())
                }
            }
            return result
        }

        private mutating func parseFencedCode(_ fence: Fence) -> Block {
            index += 1
            var codeLines: [String] = []
            while index < lines.count {
                if Self.isFenceClosing(lines[index], matching: fence) {
                    index += 1
                    break
                }
                codeLines.append(lines[index])
                index += 1
            }
            return .code(language: fence.language, content: codeLines.joined(separator: "\n"))
        }

        private mutating func parseTableIfPresent() -> Table? {
            guard index + 1 < lines.count,
                  let headerCells = Self.tableCells(lines[index]),
                  let alignments = Self.tableSeparator(lines[index + 1]),
                  headerCells.count == alignments.count else {
                return nil
            }

            index += 2
            var rows: [[InlineText]] = []
            while index < lines.count,
                  Self.isBlank(lines[index]) == false,
                  let cells = Self.tableCells(lines[index]) {
                let normalized = Array(cells.prefix(headerCells.count))
                    + Array(repeating: "", count: max(0, headerCells.count - cells.count))
                rows.append(normalized.map(InlineText.init))
                index += 1
            }
            return Table(
                header: headerCells.map(InlineText.init),
                alignments: alignments,
                rows: rows
            )
        }

        private mutating func parseList() -> Block {
            var seeds: [ListItemSeed] = []
            var pendingBlankLines = 0
            while index < lines.count {
                if let marker = Self.listMarker(lines[index]) {
                    seeds.append(
                        ListItemSeed(
                            depth: marker.depth,
                            marker: marker.marker,
                            checked: marker.checked,
                            continuationIndent: marker.continuationIndent,
                            content: marker.content
                        )
                    )
                    pendingBlankLines = 0
                    index += 1
                    continue
                }

                guard seeds.isEmpty == false else {
                    break
                }

                if Self.isBlank(lines[index]) {
                    pendingBlankLines += 1
                    index += 1
                    continue
                }

                guard Self.leadingIndent(lines[index]) >= seeds[seeds.count - 1].continuationIndent else {
                    break
                }

                if pendingBlankLines > 0 {
                    seeds[seeds.count - 1].content += String(
                        repeating: "\n",
                        count: pendingBlankLines + 1
                    )
                    pendingBlankLines = 0
                } else {
                    seeds[seeds.count - 1].content += "\n"
                }
                seeds[seeds.count - 1].content += lines[index].trimmingCharacters(in: .whitespaces)
                index += 1
            }
            return .list(
                seeds.map {
                    var parser = Parser($0.content)
                    return ListItem(
                        depth: $0.depth,
                        marker: $0.marker,
                        checked: $0.checked,
                        source: $0.content,
                        blocks: parser.parse()
                    )
                }
            )
        }

        private mutating func parseQuote() -> Block {
            var quotedLines: [String] = []
            while index < lines.count, Self.isQuote(lines[index]) {
                let trimmed = lines[index].drop(while: { $0 == " " || $0 == "\t" })
                var content = trimmed.dropFirst()
                if content.first == " " {
                    content = content.dropFirst()
                }
                quotedLines.append(String(content))
                index += 1
            }
            var parser = Parser(quotedLines.joined(separator: "\n"))
            return .quote(parser.parse())
        }

        private mutating func parseIndentedCode() -> Block {
            var codeLines: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.hasPrefix("\t") {
                    codeLines.append(String(line.dropFirst()))
                } else if line.hasPrefix("    ") {
                    codeLines.append(String(line.dropFirst(4)))
                } else if Self.isBlank(line) {
                    codeLines.append("")
                } else {
                    break
                }
                index += 1
            }
            while codeLines.last?.isEmpty == true {
                codeLines.removeLast()
            }
            return .code(language: nil, content: codeLines.joined(separator: "\n"))
        }

        private mutating func parseParagraph() -> Block {
            var paragraphLines: [String] = []
            while index < lines.count, Self.isBlank(lines[index]) == false {
                if paragraphLines.isEmpty == false, isBlockStart(at: index) {
                    break
                }
                paragraphLines.append(lines[index])
                index += 1
            }
            return .paragraph(InlineText(paragraphLines.joined(separator: "\n")))
        }

        private func setextHeadingLevel() -> Int? {
            guard index + 1 < lines.count, Self.isBlank(lines[index]) == false else { return nil }
            guard Self.leadingIndent(lines[index + 1]) <= 3 else { return nil }
            let underline = lines[index + 1].trimmingCharacters(in: .whitespaces)
            guard underline.count >= 3 else { return nil }
            if underline.allSatisfy({ $0 == "=" }) { return 1 }
            if underline.allSatisfy({ $0 == "-" }) { return 2 }
            return nil
        }

        private func isBlockStart(at candidate: Int) -> Bool {
            let line = lines[candidate]
            if Self.isIndentedCode(line) {
                return false
            }
            if Self.fenceOpening(line) != nil
                || Self.heading(line) != nil
                || Self.listMarker(line) != nil
                || Self.isQuote(line)
                || Self.isThematicBreak(line) {
                return true
            }
            guard candidate + 1 < lines.count else { return false }
            return Self.tableCells(line) != nil && Self.tableSeparator(lines[candidate + 1]) != nil
        }

        private static func isBlank(_ line: String) -> Bool {
            line.allSatisfy(\.isWhitespace)
        }

        private static func fenceOpening(_ line: String) -> Fence? {
            guard leadingIndent(line) <= 3 else { return nil }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let character = trimmed.first, character == "`" || character == "~" else {
                return nil
            }
            let length = trimmed.prefix(while: { $0 == character }).count
            guard length >= 3 else { return nil }
            let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
            let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
            return Fence(character: character, length: length, language: language)
        }

        private static func isFenceClosing(_ line: String, matching fence: Fence) -> Bool {
            guard leadingIndent(line) <= 3 else { return false }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let length = trimmed.prefix(while: { $0 == fence.character }).count
            guard length >= fence.length else { return false }
            return trimmed.dropFirst(length).allSatisfy(\.isWhitespace)
        }

        private static func heading(_ line: String) -> (level: Int, content: String)? {
            guard leadingIndent(line) <= 3 else { return nil }
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let level = trimmed.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(level) else { return nil }
            let remainder = trimmed.dropFirst(level)
            guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
            var content = remainder.trimmingCharacters(in: .whitespaces)
            while content.last == "#", content.dropLast().last?.isWhitespace == true {
                content = content.dropLast().trimmingCharacters(in: .whitespaces)
            }
            return (level, content)
        }

        private static func listMarker(_ line: String) -> ListMarker? {
            let indent = leadingIndent(line)
            let remainder = line.drop(while: { $0 == " " || $0 == "\t" })
            guard remainder.isEmpty == false else { return nil }

            var marker: String
            var content: Substring
            var continuationIndent: Int
            if let first = remainder.first,
               first == "-" || first == "*" || first == "+",
               remainder.dropFirst().first?.isWhitespace == true {
                marker = "•"
                content = remainder.dropFirst().drop(while: \.isWhitespace)
                continuationIndent = indent + 2
            } else {
                let digits = remainder.prefix(while: \.isNumber)
                guard digits.isEmpty == false else { return nil }
                let suffix = remainder.dropFirst(digits.count)
                guard let punctuation = suffix.first,
                      punctuation == "." || punctuation == ")",
                      suffix.dropFirst().first?.isWhitespace == true else {
                    return nil
                }
                marker = String(digits) + String(punctuation)
                content = suffix.dropFirst().drop(while: \.isWhitespace)
                continuationIndent = indent + digits.count + 2
            }

            var checked: Bool?
            if content.hasPrefix("[ ] ") {
                checked = false
                content = content.dropFirst(4)
            } else if content.lowercased().hasPrefix("[x] ") {
                checked = true
                content = content.dropFirst(4)
            }
            return ListMarker(
                depth: max(0, indent / 2),
                marker: marker,
                checked: checked,
                continuationIndent: continuationIndent,
                content: String(content)
            )
        }

        private static func isQuote(_ line: String) -> Bool {
            guard leadingIndent(line) <= 3 else { return false }
            return line.drop(while: { $0 == " " || $0 == "\t" }).first == ">"
        }

        private static func isIndentedCode(_ line: String) -> Bool {
            line.hasPrefix("\t") || line.hasPrefix("    ")
        }

        private static func isThematicBreak(_ line: String) -> Bool {
            guard leadingIndent(line) <= 3 else { return false }
            let compact = line.filter { $0.isWhitespace == false }
            guard compact.count >= 3, let marker = compact.first,
                  marker == "-" || marker == "*" || marker == "_" else {
                return false
            }
            return compact.allSatisfy { $0 == marker }
        }

        private static func leadingIndent(_ line: String) -> Int {
            var count = 0
            for character in line {
                if character == " " {
                    count += 1
                } else if character == "\t" {
                    count += 4
                } else {
                    break
                }
            }
            return count
        }

        private static func tableSeparator(_ line: String) -> [TableAlignment]? {
            guard leadingIndent(line) <= 3 else { return nil }
            guard let cells = tableCells(line), cells.isEmpty == false else { return nil }
            var alignments: [TableAlignment] = []
            for cell in cells {
                let trimmed = cell.trimmingCharacters(in: .whitespaces)
                let leadingColon = trimmed.first == ":"
                let trailingColon = trimmed.last == ":"
                let rule = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                guard rule.isEmpty == false, rule.allSatisfy({ $0 == "-" }) else { return nil }
                switch (leadingColon, trailingColon) {
                case (true, true): alignments.append(.center)
                case (false, true): alignments.append(.trailing)
                default: alignments.append(.leading)
                }
            }
            return alignments
        }

        private static func tableCells(_ line: String) -> [String]? {
            var value = line.trimmingCharacters(in: .whitespaces)
            guard value.contains("|") else { return nil }
            if value.first == "|" {
                value.removeFirst()
            }
            if value.last == "|" {
                value.removeLast()
            }

            var cells: [String] = []
            var current = ""
            var escaped = false
            var codeDelimiterCount = 0
            for character in value {
                if escaped {
                    if character != "|" {
                        current.append("\\")
                    }
                    current.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "`" {
                    current.append(character)
                    codeDelimiterCount = codeDelimiterCount == 0 ? 1 : 0
                } else if character == "|", codeDelimiterCount == 0 {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if escaped {
                current.append("\\")
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }
    }
}
