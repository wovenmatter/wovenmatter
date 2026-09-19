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
        try require(layout.count == document.blocks.count, "Reply is not split into direct block rows")
        try require(layout.first?.id == "reply", "First block lost the existing message scroll anchor")
        try require(Set(layout.map(\.id)).count == layout.count, "Block IDs are not unique")
        try require(layout.filter(\.isFirstMessagePart).count == 1, "Work header would be repeated")
        try require(layout.filter(\.isLastMessagePart).count == 1, "Changed-files footer would be repeated")
        try require(layout.dropFirst().allSatisfy { $0.spacingBefore == 14 }, "Markdown block spacing changed")
        try require(layout.first?.spacingBefore == 32, "Message boundary spacing changed")
        for (index, row) in layout.enumerated() {
            guard case .markdownBlock(let blockIndex, let count) = row.content else {
                throw Failure(description: "Formatted block fell back to an entire-message row")
            }
            try require(blockIndex == index && count == document.blocks.count, "Block order or extent changed")
        }
        // Lists, quotes, code and tables remain complete blocks for the existing
        // renderer. We do not reparse or split their syntax into arbitrary text.
        guard case .list(let items) = document.blocks[2], items.count == 2,
              case .quote(let quoted) = document.blocks[3], quoted.count == 2,
              case .code(let language, let code) = document.blocks[4], language == "swift",
              code.contains("print(value)"),
              case .table(let table) = document.blocks[5], table.rows.count == 1 else {
            throw Failure(description: "Rich block structure was not retained")
        }

        let before = "# Heading\n\nFirst paragraph.\n\n## Next\n\nStreaming tail"
        let during = before + " keeps growing"
        let after = during + "\n\nA new paragraph."
        let initialRows = rows(before)
        try require(rows(during).map(\.id) == initialRows.map(\.id), "Streaming tail changed stable row IDs")
        try require(Array(rows(after).prefix(initialRows.count).map(\.id)) == initialRows.map(\.id),
            "Appending a block renumbered already displayed blocks")
        let olderRows = rows("Older reply.", id: "older") + rows(after)
        try require(Array(olderRows.dropFirst().map(\.id)) == rows(after).map(\.id),
            "Prepending history changed the current message's block anchors")
        try require(rows(after).filter(\.isLastMessagePart).map(\.id) == [rows(after).last!.id],
            "Streaming append left the footer attached to an earlier block")

        for role in ["user", "system"] {
            let unsplit = rows(rich, role: role)
            try require(unsplit.count == 1 && unsplit[0].content == .message,
                "\(role) rendering was unexpectedly fragmented")
        }
        let failed = rows("  Request failed\n", failedRunError: "Request failed")
        try require(failed.count == 1 && failed[0].content == .message,
            "Duplicate failed reply left empty Markdown rows")
        try require(rows("Partial reply", failedRunError: "Request failed").first?.content != .message,
            "A useful partial reply was hidden after failure")
        try require(!ConversationMessageLayout.showsAssistantBody(content: "ignored", displayedBody: "", failedRunError: nil),
            "An empty projected reply became visible")
        let fallback = ConversationMessageLayout.rows(messageID: "pending", role: "assistant", content: "Waiting",
            displayedBody: "Waiting", failedRunError: nil, document: nil, mediaCount: 0)
        try require(fallback.count == 1 && fallback[0].id == "pending" && fallback[0].content == .message,
            "An unprepared message lost its fallback and anchor")
        try require(rows("").count == 1, "An empty document lost its message row")

        let media = rows(rich, mediaCount: 2)
        try require(media.count == layout.count + 2, "Provider media was omitted or duplicated")
        try require(Array(media.suffix(2).map(\.id)) == ["reply:media:0", "reply:media:1"],
            "Provider media lost stable ordering")
        try require(media.suffix(2).allSatisfy { $0.spacingBefore == 32 }, "Media spacing changed")
        try require(media.filter(\.isFirstMessagePart).count == 1 && media.filter(\.isLastMessagePart).count == 1,
            "Media duplicated the work header or changed-files footer")

        let unsafe = ConversationMarkdownDocument("[unsafe](javascript:alert) [safe](https://example.com)")
        guard case .paragraph(let text) = unsafe.blocks.first else { throw Failure(description: "Missing link fixture") }
        let links = text.rendered.runs.compactMap(\.link)
        try require(links.count == 1 && links[0].scheme == "https", "Prepared-block link safety changed")
        print("PASS: rich block rows, stable history/streaming anchors, header/footer ownership, failure fallback, media and link safety")
    }
}
