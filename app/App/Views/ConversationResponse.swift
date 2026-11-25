import AppKit
private typealias ResponseFont = NSFont
private let responseAbsolute = NSTextBlock.ValueType.absoluteValueType
private let responsePercentage = NSTextBlock.ValueType.percentageValueType
import SwiftUI

/// One selectable text surface and one copy action for the complete response.
extension EnvironmentValues {
    /// When set, links in a response go here instead of asking to open them externally.
    @Entry var conversationLinkHandler: ((URL) -> Void)?
}

struct ConversationResponse: View {
    enum Style: Equatable {
        case reply
        /// Reasoning inside the work log: smaller, at the log's ink.
        case reasoning

        var scale: CGFloat { self == .reply ? 1 : 0.9 }
        var inkOpacity: CGFloat { self == .reply ? 1 : 0.72 }
    }

    let content: String
    var document: ConversationMarkdownDocument? = nil
    let isStreaming: Bool
    var showsCopyButton = true
    /// While the turn runs, its dots hold the row Copy takes once it ends.
    var showsRunningDots = false
    var style: Style = .reply
    @Environment(\.conversationLinkHandler) private var linkHandler
    @State private var copied = false
    @State private var pendingExternalURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConversationResponseText(content: content, document: document, isStreaming: isStreaming, style: style) { url in
                // Page links only work where a handler routes them (bot chats).
                if let linkHandler { linkHandler(url) } else if WovenAppLink(url) == nil { pendingExternalURL = url }
            }
            .frame(maxWidth: ConversationMetrics.measure, alignment: .leading)

            if showsCopyButton {
                // One row, the same height while the reply streams and once it
                // settles, so nothing moves when the turn ends.
                ZStack(alignment: .leading) {
                    if showsRunningDots {
                        ConversationRunningDots()
                    } else if !isStreaming {
                        copyButton
                    }
                }
                .frame(height: ConversationMetrics.actionRowHeight)
                .padding(.top, ConversationMetrics.rowGap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: content) { copied = false }
        .alert("Open external link?", isPresented: Binding(
            get: { pendingExternalURL != nil },
            set: { if !$0 { pendingExternalURL = nil } }
        ), presenting: pendingExternalURL) { url in
            Button("Cancel", role: .cancel) { pendingExternalURL = nil }
            Button("Open") {
                pendingExternalURL = nil
                NSWorkspace.shared.open(url)
            }
        } message: { url in
            Text(url.absoluteString)
        }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(content, forType: .string)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: ConversationMetrics.actionRowHeight, height: ConversationMetrics.actionRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(WovenIconButtonStyle())
        // The glyph lines up with the text edge; its hover target hangs left of it.
        .offset(x: -(ConversationMetrics.actionRowHeight - 12) / 2)
        .help("Copy complete response")
        .accessibilityLabel(copied ? "Response copied" : "Copy response")
    }
}

private struct ConversationResponseText: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    let content: String
    let document: ConversationMarkdownDocument?
    let isStreaming: Bool
    let style: ConversationResponse.Style
    let onOpenLink: (URL) -> Void

    func makeNSView(context: Context) -> ConversationResponseViewport {
        ConversationResponseViewport()
    }

    func updateNSView(_ viewport: ConversationResponseViewport, context: Context) {
        viewport.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let textView = viewport.textView
        textView.onOpenLink = onOpenLink
        textView.onPressWhileGrowing = isStreaming ? transcriptInteraction : nil
        if textView.apply(content: content, document: document, isStreaming: isStreaming, style: style,
                          colorScheme: colorScheme) {
            viewport.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ConversationResponseViewport,
                      context: Context) -> CGSize? {
        nsView.textView.fittingSize(width: proposal.width ?? ConversationMetrics.measure)
    }
}

/// Keep the native backing surface bounded while text storage and layout cover
/// the entire reply. There is still one text view and no nested scroll view.
final class ConversationResponseViewport: NSView {
    let textView = ConversationResponseNativeTextView()
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
        updateVisibleFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateVisibleFrame()
    }

    override func layout() {
        super.layout()
        updateVisibleFrame()
    }

    @objc private func scrollBoundsChanged(_ notification: Notification) { updateVisibleFrame() }

    func updateVisibleFrame() {
        let visible = window == nil ? bounds : visibleRect.intersection(bounds)
        // Leave a small backing buffer around the viewport. Repositioning on
        // every scroll tick invalidates AppKit text drawing even when the same
        // laid-out content is still visible.
        let padding: CGFloat = 256
        let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? visible.height
        let heightLimit = min(bounds.height, viewportHeight + 2 * padding)
        if !visible.isEmpty, textView.frame.width == bounds.width, textView.frame.height <= heightLimit,
           bounds.contains(textView.frame), textView.frame.contains(visible) { return }
        let y = visible.isEmpty ? 0 : max(0, visible.minY - padding)
        let height = visible.isEmpty ? 1 : min(bounds.maxY - y, heightLimit)
        let frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
        if textView.frame.size != frame.size { textView.setFrameSize(frame.size) }
        if textView.frame.origin != frame.origin { textView.setFrameOrigin(frame.origin) }
        let origin = NSPoint(x: 0, y: y)
        if textView.bounds.origin != origin { textView.setBoundsOrigin(origin) }
    }
}

/// TextKit owns selection across paragraphs, list items, code and table cells.
/// It has no inner scroll view; wheel events continue through the transcript.
final class ConversationResponseNativeTextView: NSTextView, NSTextViewDelegate {
    // Bounds follow the viewport; text and selection retain document coordinates.
    override var textContainerOrigin: NSPoint { .zero }
    var onOpenLink: ((URL) -> Void)?
    /// Hands the transcript's scroll to the reader while the reply grows.
    var onPressWhileGrowing: (@MainActor () -> Void)?
    private var appliedContent: String?
    private var appliedStreaming: Bool?
    private var appliedColorScheme: ColorScheme?
    private var appliedStyle: ConversationResponse.Style?
    private var measuredSize: CGSize?
    private var decorations: [(key: NSAttributedString.Key, range: NSRange)] = []
    /// While streaming: the source before the last stable cut, the length of
    /// its rendering at the start of the text storage, and its last block.
    private var stable: (source: String, length: Int, last: ConversationMarkdownDocument.Block?)?

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: ConversationMetrics.measure, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        isHorizontallyResizable = false
        // SwiftUI owns the frame; layout uses the explicit proposed width below.
        isVerticallyResizable = false
        textContainer?.widthTracksTextView = false
        delegate = self
        linkTextAttributes = [.foregroundColor: WovenColors.success, .underlineStyle: 0]
        setAccessibilityLabel("Agent response")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func apply(content: String, document: ConversationMarkdownDocument?, isStreaming: Bool,
               style: ConversationResponse.Style = .reply, colorScheme: ColorScheme = .light) -> Bool {
        guard appliedContent != content || appliedStreaming != isStreaming
            || appliedColorScheme != colorScheme || appliedStyle != style else { return false }
        appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let samePresentation = appliedColorScheme == colorScheme && appliedStyle == style
        appliedColorScheme = colorScheme
        appliedStyle = style
        let selection = selectedRange()
        let previous = selection.length > 0 ? NSString(string: string) : nil
        guard let textStorage else { return false }
        // While a reply streams, the blocks before its last stable cut are
        // already in the text storage: only what follows is parsed, rendered
        // and laid out again, so a chunk costs its own length, not the reply's.
        // The cut stays valid while the reply only grows past what was applied,
        // through the last chunk when it settles.
        let kept: (source: Int, length: Int, last: ConversationMarkdownDocument.Block?)
        let tail: NSAttributedString
        if document == nil, let stable, samePresentation, let appliedContent,
           content.utf8.starts(with: appliedContent.utf8), stable.length <= textStorage.length {
            kept = (stable.source.utf8.count, stable.length, stable.last)
            tail = renderStreaming(content, keeping: kept, style: style)
        } else if isStreaming, document == nil {
            kept = (0, 0, nil)
            tail = renderStreaming(content, keeping: kept, style: style)
        } else {
            stable = nil
            kept = (0, 0, nil)
            tail = ConversationResponseAttributedText.render(document ?? ConversationMarkdownDocument(content), style: style)
        }
        textStorage.replaceCharacters(in: NSRange(location: kept.length, length: textStorage.length - kept.length), with: tail)
        measuredSize = nil
        decorations.removeAll { $0.range.location >= kept.length }
        for key in [NSAttributedString.Key.responseCode, .responseQuote, .responseDivider, .responseTable] {
            tail.enumerateAttribute(key, in: NSRange(location: 0, length: tail.length)) { value, range, _ in
                if value != nil { decorations.append((key, NSRange(location: range.location + kept.length, length: range.length))) }
            }
        }
        // Streaming appends keep the selection; once the selected text itself
        // changes (a replacement, or a rerendered prefix), it no longer
        // identifies what the user chose.
        let end = NSMaxRange(selection)
        let selectionUnchanged = previous.map { previous in
            let rendered = textStorage.string as NSString
            return end <= previous.length && end <= rendered.length
                && previous.substring(to: end) == rendered.substring(to: end)
        } ?? false
        setSelectedRange(selectionUnchanged ? selection : NSRange(location: 0, length: 0))
        appliedContent = content
        appliedStreaming = isStreaming
        return true
    }

    /// What follows the kept part of a streaming reply, rendered, with the
    /// reply's new stable cut recorded. Each part is rendered after the last
    /// block before it, which is all a block's spacing depends on.
    private func renderStreaming(_ content: String, keeping kept: (source: Int, length: Int, last: ConversationMarkdownDocument.Block?),
                                 style: ConversationResponse.Style) -> NSAttributedString {
        let start = content.utf8.index(content.startIndex, offsetBy: kept.source)
        let source = content[start...]
        let (blocks, cut) = ConversationMarkdownDocument.blocks(cutting: source)
        let settledCount = cut?.blockCount ?? 0
        let settled = ConversationResponseAttributedText.render(Array(blocks[..<settledCount]), after: kept.last,
                                                                endsResponse: false, style: style)
        let last = settledCount > 0 ? blocks[settledCount - 1] : kept.last
        let tail = NSMutableAttributedString(attributedString: settled)
        tail.append(ConversationResponseAttributedText.render(Array(blocks[settledCount...]), after: last,
                                                              endsResponse: true, style: style))
        let end = cut.map { source.utf8.index(source.startIndex, offsetBy: $0.offset) } ?? start
        stable = (String(content[..<end]), kept.length + settled.length, last)
        return tail
    }

    func fittingSize(width: CGFloat) -> CGSize {
        let width = max(1, width)
        guard let textContainer, let layoutManager else { return CGSize(width: width, height: 1) }
        if let measuredSize, measuredSize.width == width { return measuredSize }
        if textContainer.size.width != width {
            textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: textContainer)
        var height = layoutManager.usedRect(for: textContainer).maxY
        if let textStorage, textStorage.length > 0,
           (textStorage.string as NSString).character(at: textStorage.length - 1) == 0x0A {
            // Text ending in a box keeps its last line break: measure to the
            // box's edge, not to the empty line after it.
            height = layoutManager.extraLineFragmentRect.minY
            if textStorage.attribute(.responseCode, at: textStorage.length - 1, effectiveRange: nil) != nil {
                height += ConversationMetrics.Prose.codePadding - ConversationMetrics.Prose.codeLineSpacing
            }
        }
        let size = CGSize(width: width, height: max(1, ceil(height)))
        measuredSize = size
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        if !decorations.isEmpty, let layoutManager, let textContainer, let textStorage {
            typealias Prose = ConversationMetrics.Prose
            // Include code-box padding and the full line width for partial redraws.
            let reach = Prose.codePadding + ConversationMetrics.tight
            let visibleRect = NSRect(x: 0, y: dirtyRect.minY - reach,
                                     width: textContainer.size.width, height: dirtyRect.height + 2 * reach)
            let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let visibleCharacters = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
            let text = textStorage.string as NSString
            for decoration in decorations where NSIntersectionRange(decoration.range, visibleCharacters).length > 0 {
                guard let block = textStorage.attribute(decoration.key, at: decoration.range.location,
                                                        effectiveRange: nil) as? ResponseBlockDecoration else { continue }
                let glyphs = layoutManager.glyphRange(forCharacterRange: decoration.range, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                // Used rects leave out the spacing above a line, and keep the
                // line spacing below every line but the text's last.
                let top = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY
                let lastLine = layoutManager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
                let width = textContainer.size.width - block.indent
                switch decoration.key {
                case .responseCode:
                    let rect = NSRect(x: block.indent, y: top - Prose.codePadding, width: width,
                                      height: lastLine.maxY - top + 2 * Prose.codePadding - Prose.codeLineSpacing)
                    WovenColors.primary.withAlphaComponent(0.05).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: ConversationMetrics.blockRadius,
                                 yRadius: ConversationMetrics.blockRadius).fill()
                case .responseQuote:
                    let end = NSMaxRange(decoration.range) - 1
                    let trailing = text.character(at: end) == 0x0A
                        ? (textStorage.attribute(.paragraphStyle, at: end, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing ?? 0
                        : 0
                    WovenColors.foreground.withAlphaComponent(0.16).setFill()
                    NSRect(x: block.indent, y: top, width: Prose.quoteBar, height: lastLine.maxY - trailing - top).fill()
                case .responseDivider:
                    WovenColors.foreground.withAlphaComponent(0.16).setFill()
                    NSRect(x: block.indent, y: top, width: width, height: 1).fill()
                default:
                    // The first cell's top left and the last cell's bottom right.
                    let cells = [decoration.range.location, NSMaxRange(decoration.range) - 1].compactMap { index -> NSRect? in
                        guard let cell = (textStorage.attribute(.paragraphStyle, at: index, effectiveRange: nil)
                            as? NSParagraphStyle)?.textBlocks.last else { return nil }
                        let paragraph = layoutManager.glyphRange(forCharacterRange: text.paragraphRange(for: NSRange(location: index, length: 0)),
                                                                 actualCharacterRange: nil)
                        return layoutManager.boundsRect(for: cell, glyphRange: paragraph)
                    }
                    guard let first = cells.first, let last = cells.last else { continue }
                    let path = NSBezierPath(roundedRect: first.union(last).insetBy(dx: 0.5, dy: 0.5),
                                            xRadius: ConversationMetrics.blockRadius, yRadius: ConversationMetrics.blockRadius)
                    WovenColors.primary.withAlphaComponent(0.032).setFill()
                    path.fill()
                    WovenColors.foreground.withAlphaComponent(0.09).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        // A transcript following the live edge scrolls each new chunk under
        // the held pointer, so a selection would run on to the newest text.
        onPressWhileGrowing?()
        super.mouseDown(with: event)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, ConversationMarkdownDocument.isLiveLink(url) { onOpenLink?(url) }
        // Always consume the click; opening still requires the existing confirmation.
        return true
    }
}


private extension NSAttributedString.Key {
    static let responseCode = Self("WovenMatterResponseCode")
    static let responseQuote = Self("WovenMatterResponseQuote")
    static let responseDivider = Self("WovenMatterResponseDivider")
    static let responseTable = Self("WovenMatterResponseTable")
    static let responseScaledFont = Self("WovenMatterResponseScaledFont")
}

/// Where a box or bar is drawn: from the indent of the block that owns it.
/// Each block gets its own, so adjacent blocks never merge into one.
private final class ResponseBlockDecoration: NSObject {
    let indent: CGFloat
    init(indent: CGFloat) { self.indent = indent }
}

/// Reuses the prepared Markdown parser; only the response's presentation changes.
@MainActor
private enum ConversationResponseAttributedText {
    typealias Block = ConversationMarkdownDocument.Block
    typealias Prose = ConversationMetrics.Prose

    private struct Marker {
        let text: NSAttributedString
        /// Where the item's first line starts; the marker ends at `end`.
        let start: CGFloat
        let end: CGFloat
    }

    static func render(_ document: ConversationMarkdownDocument, style: ConversationResponse.Style) -> NSAttributedString {
        render(document.blocks, after: nil, endsResponse: true, style: style)
    }

    /// `values` rendered on their own, after `previous` (nil at the start of
    /// the response). Every gap is spacing above a block's first line, chosen
    /// from that block and the one before it, never from the one after: a
    /// streaming reply renders what follows its stable cut again with each
    /// chunk, after the last block before the cut, so pieces rendered apart
    /// join exactly as the whole renders. Blocks that do not end the response
    /// keep their last line break.
    static func render(_ values: [Block], after previous: Block?, endsResponse: Bool,
                       style responseStyle: ConversationResponse.Style) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        // Streaming is conveyed by work activity; answer ink stays stable as
        // paragraphs arrive and the run settles.
        let foreground = WovenColors.foreground.withAlphaComponent(responseStyle.inkOpacity)
        func font(_ size: CGFloat, _ weight: ResponseFont.Weight = .regular) -> ResponseFont {
            .systemFont(ofSize: size * responseStyle.scale, weight: weight)
        }
        func monospaced(_ size: CGFloat) -> ResponseFont {
            .monospacedSystemFont(ofSize: size * responseStyle.scale, weight: .regular)
        }
        let body = font(15)

        func paragraphStyle(indent: CGFloat, before: CGFloat, lineSpacing: CGFloat = Prose.lineSpacing) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.paragraphSpacingBefore = before
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            return style
        }

        func inline(_ text: ConversationMarkdownDocument.InlineText, font: ResponseFont) -> NSMutableAttributedString {
            let result = NSMutableAttributedString(string: "")
            for run in text.rendered.runs {
                let intent = run.inlinePresentationIntent ?? []
                var runFont = intent.contains(.code) ? monospaced(13.5) : font
                if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: foreground]
                if intent.contains(.code) { attributes[.backgroundColor] = WovenColors.primary.withAlphaComponent(0.075) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link, ConversationMarkdownDocument.isLiveLink(link) { attributes[.link] = link }
                result.append(NSAttributedString(string: String(text.rendered[run.range].characters), attributes: attributes))
            }
            return result
        }

        /// Each source line is its own paragraph. The first takes `style`;
        /// the lines after it continue the block, at its content indent with
        /// no gap above, so they space like wrapped lines.
        func append(_ text: NSAttributedString, style: NSParagraphStyle) {
            let paragraph = NSMutableAttributedString(attributedString: text)
            let lineFont: Any = text.length > 0 ? text.attribute(.font, at: text.length - 1, effectiveRange: nil) ?? body : body
            paragraph.append(NSAttributedString(string: "\n", attributes: [.font: lineFont, .foregroundColor: foreground]))
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            let first = (paragraph.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            if first.length < paragraph.length {
                let continuation = style.mutableCopy() as! NSMutableParagraphStyle
                continuation.firstLineHeadIndent = style.headIndent
                continuation.paragraphSpacingBefore = 0
                continuation.tabStops = []
                paragraph.addAttribute(.paragraphStyle, value: continuation,
                    range: NSRange(location: first.length, length: paragraph.length - first.length))
            }
            output.append(paragraph)
        }

        func appendInline(_ content: ConversationMarkdownDocument.InlineText, font: ResponseFont,
                          style: NSMutableParagraphStyle, marker: Marker?) {
            let text = NSMutableAttributedString(string: "")
            if let marker {
                // A right-aligned marker column, so "9." and "10." end together.
                style.firstLineHeadIndent = marker.start
                style.tabStops = [NSTextTab(textAlignment: .right, location: marker.end),
                                  NSTextTab(textAlignment: .left, location: style.headIndent)]
                text.append(NSAttributedString(string: "\t", attributes: [.font: font]))
                text.append(marker.text)
                text.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            }
            text.append(inline(content, font: font))
            append(text, style: style)
        }

        func decorate(_ key: NSAttributedString.Key, from start: Int, indent: CGFloat) {
            guard output.length > start else { return }
            output.addAttribute(key, value: ResponseBlockDecoration(indent: indent),
                                range: NSRange(location: start, length: output.length - start))
        }

        /// `values` in order. The first block's gap is `firstBefore` when a
        /// container chose it; every other block's comes from its predecessor.
        func sequence(_ values: [Block], indent: CGFloat, after previous: Block?, firstBefore: CGFloat?,
                      inItem: Bool, marker: Marker? = nil) {
            var previous = previous
            for (index, block) in values.enumerated() {
                let before = index == 0 ? firstBefore ?? spacing(after: previous, before: block, inItem: inItem)
                    : spacing(after: previous, before: block, inItem: inItem)
                emit(block, indent: indent, before: before, inItem: inItem, marker: index == 0 ? marker : nil)
                previous = block
            }
        }

        func emit(_ block: Block, indent: CGFloat, before: CGFloat, inItem: Bool, marker: Marker?) {
            switch block {
            case .paragraph(let content):
                appendInline(content, font: body, style: paragraphStyle(indent: indent, before: before), marker: marker)
            case .heading(let level, let content):
                let size: CGFloat = switch level { case 1: 22; case 2: 19; case 3: 17; default: 15.5 }
                appendInline(content, font: font(size, .semibold), style: paragraphStyle(indent: indent, before: before),
                             marker: marker)
            case .list(let items):
                let gap = items.contains { $0.blocks.count > 1 } ? Prose.looseListGap : Prose.tightListGap
                // Nesting steps by level, however many spaces the source used.
                let depths = Set(items.map(\.depth)).sorted()
                var previousItem: Block?
                for (index, item) in items.enumerated() {
                    let level = CGFloat(min(depths.firstIndex(of: item.depth) ?? 0, 6))
                    let markerEnd = indent + Prose.markerColumn + level * Prose.nestedListStep
                    let text: NSAttributedString = if let checked = item.checked {
                        NSAttributedString(string: checked ? "☑" : "☐", attributes: [
                            .font: font(13), .foregroundColor: checked ? WovenColors.primary : WovenColors.mutedForeground])
                    } else {
                        NSAttributedString(string: item.marker, attributes: [.font: body, .foregroundColor: foreground])
                    }
                    let first = index == 0 ? before
                        : max(0, gap + topOverhang(item.blocks.first) - bottomSlack(previousItem))
                    sequence(item.blocks, indent: markerEnd + Prose.markerGap, after: nil, firstBefore: first, inItem: true,
                             marker: Marker(text: text, start: markerEnd - Prose.markerColumn, end: markerEnd))
                    previousItem = item.blocks.last ?? previousItem
                }
            case .quote(let quoted):
                let start = output.length
                sequence(quoted, indent: indent + Prose.quoteBar + Prose.quoteGap, after: nil, firstBefore: before,
                         inItem: inItem)
                decorate(.responseQuote, from: start, indent: indent)
            case .code(let language, let content):
                let start = output.length
                let style = paragraphStyle(indent: indent + ConversationMetrics.blockInset, before: before,
                                           lineSpacing: Prose.codeLineSpacing)
                style.tailIndent = -ConversationMetrics.blockInset
                if let language, !language.isEmpty {
                    let labelStyle = style.mutableCopy() as! NSMutableParagraphStyle
                    labelStyle.lineSpacing = 0
                    append(NSAttributedString(string: language, attributes: [
                        .font: font(11.5), .foregroundColor: WovenColors.mutedForeground]), style: labelStyle)
                    style.paragraphSpacingBefore = Prose.codeLabelGap
                }
                append(NSAttributedString(string: content, attributes: [.font: monospaced(13), .foregroundColor: foreground]),
                       style: style)
                decorate(.responseCode, from: start, indent: indent)
            case .table(let table):
                guard !table.header.isEmpty else { return }
                let start = output.length
                let nativeTable = NSTextTable()
                nativeTable.numberOfColumns = table.header.count
                nativeTable.collapsesBorders = true
                nativeTable.setWidth(before, type: responseAbsolute, for: .margin, edge: .minY)
                nativeTable.setWidth(indent, type: responseAbsolute, for: .margin, edge: .minX)
                let rows = ([table.header] + table.rows).enumerated().map { rowIndex, cells in
                    table.header.indices.map { column in
                        inline(cells.indices.contains(column) ? cells[column] : .init(""),
                               font: font(13, rowIndex == 0 ? .semibold : .regular))
                    }
                }
                // Columns as wide as their content; a table too wide for the
                // text shrinks in proportion and wraps.
                let widths = table.header.indices.map { column in
                    min(Prose.tableColumnLimit, max(1, rows.map { ceil($0[column].size().width) + 1 }.max() ?? 1))
                }
                for (rowIndex, cells) in rows.enumerated() {
                    for (column, text) in cells.enumerated() {
                        let cell = NSTextTableBlock(table: nativeTable, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                        cell.setValue(widths[column], type: responseAbsolute, for: .width)
                        cell.setWidth(Prose.cellPaddingHorizontal, type: responseAbsolute, for: .padding, edge: .minX)
                        cell.setWidth(Prose.cellPaddingHorizontal, type: responseAbsolute, for: .padding, edge: .maxX)
                        cell.setWidth(Prose.cellPaddingVertical, type: responseAbsolute, for: .padding, edge: .minY)
                        // A cell's last line keeps its line spacing below it.
                        cell.setWidth(Prose.cellPaddingVertical - Prose.cellLineSpacing, type: responseAbsolute,
                                      for: .padding, edge: .maxY)
                        if rowIndex < rows.count - 1 {
                            cell.setWidth(0.5, type: responseAbsolute, for: .border, edge: .maxY)
                        }
                        cell.setBorderColor(WovenColors.foreground.withAlphaComponent(0.09))
                        let cellStyle = paragraphStyle(indent: 0, before: 0, lineSpacing: Prose.cellLineSpacing)
                        cellStyle.textBlocks = [cell]
                        if table.alignments.indices.contains(column) {
                            cellStyle.alignment = switch table.alignments[column] { case .leading: .left; case .center: .center; case .trailing: .right }
                        }
                        append(text, style: cellStyle)
                    }
                }
                decorate(.responseTable, from: start, indent: indent)
            case .divider:
                let start = output.length
                let style = paragraphStyle(indent: indent, before: before, lineSpacing: 0)
                style.minimumLineHeight = 1
                style.maximumLineHeight = 1
                append(NSAttributedString(string: " ", attributes: [.font: body, .foregroundColor: foreground]), style: style)
                decorate(.responseDivider, from: start, indent: indent)
            }
        }

        // TextKit drops the spacing above the text's first paragraph; a box
        // that starts the text needs room above its first line.
        if previous == nil, topOverhang(values.first) > 0 {
            let lead = NSMutableParagraphStyle()
            lead.minimumLineHeight = 0.01
            lead.maximumLineHeight = 0.01
            output.append(NSAttributedString(string: "\n", attributes: [.font: ResponseFont.systemFont(ofSize: 1), .paragraphStyle: lead]))
        }
        sequence(values, indent: 0, after: previous, firstBefore: nil, inItem: false)
        guard endsResponse, output.length > 0 else { return output }
        // The last line break would add an empty line under the text. A box
        // keeps it, so its last line keeps the spacing its edge is drawn from.
        let end = output.length - 1
        let endsInBox = output.attribute(.responseCode, at: end, effectiveRange: nil) != nil
            || (output.attribute(.paragraphStyle, at: end, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == false
        if !endsInBox { output.deleteCharacters(in: NSRange(location: end, length: 1)) }
        return output
    }

    /// The spacing above `block`'s first line: the visible gap between the two
    /// blocks' edges, adjusted for where those edges sit around their lines.
    private static func spacing(after previous: Block?, before block: Block, inItem: Bool) -> CGFloat {
        max(0, gap(after: previous, before: block, inItem: inItem) + topOverhang(block) - bottomSlack(previous))
    }

    /// Visible space between two blocks: text to text, or to a box's edge.
    private static func gap(after previous: Block?, before block: Block, inItem: Bool) -> CGFloat {
        guard let previous else { return 0 }
        // A heading attaches to what follows it.
        if case .heading(let level, _) = previous { return level <= 2 ? Prose.majorHeadingAttach : Prose.minorHeadingAttach }
        if case .heading(let level, _) = block { return level <= 2 ? Prose.majorHeadingGap : Prose.minorHeadingGap }
        if isRule(previous) || isRule(block) { return Prose.ruleGap }
        if isBox(previous) || isBox(block) { return Prose.paragraphGap }
        if case .list = previous { return Prose.paragraphGap }
        if case .list = block { return Prose.looseListGap }
        return inItem ? Prose.looseListGap : Prose.paragraphGap
    }

    private static func isRule(_ block: Block) -> Bool {
        if case .divider = block { return true }
        return false
    }

    private static func isBox(_ block: Block) -> Bool {
        switch block {
        case .code, .table, .quote: true
        default: false
        }
    }

    /// How far a block's visible top sits above its first line.
    private static func topOverhang(_ block: Block?) -> CGFloat {
        switch block {
        case .code: Prose.codePadding
        case .quote(let quoted): topOverhang(quoted.first)
        case .list(let items): topOverhang(items.first?.blocks.first)
        default: 0
        }
    }

    /// How far a block's last line fragment runs past its visible bottom: its
    /// line spacing for text, less than nothing for a box drawn around it.
    private static func bottomSlack(_ block: Block?) -> CGFloat {
        switch block {
        case nil, .table, .divider: 0
        case .code: Prose.codeLineSpacing - Prose.codePadding
        case .quote(let quoted): quoted.last.map(bottomSlack) ?? 0
        case .list(let items): bottomSlack(items.last?.blocks.last)
        case .paragraph, .heading: Prose.lineSpacing
        }
    }
}

/// The same user-message bubble on desktop and mobile; callers supply their
/// platform's persisted attachment/reference chips inside the shared layout.
struct ConversationUserBubble<Attachments: View>: View {
    let content: String
    var hasAttachments = false
    @ViewBuilder var attachments: () -> Attachments
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .trailing, spacing: ConversationMetrics.rowGap) {
            if !content.isEmpty {
                Text(content)
                    .font(.system(size: 15))
                    .lineSpacing(ConversationMetrics.Prose.lineSpacing)
                    .lineLimit(isLong && !expanded ? 6 : nil)
                    .foregroundStyle(WovenPalette.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            attachments()
            if isLong {
                Button(expanded ? "Show less" : "Show full message") {
                    withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(WovenPalette.mutedForeground)
            }
        }
        .frame(maxWidth: preferredContentWidth, alignment: .trailing)
        .padding(ConversationMetrics.bubbleInsets)
        .background(WovenPalette.primary.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.composerRadius, style: .continuous))
    }
    private var isLong: Bool { content.count > 420 || content.filter { $0 == "\n" }.count > 5 }
    private var preferredContentWidth: CGFloat {
        if hasAttachments { return 420 }
        let font = ResponseFont.systemFont(ofSize: 15)
        let longestLine = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(586, max(isLong ? 118 : 1, ceil(longestLine)))
    }
}
