import Foundation

@main
struct ConversationMessageLayoutTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func rows(_ source: String, id: String = "reply", role: String = "assistant",
                     failedRunError: String? = nil, mediaCount: Int = 0) -> [ConversationMessageLayout.Row] {
        ConversationMessageLayout.rows(messageID: id, role: role, content: source,
            displayedBody: source, failedRunError: failedRunError,
            document: ConversationMarkdownDocument(source), mediaCount: mediaCount)
    }

    static func main() throws {
        let rich = """
        # Heading

        Paragraph with **emphasis**, `inline code`, and a [safe link](https://example.com).

        - First item
        - Second item

        > Quoted paragraph.
        >
        > Another quoted paragraph.

        ```swift
        let value = 42
        print(value)
        ```

        | First | Second |
        | --- | --- |
        | Cell A | Cell B |

        ---
        """
        let document = ConversationMarkdownDocument(rich)
        let layout = rows(rich)
        try require(document.blocks.count == 7, "Rich fixture lost a top-level block")
        try require(layout.count == 3, "Seven rich blocks should occupy two bounded lazy rows and a footer")
        try require(layout.first?.id == "reply", "First block lost the existing message scroll anchor")
        try require(Set(layout.map(\.id)).count == layout.count, "Block IDs are not unique")
        try require(layout.filter(\.isFirstMessagePart).count == 1, "Work header would be repeated")
        try require(layout.filter(\.isLastMessagePart).count == 1, "Last body padding would be repeated")
        try require(layout.dropFirst().dropLast().allSatisfy { $0.spacingBefore == 14 }, "Markdown block spacing changed")
        try require(layout.last?.content == .fileChanges && layout.last?.id == "reply:files"
            && layout.last?.spacingBefore == 0, "Empty files footer would add a gap or lose its stable identity")
        try require(layout.first?.spacingBefore == 32, "Message boundary spacing changed")
        try require(layout.map(\.id) == ["reply", "reply:markdown:4", "reply:files"],
            "Group identity is not anchored to its first block ordinal")
        var richRanges: [Range<Int>] = []
        for row in layout.dropLast() {
            guard case .markdownBlocks(let range, let count) = row.content else {
                throw Failure(description: "Formatted blocks fell back to an entire-message row")
            }
            richRanges.append(range)
            try require(count == document.blocks.count, "Group lost the document extent")
        }
        try require(richRanges == [0..<4, 4..<7], "Rich content was not grouped at the chosen boundary")
        // Lists, quotes, code and tables remain complete blocks for the existing
        // renderer. We do not reparse or split their syntax into arbitrary text.
        guard case .list(let items) = document.blocks[2], items.count == 2,
              case .quote(let quoted) = document.blocks[3], quoted.count == 2,
              case .code(let language, let code) = document.blocks[4], language == "swift",
              code.contains("print(value)"),
              case .table(let table) = document.blocks[5], table.rows.count == 1 else {
            throw Failure(description: "Rich block structure was not retained")
        }

        // Exercise every tail size and multiple group boundaries. Reconstruct
        // the rendered block ordinals, not just the number of layout rows.
        var previousBodyIDs: [String] = []
        for blockCount in 1...(ConversationMessageLayout.maximumMarkdownBlocksPerRow * 8 + 1) {
            let source = (0..<blockCount).map { "Paragraph \($0)." }.joined(separator: "\n\n")
            let growing = rows(source)
            let bodyRows = Array(growing.dropLast())
            let parsed = ConversationMarkdownDocument(source)
            try require(parsed.blocks.count == blockCount, "Coverage fixture did not produce separate paragraphs")
            var renderedOrdinals: [Int] = []
            for row in bodyRows {
                guard case .markdownBlocks(let range, let count) = row.content else {
                    throw Failure(description: "Grouped response unexpectedly contains a fallback row")
                }
                try require(!range.isEmpty && range.count <= ConversationMessageLayout.maximumMarkdownBlocksPerRow,
                    "A lazy row exceeded the bounded block count")
                try require(count == blockCount && range.lowerBound >= 0 && range.upperBound <= count,
                    "A group extends beyond the prepared document")
                try require(row.isLastMessagePart == (range.upperBound == count),
                    "Body bottom padding is attached to the wrong group")
                renderedOrdinals.append(contentsOf: range)
            }
            try require(renderedOrdinals == Array(parsed.blocks.indices),
                "Growing response omitted, duplicated, or reordered rendered blocks")
            try require(Array(bodyRows.prefix(previousBodyIDs.count).map(\.id)) == previousBodyIDs,
                "Appending within or across a group changed a retained row's identity")
            try require(rows(source + " continues streaming").map(\.id) == growing.map(\.id),
                "Extending the current paragraph changed row identity")
            try require(growing.last?.id == "reply:files" && growing.last?.spacingBefore == 0,
                "Growing groups displaced the stable files footer or introduced empty spacing")
            try require(bodyRows.filter(\.isFirstMessagePart).count == 1
                && bodyRows.filter(\.isLastMessagePart).count == 1,
                "Growing groups repeated message edge padding or work-header ownership")
            previousBodyIDs = bodyRows.map(\.id)
        }

        let before = "# Heading\n\nFirst paragraph.\n\n## Next\n\nStreaming tail"
        let during = before + " keeps growing"
        let after = during + "\n\nA new paragraph."
        let initialRows = rows(before)
        try require(rows(during).map(\.id) == initialRows.map(\.id), "Streaming tail changed stable row IDs")
        try require(Array(rows(after).prefix(initialRows.count - 1).map(\.id)) == initialRows.dropLast().map(\.id),
            "Appending a block renumbered already displayed blocks")
        let olderRows = rows("Older reply.", id: "older") + rows(after)
        try require(Array(olderRows.dropFirst(2).map(\.id)) == rows(after).map(\.id),
            "Prepending history changed the current message's block anchors")
        try require(rows(after).filter(\.isLastMessagePart).map(\.id) == [rows(after).dropLast().last!.id],
            "Streaming append left bottom padding attached to an earlier block")
        try require(initialRows.last?.id == rows(after).last?.id
            && rows("").last?.id == initialRows.last?.id,
            "Streaming append or initial reply changed the files card identity")
        try require(rows(after).filter { $0.content == .fileChanges }.count == 1,
            "Streaming appended a duplicate changed-files card")

        for role in ["user", "system"] {
            let unsplit = rows(rich, role: role)
            try require(unsplit.count == 1 && unsplit[0].content == .message,
                "\(role) rendering was unexpectedly fragmented")
        }
        let failed = rows("  Request failed\n", failedRunError: "Request failed")
        try require(failed.count == 2 && failed[0].content == .message && failed[1].content == .fileChanges,
            "Duplicate failed reply left empty Markdown rows")
        try require(rows("Partial reply", failedRunError: "Request failed").first?.content != .message,
            "A useful partial reply was hidden after failure")
        try require(!ConversationMessageLayout.showsAssistantBody(content: "ignored", displayedBody: "", failedRunError: nil),
            "An empty projected reply became visible")
        let fallback = ConversationMessageLayout.rows(messageID: "pending", role: "assistant", content: "Waiting",
            displayedBody: "Waiting", failedRunError: nil, document: nil, mediaCount: 0)
        try require(fallback.count == 2 && fallback[0].id == "pending" && fallback[0].content == .message,
            "An unprepared message lost its fallback and anchor")
        try require(rows("").count == 2 && rows("").first?.id == "reply"
            && rows("").last?.spacingBefore == 0, "An empty document lost its message anchor or acquired a footer gap")

        let media = rows(rich, mediaCount: 2)
        try require(media.count == layout.count + 2, "Provider media was omitted or duplicated")
        try require(Array(media.suffix(2).map(\.id)) == ["reply:media:0", "reply:media:1"],
            "Provider media lost stable ordering")
        try require(media.suffix(2).allSatisfy { $0.spacingBefore == 32 }, "Media spacing changed")
        try require(media.filter(\.isFirstMessagePart).count == 1 && media.filter(\.isLastMessagePart).count == 1,
            "Media duplicated the work header or body padding")

        let unsafe = ConversationMarkdownDocument("[unsafe](javascript:alert) [safe](https://example.com)")
        guard case .paragraph(let text) = unsafe.blocks.first else { throw Failure(description: "Missing link fixture") }
        let links = text.rendered.runs.compactMap(\.link)
        try require(links.count == 1 && links[0].scheme == "https", "Prepared-block link safety changed")
        print("PASS: bounded rich-block groups, exhaustive growing coverage, stable history/streaming anchors, header/footer ownership, failure fallback, media and link safety")
    }
}
