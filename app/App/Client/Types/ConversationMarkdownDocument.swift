import Foundation
import WovenProtocol

/// Links from chat to pages inside Woven Matter (bots point users at Settings with them).
/// Only these exact links are live; any other `wovenmatter:` link stays plain text.
enum WovenAppLink: Equatable, Sendable {
    case accounts, botProfiles

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "wovenmatter", url.host?.lowercased() == "settings" else { return nil }
        switch url.path.lowercased() {
        case "/accounts": self = .accounts
        case "/bots/profiles": self = .botProfiles
        default: return nil
        }
    }
}

struct ConversationMarkdownDocument: Sendable {
    static let safeExternalLinkSchemes = Set(["http", "https", "mailto", "tel"])

    /// Clickable in a response: a safe external link or a Woven Matter page link.
    static func isLiveLink(_ url: URL) -> Bool { isSafeExternalLink(url) || WovenAppLink(url) != nil }

    /// A link to a local file, as the reply's file chips are found.
    static func isFileLink(_ url: URL) -> Bool { LibraryFileReference.path(url.absoluteString) != nil }

    static func isSafeExternalLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return safeExternalLinkSchemes.contains(scheme)
    }

    struct InlineText: Sendable {
        let attributed: AttributedString
        let rendered: AttributedString

        var plainText: String {
            String(attributed.characters)
        }

        init(_ source: String) {
            attributed = Self.render(source)
            rendered = Self.trimmingLineEnds(in: attributed)
        }

        private static func render(_ source: String) -> AttributedString {
            var rendered = (
                try? AttributedString(
                    markdown: source,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                )
            ) ?? AttributedString(source)
            // A link to a local file stays for the renderer to match against
            // the reply's file chips; it never opens on its own.
            let unsafeLinkRanges: [Range<AttributedString.Index>] = rendered.runs.compactMap { run in
                guard let link = run.link,
                      ConversationMarkdownDocument.isLiveLink(link) == false,
                      ConversationMarkdownDocument.isFileLink(link) == false else {
                    return nil
                }
                return run.range
            }
            for range in unsafeLinkRanges {
                rendered[range].link = nil
            }
            return rendered
        }

        /// Parse the complete inline span before trimming presentation whitespace.
        /// Per-line parsing breaks emphasis and links that cross a line boundary;
        /// Foundation already handles hard-break backslashes and literal escapes.
        private static func trimmingLineEnds(in attributed: AttributedString) -> AttributedString {
            var result = attributed
            var removals: [Range<AttributedString.Index>] = []
            for line in result.characters.split(separator: "\n", omittingEmptySubsequences: false) {
                var end = line.endIndex
                while end > line.startIndex {
                    let previous = result.characters.index(before: end)
                    guard result.characters[previous] == " " || result.characters[previous] == "\t",
                          result[previous..<end].inlinePresentationIntent?.contains(.code) != true else { break }
                    end = previous
                }
                if end < line.endIndex { removals.append(end..<line.endIndex) }
            }
            for range in removals.reversed() { result.removeSubrange(range) }
            return result
        }
    }

    struct ListItem: Sendable {
        let depth: Int
        let marker: String
        let checked: Bool?
        let blocks: [Block]
        /// More blocks of the item before it at this depth, after a nested
        /// list: shown at that item's text indent, without a marker.
        var continuation = false
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

    let blocks: [Block]

    init(_ rawContent: String) {
        var parser = Parser(rawContent)
        blocks = parser.parse()
    }

    /// The blocks of `source`, and the last place it can be cut so that the
    /// blocks before and after the cut are the blocks of the whole: the start
    /// of a complete, unindented line after a blank line that begins a block
    /// and cannot continue a list. Text appended later cannot change the
    /// blocks before that cut, so a stream parses each part once.
    static func blocks(cutting source: Substring) -> (blocks: [Block], cut: (offset: Int, blockCount: Int)?) {
        var parser = Parser(String(source))
        var starts: [(line: Int, blockCount: Int)] = []
        let blocks = parser.parse(recordingStarts: &starts)
        // Line offsets match the source only when it has no carriage returns.
        guard !source.utf8.contains(UInt8(ascii: "\r")) else { return (blocks, nil) }
        let lines = parser.lines
        guard let cut = starts.last(where: { start in
            let line = lines[start.line]
            return start.line > 0 && start.line + 1 < lines.count && Parser.isBlank(lines[start.line - 1])
                && line.first?.isWhitespace == false && Parser.listMarker(line) == nil
        }) else { return (blocks, nil) }
        let offset = lines[..<cut.line].reduce(0) { $0 + $1.utf8.count + 1 }
        return (blocks, (offset, cut.blockCount))
    }

    /// A reply cut off mid-stream, made to show its last block as what it
    /// was becoming; anything the parser already draws as intended comes back
    /// unchanged, and only the last block is ever touched.
    /// - A header row with no separator yet, as the very last line (a line
    ///   that starts with `|` and has at least two cells), is dropped: in a
    ///   cut reply it can only be the start of a table, or prose that looks
    ///   like one, and the two cannot be told apart. A header row with part
    ///   of its separator under it is dropped with it.
    /// - An inline code span, bold run or link target left open on the last
    ///   line is closed; code spans are skipped when looking (CommonMark's
    ///   rule: a run of backticks closes at the next run of the same length).
    /// - Inside an open code fence nothing changes: it draws as code already.
    /// A row of an established table, finished or not, stays a row.
    static func finishingCutText(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // An open fence, by the parser's matching: same character, at least as long.
        var fence: Fence?
        for line in lines {
            if let open = fence {
                if Parser.isFenceClosing(line, matching: open) { fence = nil }
            } else if let opening = Parser.fenceOpening(line) {
                fence = opening
            }
        }
        guard fence == nil else { return text }
        // The text's very last line, or the one before a single last line break.
        if lines.count > 1, lines[lines.count - 1].isEmpty { lines.removeLast() }
        guard let last = lines.last, !Parser.isBlank(last) else { return text }
        func isHeaderCandidate(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).first == "|" && (Parser.tableCells(line)?.count ?? 0) >= 2
        }
        func isTableLine(_ line: String?) -> Bool { line.map { Parser.tableCells($0) != nil } ?? false }
        let before = lines.count > 1 ? lines[lines.count - 2] : nil
        if isHeaderCandidate(last), !isTableLine(before) {
            // A header row alone.
            lines.removeLast()
            return lines.joined(separator: "\n")
        }
        if let before, isHeaderCandidate(before), last.contains("|"),
           last.trimmingCharacters(in: .whitespaces).allSatisfy({ "|-: ".contains($0) }),
           !Parser.startsTable(header: before, separator: last),
           !isTableLine(lines.count > 2 ? lines[lines.count - 3] : nil) {
            // A header row and part of its separator.
            lines.removeLast(2)
            return lines.joined(separator: "\n")
        }
        // Open inline markup on the last line, outside its code spans.
        let characters = Array(last)
        var outside = ""
        var openRun = 0
        var index = 0
        scan: while index < characters.count {
            guard characters[index] == "`" else { outside.append(characters[index]); index += 1; continue }
            var run = 0
            while index + run < characters.count, characters[index + run] == "`" { run += 1 }
            var search = index + run
            while search < characters.count {
                if characters[search] == "`" {
                    var other = 0
                    while search + other < characters.count, characters[search + other] == "`" { other += 1 }
                    if other == run {
                        // A boundary where the span was, so the delimiters on
                        // either side of it never join (`*` and `*` into `**`).
                        outside.append("\u{1}")
                        index = search + other
                        continue scan
                    }
                    search += other
                } else {
                    search += 1
                }
            }
            // No closing run: the rest of the line is code that was being written.
            openRun = run
            break
        }
        var closing = ""
        if openRun > 0 { closing += String(repeating: "`", count: openRun) }
        if outside.components(separatedBy: "**").count % 2 == 0 { closing += "**" }
        if let open = outside.range(of: "](", options: .backwards), !outside[open.upperBound...].contains(")") { closing += ")" }
        guard !closing.isEmpty else { return text }
        lines[lines.count - 1] = last + closing
        return lines.joined(separator: "\n")
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
        var continuation = false
        /// The fence of a code block open in `content`, whose lines keep
        /// their indent past the item's.
        var fence: Fence?
        /// The block `content` ends in, kept as lines are added rather than
        /// parsed again for each one, and its last line, which the parser
        /// reads again once the next line is known (a setext underline or a
        /// table separator can change what it was).
        var block: Parser.Opened = .none
        var lastLine = ""
        /// `lastLine` began `block`.
        var lastStartedBlock = false
        /// A code fence open in `content`, however its opening line came.
        var openFence: Fence?

        /// `content` ends in a paragraph a lazy line can continue.
        var endsInParagraph: Bool { block == .paragraph }

        /// A seed whose `content` is its first line.
        init(depth: Int, marker: String, checked: Bool?, continuationIndent: Int, content: String, continuation: Bool = false) {
            self.depth = depth
            self.marker = marker
            self.checked = checked
            self.continuationIndent = continuationIndent
            self.content = content
            self.continuation = continuation
            fence = Parser.fenceOpening(content)
            start(content)
        }

        private mutating func start(_ line: String) {
            block = Parser.opened(by: line)
            openFence = Parser.fenceOpening(line)
            lastLine = line
            lastStartedBlock = true
        }

        /// Records the block `content` ends in once `line` is added, `afterBlank`
        /// when blank lines came before it, by the parser's own predicates in
        /// the parser's order (`Parser.parse`, `parseParagraph`).
        mutating func track(_ line: String, afterBlank: Bool) {
            // Inside an open fence every line is code, up to the closing one.
            if openFence != nil { return trackCode(line) }
            guard !afterBlank else { return start(line) }
            // The line above began its block: the parser reads it with this
            // line in view, a setext underline before a table, both before
            // a rule, a list or a quote; a fence or a heading came first.
            if lastStartedBlock, block != .heading, block != .code {
                if Parser.setextLevel(lastLine, underline: line) != nil {
                    block = .heading
                    lastLine = line
                    lastStartedBlock = false
                    return
                }
                if Parser.startsTable(header: lastLine, separator: line) {
                    block = .table
                    lastLine = line
                    lastStartedBlock = false
                    return
                }
            }
            // A paragraph line with a separator under it ends the paragraph:
            // it starts a table, or with other cells a paragraph of its own.
            if block == .paragraph, !lastStartedBlock, Parser.interruptsParagraph(lastLine, next: line) {
                if Parser.startsTable(header: lastLine, separator: line) {
                    block = .table
                    lastLine = line
                    lastStartedBlock = false
                    return
                }
                lastStartedBlock = true
            }
            switch block {
            case .paragraph where !Parser.interruptsParagraph(line, next: nil),
                 .table where Parser.tableCells(line) != nil,
                 .quote where Parser.isQuote(line):
                lastLine = line
                lastStartedBlock = false
            default:
                start(line)
            }
        }

        /// A line of the item's fenced code.
        mutating func trackCode(_ line: String) {
            if let open = openFence, Parser.isFenceClosing(line, matching: open) { openFence = nil }
            block = .code
            lastLine = line
            lastStartedBlock = false
        }
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
            var starts: [(line: Int, blockCount: Int)] = []
            return parse(recordingStarts: &starts)
        }

        /// Also records the line each top-level block starts on.
        mutating func parse(recordingStarts starts: inout [(line: Int, blockCount: Int)]) -> [Block] {
            var result: [Block] = []
            while index < lines.count {
                if !Self.isBlank(lines[index]) { starts.append((index, result.count)) }
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
            guard index + 1 < lines.count, Self.startsTable(header: lines[index], separator: lines[index + 1]),
                  let headerCells = Self.tableCells(lines[index]),
                  let alignments = Self.tableSeparator(lines[index + 1]) else {
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
            /// Adds a line to the last item, after the blank lines before it.
            func add(_ text: String) {
                seeds[seeds.count - 1].content += String(repeating: "\n", count: pendingBlankLines > 0 ? pendingBlankLines + 1 : 1) + text
                pendingBlankLines = 0
            }
            /// The nearest item around the last one whose text a line at `indent` continues.
            func owner(accepting indent: Int) -> Int? {
                var depth = seeds[seeds.count - 1].depth
                for candidate in seeds.indices.dropLast().reversed() where seeds[candidate].depth < depth {
                    if seeds[candidate].continuationIndent <= indent { return candidate }
                    depth = seeds[candidate].depth
                }
                return nil
            }
            while index < lines.count {
                let line = lines[index]
                // Inside an item's fenced code, a line within the item is
                // code: it keeps its indent past the item's, and is never a marker.
                if let last = seeds.last, let fence = last.fence, Self.isBlank(line) == false,
                   Self.leadingIndent(line) >= last.continuationIndent {
                    let text = Self.removingIndent(line, columns: last.continuationIndent)
                    seeds[seeds.count - 1].track(text, afterBlank: pendingBlankLines > 0)
                    add(text)
                    if Self.isFenceClosing(text, matching: fence) { seeds[seeds.count - 1].fence = nil }
                    index += 1
                    continue
                }

                if let marker = Self.listMarker(line) {
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

                if Self.isBlank(line) {
                    pendingBlankLines += 1
                    index += 1
                    continue
                }

                let text = line.trimmingCharacters(in: .whitespaces)
                func track(_ text: String) { seeds[seeds.count - 1].track(text, afterBlank: pendingBlankLines > 0) }
                if Self.leadingIndent(line) >= seeds[seeds.count - 1].continuationIndent {
                    track(text)
                    add(text)
                    seeds[seeds.count - 1].fence = Self.fenceOpening(text)
                } else if let owner = owner(accepting: Self.leadingIndent(line)) {
                    if pendingBlankLines == 0, seeds[seeds.count - 1].endsInParagraph {
                        // A lazy line continues the paragraph it follows.
                        track(text)
                        add(text)
                    } else {
                        // After a blank line, a block of an item further out,
                        // following its nested list.
                        seeds.append(
                            ListItemSeed(
                                depth: seeds[owner].depth,
                                marker: seeds[owner].marker,
                                checked: nil,
                                continuationIndent: seeds[owner].continuationIndent,
                                content: text,
                                continuation: true
                            )
                        )
                        pendingBlankLines = 0
                    }
                } else {
                    break
                }
                index += 1
            }
            return .list(
                seeds.map {
                    var parser = Parser($0.content)
                    return ListItem(
                        depth: $0.depth,
                        marker: $0.marker,
                        checked: $0.checked,
                        blocks: parser.parse(),
                        continuation: $0.continuation
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
            guard index + 1 < lines.count else { return nil }
            return Self.setextLevel(lines[index], underline: lines[index + 1])
        }

        /// The setext heading level `underline` gives the line `line` above it.
        static func setextLevel(_ line: String, underline: String) -> Int? {
            guard isBlank(line) == false, leadingIndent(underline) <= 3 else { return nil }
            let underline = underline.trimmingCharacters(in: .whitespaces)
            guard underline.count >= 3 else { return nil }
            if underline.allSatisfy({ $0 == "=" }) { return 1 }
            if underline.allSatisfy({ $0 == "-" }) { return 2 }
            return nil
        }

        private func isBlockStart(at candidate: Int) -> Bool {
            Self.interruptsParagraph(lines[candidate], next: candidate + 1 < lines.count ? lines[candidate + 1] : nil)
        }

        /// Whether `line` ends the paragraph above it and starts a block,
        /// `next` being the line after it (nil when not known).
        static func interruptsParagraph(_ line: String, next: String?) -> Bool {
            if isIndentedCode(line) {
                return false
            }
            if fenceOpening(line) != nil
                || heading(line) != nil
                || listMarker(line) != nil
                || isQuote(line)
                || isThematicBreak(line) {
                return true
            }
            guard let next else { return false }
            return tableCells(line) != nil && tableSeparator(next) != nil
        }

        /// Whether a table starts at `header` with `separator` under it.
        static func startsTable(header: String, separator: String) -> Bool {
            guard let cells = tableCells(header), let alignments = tableSeparator(separator) else { return false }
            return cells.count == alignments.count
        }

        /// The kind of block a line opens where a block starts (`parse`),
        /// before the line after it is known.
        enum Opened { case none, code, heading, divider, list, quote, paragraph, table }
        static func opened(by line: String) -> Opened {
            if isBlank(line) { return .none }
            if isIndentedCode(line) { return .code }
            if fenceOpening(line) != nil { return .code }
            if heading(line) != nil { return .heading }
            if isThematicBreak(line) { return .divider }
            if listMarker(line) != nil { return .list }
            if isQuote(line) { return .quote }
            return .paragraph
        }

        static func isBlank(_ line: String) -> Bool {
            line.allSatisfy(\.isWhitespace)
        }

        static func fenceOpening(_ line: String) -> Fence? {
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

        static func isFenceClosing(_ line: String, matching fence: Fence) -> Bool {
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

        static func listMarker(_ line: String) -> ListMarker? {
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

        static func isQuote(_ line: String) -> Bool {
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


        /// `line` without up to `columns` of its leading spaces and tabs.
        private static func removingIndent(_ line: String, columns: Int) -> String {
            var removed = 0
            var rest = Substring(line)
            while removed < columns, let first = rest.first, first == " " || first == "\t" {
                removed += first == "\t" ? 4 : 1
                rest = rest.dropFirst()
            }
            return String(rest)
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

        /// How many cells `line` has as a table row, or nil when it is not one.
        static func tableCellCount(_ line: String) -> Int? { tableCells(line)?.count }

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

        static func tableCells(_ line: String) -> [String]? {
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
