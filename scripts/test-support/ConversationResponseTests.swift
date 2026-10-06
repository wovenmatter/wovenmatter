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
        view.setFrameSize(CGSize(width: 680, height: 40))
        require(view.fittingSize(width: 680) == wide, "A frame update changed cached response sizing")
        let narrow = view.fittingSize(width: 280)
        require(wide.height > 100 && narrow.height >= wide.height && narrow.width == 280,
            "Response height did not adapt to transcript width")
        require(view.fittingSize(width: 680) == wide, "Width changes did not restore the original wrapping")
        view.apply(content: source + "\n\n" + String(repeating: "A growing response wraps onto another line. ", count: 30), document: nil, isStreaming: true)
        require(view.frame.size == CGSize(width: 680, height: 40), "AppKit resized a frame owned by SwiftUI")
        let grown = view.fittingSize(width: 680)
        require(grown.height > wide.height, "Streaming growth reused a stale measured height")
        view.apply(content: "Short", document: nil, isStreaming: false)
        require(view.fittingSize(width: 680).height < wide.height, "Content replacement reused a stale measured height")
        let longSource = (0..<120).map { "## Section \($0)\n\nA long paragraph with **formatted text**, `code`, and enough words to wrap in a narrow panel." }.joined(separator: "\n\n")
        view.apply(content: longSource, document: nil, isStreaming: false)
        let longSize = view.fittingSize(width: 280)
        require(longSize.height > narrow.height && longSize.height.isFinite, "Long response layout was clipped or non-finite")
        view.selectAll(nil)
        require(view.selectedRange().length == view.string.utf16.count, "A long response could not be selected in full")
        // A clipped repaint must preserve the full box, even when its ends are offscreen.
        let drawSource = "# Heading\n\n> Quoted text.\n> Another quoted line.\n\n```swift\n"
            + (0..<80).map { "let line\($0) = \($0)" }.joined(separator: "\n")
            + "\n```\n\n---\n\nLast paragraph."
        view.apply(content: drawSource, document: nil, isStreaming: false)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setFrameSize(view.fittingSize(width: 320))
        let full = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: full)
        let middleCode = (view.string as NSString).range(of: "let line25")
        let glyphs = view.layoutManager!.glyphRange(forCharacterRange: middleCode, actualCharacterRange: nil)
        let glyphRect = view.layoutManager!.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
        let clip = NSRect(x: 0, y: floor(glyphRect.minY), width: view.bounds.width, height: 80)
        let partial = view.bitmapImageRepForCachingDisplay(in: clip)!
        view.cacheDisplay(in: clip, to: partial)
        let scale = CGFloat(full.pixelsWide) / view.bounds.width
        let yOffset = Int(clip.minY * scale)
        require((full.colorAt(x: 2, y: yOffset + 2)?.alphaComponent ?? 0) > 0.01,
            "The native drawing check produced an empty code background")
        for y in stride(from: 2, to: partial.pixelsHigh - 2, by: 3) {
            for x in stride(from: 2, to: partial.pixelsWide - 2, by: 3) {
                require(full.colorAt(x: x, y: y + yOffset) == partial.colorAt(x: x, y: y),
                    "Clipped code painting differs from the full response")
            }
        }
        let viewport = ConversationResponseViewport()
        viewport.textView.apply(content: drawSource, document: nil, isStreaming: false)
        viewport.setFrameSize(viewport.textView.fittingSize(width: 320))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        scroll.documentView = viewport
        viewport.updateVisibleFrame()
        require(viewport.textView.frame.height <= 160 + 512 && viewport.textView.enclosingScrollView === scroll,
            "The response added an inner scroll view or retained an oversized native backing surface")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        require(viewport.textView.frame.contains(scroll.contentView.bounds),
            "Native text backing does not cover the outer scroll viewport")
        let bufferedFrame = viewport.textView.frame
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 610))
        require(viewport.textView.frame == bufferedFrame, "Small scrolls needlessly moved the native backing")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
        require(viewport.textView.frame.contains(scroll.contentView.bounds), "Scrolling beyond the buffer lost visible text")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
        require(viewport.textView.textContainerOrigin == .zero, "Viewport movement shifted text layout coordinates")
        let scrolled = viewport.textView.bitmapImageRepForCachingDisplay(in: viewport.textView.bounds)!
        viewport.textView.cacheDisplay(in: viewport.textView.bounds, to: scrolled)
        let scrolledOffset = Int(viewport.textView.bounds.minY * scale)
        for y in stride(from: 2, to: scrolled.pixelsHigh - 2, by: 5) {
            for x in stride(from: 2, to: scrolled.pixelsWide - 2, by: 5) {
                // Window-backed and detached bitmaps may use different color spaces.
                // Alpha coverage checks glyphs and geometry without those RGB conversions.
                require(abs(full.colorAt(x: x, y: y + scrolledOffset)!.alphaComponent
                    - scrolled.colorAt(x: x, y: y)!.alphaComponent) <= 1.0 / 255,
                    "The scrolled viewport painted different text from the full response")
            }
        }
        let logicalRect = NSRect(x: 0, y: 800, width: 50, height: 20)
        require(viewport.textView.convert(logicalRect, to: viewport) == logicalRect,
            "Viewport movement changed logical text or selection coordinates")
        viewport.textView.selectAll(nil)
        require(viewport.textView.selectedRange().length == viewport.textView.string.utf16.count,
            "The visible viewport truncated Select All")
        require(viewport.textView.writeSelection(to: pasteboard, types: viewport.textView.writablePasteboardTypes),
            "Viewport-backed native selection could not be copied")
        let viewportCopy = pasteboard.string(forType: .string)!
        require(viewportCopy.contains("Heading") && viewportCopy.contains("let line79") && viewportCopy.contains("Last paragraph"),
            "Native copy lost offscreen response text")
        let savedSelection = viewport.textView.selectedRange()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        require(viewport.textView.selectedRange() == savedSelection, "Scrolling the native viewport discarded selection")
        viewport.setFrameSize(viewport.textView.fittingSize(width: 280))
        require(viewport.textView.frame.width == 280, "Width changes left a stale native backing width")
        viewport.textView.apply(content: "Short", document: nil, isStreaming: false)
        viewport.setFrameSize(viewport.textView.fittingSize(width: 280))
        scroll.contentView.scroll(to: .zero)
        require(viewport.bounds.contains(viewport.textView.frame), "Shrinking a response left native drawing outside its bounds")
        require(viewport.textView.bounds.origin == viewport.textView.frame.origin,
            "Resizing changed logical text coordinates")
        window.contentView = nil
        print("PASS: native whole-response selection/copy, rich styling, streaming/width sizing, clipped painting and viewport selection/coordinates")
    }
}
