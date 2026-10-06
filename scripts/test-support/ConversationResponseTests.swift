import AppKit
import SwiftUI

// Only the palette is stubbed; exercise the production renderer and native view.
enum DashboardPalette {
    static let foreground = Color(red: 0.039, green: 0.122, blue: 0.086)
    static let primary = Color(red: 0, green: 0.259, blue: 0.145)
    static let success = Color(red: 0.051, green: 0.561, blue: 0.353)
    static let mutedForeground = Color.gray
}

@main @MainActor
struct ConversationResponseTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        _ = NSApplication.shared
        let source = """
        # Heading

        First **bold** paragraph with *italics*, `inline code`, and [safe](https://example.com).

        - First item
        - [x] Completed item

        > Quoted text.

        ```swift
        let value = "🙂"
        print(value)
        ```

        | First | Second |
        | :--- | ---: |
        | Cell A | Cell B |

        Last paragraph with [unsafe](javascript:alert).
        """
        let view = ConversationResponseNativeTextView()
        view.apply(content: source, document: ConversationMarkdownDocument(source), isStreaming: false)
        require(view.isSelectable && !view.isEditable && view.isRichText, "Response must support read-only native selection")
        require(view.enclosingScrollView == nil, "Response added a competing scroll view")
        let storage = view.textStorage!
        for text in ["Heading", "First item", "☑", "Quoted text.", "print(value)", "Cell A", "Cell B", "Last paragraph"] {
            require(view.string.contains(text), "Rendered response lost \(text)")
        }
        var tableCells = 0
        var links: [URL] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            if (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock { tableCells += 1 }
            if let link = attributes[.link] as? URL { links.append(link) }
        }
        require(tableCells >= 4, "Tables must remain native selectable cells")
        require(links == [URL(string: "https://example.com")!], "Link safety changed")
        var requestedURL: URL?
        view.onOpenLink = { requestedURL = $0 }
        require(view.textView(view, clickedOnLink: URL(string: "https://example.com")!, at: 0), "Safe link click escaped confirmation")
        require(requestedURL == URL(string: "https://example.com"), "Safe link did not request confirmation")
        requestedURL = nil
        require(view.textView(view, clickedOnLink: "javascript:alert", at: 0) && requestedURL == nil,
            "Unsafe link click was opened or passed to AppKit")
        let boldRange = (view.string as NSString).range(of: "bold")
        let boldFont = storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont
        require(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask), "Inline bold styling was lost")
        let codeRange = (view.string as NSString).range(of: "print(value)")
        let codeFont = storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as! NSFont
        require(codeFont.isFixedPitch, "Code must retain a monospaced font")

        // Native selection and native copy span all block types, including cells.
        view.selectAll(nil)
        require(view.selectedRange() == NSRange(location: 0, length: storage.length), "Select All stops at a Markdown boundary")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        require(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes), "Native selection could not be copied")
        let selected = pasteboard.string(forType: .string)!
        require(selected.contains("Heading") && selected.contains("print(value)")
            && selected.contains("Cell A") && selected.contains("Last paragraph"), "Native copy omitted part of the response")
        let acrossBlocks = NSRange(location: boldRange.location, length: codeRange.location + codeRange.length - boldRange.location)
        view.setSelectedRange(acrossBlocks)
        view.apply(content: source + "\n\nStreamed tail.", document: nil, isStreaming: true)
        require(view.selectedRange() == acrossBlocks, "Streaming growth discarded the user's selection")
        require(view.string.hasSuffix("Streamed tail."), "Streaming tail disappeared")
        view.apply(content: "Short", document: nil, isStreaming: false)
        require(NSMaxRange(view.selectedRange()) <= view.string.utf16.count, "Shrinking content left an invalid selection")

        require(ConversationResponse.copy(source, to: pasteboard), "Copy response failed")
        require(pasteboard.string(forType: .string) == source, "Copy response did not preserve complete displayed Markdown")

        view.apply(content: source, document: nil, isStreaming: false)
        let wide = view.fittingSize(width: 680)
        let narrow = view.fittingSize(width: 280)
        require(wide.height > 100 && narrow.height >= wide.height && narrow.width == 280,
            "Response height did not adapt to transcript width")
        let longSource = (0..<120).map { "## Section \($0)\n\nA long paragraph with **formatted text**, `code`, and enough words to wrap in a narrow panel." }.joined(separator: "\n\n")
        view.apply(content: longSource, document: nil, isStreaming: false)
        let longSize = view.fittingSize(width: 280)
        require(longSize.height > narrow.height && longSize.height.isFinite, "Long response layout was clipped or non-finite")
        view.selectAll(nil)
        require(view.selectedRange().length == view.string.utf16.count, "A long response could not be selected in full")
        print("PASS: native whole-response selection/copy, Markdown styling, native tables, link safety, streaming selection and narrow/long layout")
    }
}
