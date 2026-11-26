import AppKit
private typealias ResponseFont = NSFont
private let responseAbsolute = NSTextBlock.ValueType.absoluteValueType
import SwiftUI

/// One selectable text surface and one copy action for the complete response.
extension EnvironmentValues {
    /// When set, links in a response go here instead of asking to open them externally.
    @Entry var conversationLinkHandler: ((URL) -> Void)?
}

struct ConversationResponse: View {
    enum Style: Equatable {
        case reply
        /// Commentary in the work lane: the lane's size, a step below the reply's ink.
        case commentary
        /// Reasoning in the work lane: the lane's size, its quietest ink.
        case reasoning

        var scale: CGFloat { self == .reply ? 1 : 0.9 }
        var inkOpacity: CGFloat {
            switch self {
            case .reply: 1
            case .commentary: 0.88
            case .reasoning: 0.62
            }
        }
    }

    let content: String
    let isStreaming: Bool
    var showsCopyButton = true
    /// While the turn runs, its dots hold the row Copy takes once it ends.
    var showsRunningDots = false
    var style: Style = .reply
    /// The files the reply refers to, as chips after Copy once it settles.
    var fileRow: ConversationFileRow?
    @Environment(\.conversationLinkHandler) private var linkHandler
    @State private var copied = false
    @State private var pendingExternalURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConversationResponseText(content: content, isStreaming: isStreaming, style: style) { url in
                // Page links only work where a handler routes them (bot chats).
                if let linkHandler { linkHandler(url) } else if WovenAppLink(url) == nil { pendingExternalURL = url }
            }
            .frame(maxWidth: ConversationMetrics.column, alignment: .leading)

            if showsCopyButton {
                // One row, the same height while the reply streams and once it
                // settles, so nothing moves when the turn ends.
                // Files the reply refers to follow Copy in the same row, which
                // wraps; with none the row is just Copy.
                let files = isStreaming || showsRunningDots ? [] : fileRow.map { _ in ConversationFileRow.files(in: content) } ?? []
                ZStack(alignment: .leading) {
                    if showsRunningDots {
                        ConversationRunningDots()
                    } else if !isStreaming, let fileRow, !files.isEmpty {
                        FlowLayout(horizontalSpacing: ConversationMetrics.rowGap, verticalSpacing: ConversationMetrics.rowGap) {
                            copyButton.frame(height: WovenMetrics.rowHeight)
                            fileRow.chips(files)
                        }
                    } else if !isStreaming {
                        copyButton
                    }
                }
                .frame(minHeight: ConversationMetrics.actionRowHeight)
                .padding(.top, ConversationMetrics.tight)
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
                .font(.system(size: 13, weight: .medium))
                .frame(width: ConversationMetrics.actionRowHeight, height: ConversationMetrics.actionRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(WovenIconButtonStyle())
        // The glyph lines up with the text edge; its hover target hangs left of it.
        .padding(.leading, -(ConversationMetrics.actionRowHeight - 13) / 2)
        .help("Copy complete response")
        .accessibilityLabel(copied ? "Response copied" : "Copy response")
    }
}

private struct ConversationResponseText: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    let content: String
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
        textView.onSelect = transcriptInteraction
        if textView.apply(content: content, isStreaming: isStreaming, style: style, colorScheme: colorScheme) {
            viewport.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ConversationResponseViewport,
                      context: Context) -> CGSize? {
        nsView.textView.fittingSize(width: proposal.width ?? ConversationMetrics.column)
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
final class ConversationResponseNativeTextView: NSTextView, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
    // Bounds follow the viewport; text and selection retain document coordinates.
    override var textContainerOrigin: NSPoint { .zero }
    var onOpenLink: ((URL) -> Void)?
    /// Hands the transcript's scroll to the reader while the reply grows.
    var onPressWhileGrowing: (@MainActor () -> Void)?
    /// The reader selected text, by pointer or keyboard: the transcript keeps it in view.
    var onSelect: (@MainActor () -> Void)?
    private var applying = false
    private var appliedContent: String?
    private var appliedStreaming: Bool?
    private var appliedColorScheme: ColorScheme?
    private var appliedStyle: ConversationResponse.Style?
    private var measuredSize: CGSize?
    /// The width tables were sized for.
    private var layoutWidth = ConversationMetrics.column
    private var decorations: [(key: NSAttributedString.Key, range: NSRange, block: ResponseBlockDecoration?)] = []
    /// While streaming: the source's length in UTF-8 before the last stable
    /// cut, the length of its rendering at the start of the text storage, and
    /// its last block.
    private var stable: (source: Int, length: Int, last: ConversationMarkdownDocument.Block?)?

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: ConversationMetrics.column, height: CGFloat.greatestFiniteMagnitude))
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
        self.layoutManager?.delegate = self
        linkTextAttributes = [.foregroundColor: WovenColors.success, .underlineStyle: 0]
        setAccessibilityLabel("Agent response")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func apply(content: String, isStreaming: Bool,
               style: ConversationResponse.Style = .reply, colorScheme: ColorScheme = .light) -> Bool {
        guard appliedContent != content || appliedStreaming != isStreaming
            || appliedColorScheme != colorScheme || appliedStyle != style else { return false }
        appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let samePresentation = appliedColorScheme == colorScheme && appliedStyle == style
        appliedColorScheme = colorScheme
        appliedStyle = style
        // Selection changes from here on are the text changing, not the reader.
        applying = true
        defer { applying = false }
        let selection = selectedRange()
        let previous = selection.length > 0 ? NSString(string: string) : nil
        guard let textStorage else { return false }
        // While a reply streams, the blocks before its last stable cut are
        // already in the text storage: only what follows is parsed, rendered
        // and laid out again, so a chunk costs its own length, not the reply's.
        // The cut stays valid while the reply only grows past what was applied,
        // through the last chunk when it settles.
        var kept: (source: Int, length: Int, last: ConversationMarkdownDocument.Block?) = (0, 0, nil)
        var tail: NSAttributedString
        if let stable, samePresentation, let appliedContent,
           content.utf8.starts(with: appliedContent.utf8), stable.length <= textStorage.length {
            kept = stable
            tail = renderStreaming(content, keeping: kept, style: style)
            // Nothing after the kept part: its last line break, which the
            // whole reply would drop, must not stay.
            if tail.length == 0, kept.length > 0 {
                kept = (0, 0, nil)
                tail = renderStreaming(content, keeping: kept, style: style)
            }
        } else if isStreaming {
            tail = renderStreaming(content, keeping: kept, style: style)
        } else {
            stable = nil
            tail = ConversationResponseAttributedText.render(ConversationMarkdownDocument(content).blocks, after: nil,
                                                             endsResponse: true, style: style, width: layoutWidth)
        }
        textStorage.replaceCharacters(in: NSRange(location: kept.length, length: textStorage.length - kept.length), with: tail)
        measuredSize = nil
        decorations.removeAll { $0.range.location >= kept.length }
        // Inline code last: it draws over code boxes and table fills.
        let whole = NSRange(location: 0, length: tail.length)
        for key in [NSAttributedString.Key.responseCode, .responseDivider, .responseTable] {
            tail.enumerateAttribute(key, in: whole) { value, range, _ in
                if let block = value as? ResponseBlockDecoration {
                    decorations.append((key, NSRange(location: range.location + kept.length, length: range.length), block))
                }
            }
        }
        // Nested quotes overlap: each keeps its own range and bar.
        var quotes: [(block: ResponseBlockDecoration, range: NSRange)] = []
        tail.enumerateAttribute(.responseQuote, in: whole) { value, range, _ in
            for block in value as? [ResponseBlockDecoration] ?? [] {
                if let index = quotes.firstIndex(where: { $0.block === block }) {
                    quotes[index].range = NSUnionRange(quotes[index].range, range)
                } else {
                    quotes.append((block, range))
                }
            }
        }
        for quote in quotes {
            decorations.append((.responseQuote, NSRange(location: quote.range.location + kept.length, length: quote.range.length), quote.block))
        }
        for key in [NSAttributedString.Key.responseInlineCode, .responseTaskBox] {
            tail.enumerateAttribute(key, in: whole) { value, range, _ in
                if value != nil { decorations.append((key, NSRange(location: range.location + kept.length, length: range.length), nil)) }
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
        setSelectedRange(selectionUnchanged ? selection : NSRange(location: textRange.location, length: 0))
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
        let (blocks, cut) = ConversationMarkdownDocument.blocks(cutting: content[start...])
        func render(cutAt settledCount: Int) -> (settled: NSAttributedString, rest: NSAttributedString, last: ConversationMarkdownDocument.Block?) {
            let last = settledCount > 0 ? blocks[settledCount - 1] : kept.last
            return (ConversationResponseAttributedText.render(Array(blocks[..<settledCount]), after: kept.last,
                                                               endsResponse: false, style: style, width: layoutWidth),
                    ConversationResponseAttributedText.render(Array(blocks[settledCount...]), after: last,
                                                              endsResponse: true, style: style, width: layoutWidth), last)
        }
        var cutOffset = cut?.offset ?? 0
        var parts = render(cutAt: cut?.blockCount ?? 0)
        // A cut with nothing visible after it would keep the settled blocks'
        // last line break, which the whole reply drops: don't cut there yet.
        if parts.rest.length == 0, parts.settled.length > 0 {
            cutOffset = 0
            parts = render(cutAt: 0)
        }
        let tail = NSMutableAttributedString(attributedString: parts.settled)
        tail.append(parts.rest)
        stable = (kept.source + cutOffset, kept.length + parts.settled.length, parts.last)
        return tail
    }

    func fittingSize(width: CGFloat) -> CGSize {
        let width = max(1, width)
        guard let textContainer, let layoutManager else { return CGSize(width: width, height: 1) }
        if let measuredSize, measuredSize.width == width { return measuredSize }
        // Tables share out the width they are given: lay them out again for a new one.
        if width != layoutWidth {
            layoutWidth = width
            if decorations.contains(where: { $0.key == .responseTable }), let content = appliedContent,
               let isStreaming = appliedStreaming, let style = appliedStyle {
                stable = nil
                appliedContent = nil
                apply(content: content, isStreaming: isStreaming, style: style, colorScheme: appliedColorScheme ?? .light)
            }
        }
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
                if decoration.key == .responseInlineCode {
                    drawInlineCode(decoration.range, within: visibleGlyphs, layoutManager: layoutManager,
                                   textContainer: textContainer, text: textStorage)
                    continue
                }
                if decoration.key == .responseTaskBox {
                    drawTaskBox(decoration.range, layoutManager: layoutManager, textContainer: textContainer, text: textStorage)
                    continue
                }
                guard let block = decoration.block else { continue }
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
                    let endStyle = textStorage.attribute(.paragraphStyle, at: end, effectiveRange: nil) as? NSParagraphStyle
                    let bottom: CGFloat
                    if let cell = endStyle?.textBlocks.last {
                        // A quoted table ends at its last row, whichever cell is tallest.
                        let paragraph = layoutManager.glyphRange(forCharacterRange: text.paragraphRange(for: NSRange(location: end, length: 0)),
                                                                 actualCharacterRange: nil)
                        bottom = layoutManager.boundsRect(for: cell, glyphRange: paragraph).maxY
                    } else {
                        bottom = lastLine.maxY - (text.character(at: end) == 0x0A ? endStyle?.lineSpacing ?? 0 : 0)
                    }
                    // The full height of the quote's lines, a little past their text.
                    WovenColors.foreground.withAlphaComponent(0.24).setFill()
                    NSRect(x: block.indent, y: top - ConversationMetrics.hair, width: Prose.quoteBar,
                           height: bottom - top + 2 * ConversationMetrics.hair).fill()
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

    /// Inline code's background, one rounded box per line around its glyphs:
    /// never the indent before a wrapped line or the space after it.
    /// Only the lines in `visible` are walked, however long the span.
    private func drawInlineCode(_ range: NSRange, within visible: NSRange, layoutManager: NSLayoutManager,
                                textContainer: NSTextContainer, text: NSTextStorage) {
        let characters = text.string as NSString
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let shown = NSIntersectionRange(glyphs, visible)
        guard shown.length > 0 else { return }
        var index = shown.location
        let end = NSMaxRange(shown)
        WovenColors.primary.withAlphaComponent(0.075).setFill()
        while index < end {
            var line = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &line)
            index = NSMaxRange(line)
            var piece = layoutManager.characterRange(forGlyphRange: NSIntersectionRange(line, glyphs), actualGlyphRange: nil)
            while piece.length > 0, let scalar = UnicodeScalar(characters.character(at: NSMaxRange(piece) - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) { piece.length -= 1 }
            guard piece.length > 0, let font = text.attribute(.font, at: piece.location, effectiveRange: nil) as? NSFont else { continue }
            let pieceGlyphs = layoutManager.glyphRange(forCharacterRange: piece, actualCharacterRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: pieceGlyphs, in: textContainer)
            let baseline = fragment.minY + layoutManager.location(forGlyphAt: pieceGlyphs.location).y
            // Around the code's own line box, so stacked lines never touch,
            // and never past the text's left edge, where it would be cut off.
            let minX = max(0, bounds.minX - ConversationMetrics.hair)
            let rect = NSRect(x: minX, y: baseline - font.ascender - 1,
                              width: bounds.maxX + ConversationMetrics.hair - minX, height: font.ascender - font.descender + 2)
            NSBezierPath(roundedRect: rect, xRadius: ConversationMetrics.tight, yRadius: ConversationMetrics.tight).fill()
        }
    }

    /// A task's box: one square for both states, ending where the marker
    /// column ends and centred on the text's x-height. Checked is filled
    /// with a check; unchecked is a hairline outline.
    private func drawTaskBox(_ range: NSRange, layoutManager: NSLayoutManager, textContainer: NSTextContainer,
                             text: NSTextStorage) {
        guard let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
        let checked = text.attribute(.responseTaskBox, at: range.location, effectiveRange: nil) as? Bool == true
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyphs.location).y
        let side = (font.pointSize * 0.87).rounded()
        let rect = NSRect(x: bounds.maxX - side, y: (baseline - font.xHeight / 2 - side / 2).rounded(), width: side, height: side)
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        if checked {
            WovenColors.primary.setFill()
            box.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: rect.minX + side * 0.26, y: rect.midY + side * 0.02))
            check.line(to: NSPoint(x: rect.minX + side * 0.43, y: rect.minY + side * 0.7))
            check.line(to: NSPoint(x: rect.minX + side * 0.76, y: rect.minY + side * 0.3))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            WovenColors.foreground.withAlphaComponent(0.4).setStroke()
            box.lineWidth = 1
            box.stroke()
        }
    }

    /// The text without the characters only layout needs.
    private var textRange: NSRange {
        guard let textStorage, textStorage.length > 0 else { return NSRange(location: 0, length: 0) }
        var range = NSRange(location: 0, length: textStorage.length)
        if textStorage.attribute(.responseLayoutOnly, at: 0, effectiveRange: nil) != nil { range.location = 1; range.length -= 1 }
        if range.length > 0, textStorage.attribute(.responseLayoutOnly, at: textStorage.length - 1, effectiveRange: nil) != nil {
            range.length -= 1
        }
        return range
    }

    override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        let range = super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        let text = textRange
        let start = min(max(range.location, text.location), NSMaxRange(text))
        return NSRange(location: start, length: max(0, min(NSMaxRange(range), NSMaxRange(text)) - start))
    }

    override func selectAll(_ sender: Any?) {
        setSelectedRange(textRange)
    }

    override func mouseDown(with event: NSEvent) {
        // A transcript following the live edge scrolls each new chunk under
        // the held pointer, so a selection would run on to the newest text.
        onPressWhileGrowing?()
        super.mouseDown(with: event)
    }

    /// Lines do not break inside text kept together.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        guard let textStorage, charIndex > 0, charIndex < textStorage.length else { return true }
        return textStorage.attribute(.responseNoBreak, at: charIndex, effectiveRange: nil) == nil
            || textStorage.attribute(.responseNoBreak, at: charIndex - 1, effectiveRange: nil) == nil
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByHyphenatingBeforeCharacterAt charIndex: Int) -> Bool {
        self.layoutManager(layoutManager, shouldBreakLineByWordBeforeCharacterAt: charIndex)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if !applying, selectedRange().length > 0 { onSelect?() }
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
    static let responseInlineCode = Self("WovenMatterResponseInlineCode")
    /// A task list item's box, drawn in place of its character: true when checked.
    static let responseTaskBox = Self("WovenMatterResponseTaskBox")
    /// Text a line does not break inside (short inline code in a table cell).
    static let responseNoBreak = Self("WovenMatterResponseNoBreak")
    /// Characters only layout needs: the spacer above a box that opens the
    /// text and the line break kept after one that ends it. Selection skips them.
    static let responseLayoutOnly = Self("WovenMatterResponseLayoutOnly")
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

    private enum MarkerKind { case bullet, number, task }

    private static let emptyParagraph = Block.paragraph(.init(""))

    /// `values` rendered on their own, after `previous` (nil at the start of
    /// the response). Every gap is spacing above a block's first line, chosen
    /// from that block and the one before it, never from the one after: a
    /// streaming reply renders what follows its stable cut again with each
    /// chunk, after the last block before the cut, so pieces rendered apart
    /// join exactly as the whole renders. Blocks that do not end the response
    /// keep their last line break.
    /// `width` is the text's width, which tables share out among their columns.
    static func render(_ values: [Block], after previous: Block?, endsResponse: Bool,
                       style responseStyle: ConversationResponse.Style, width: CGFloat) -> NSAttributedString {
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

        /// In a table cell, short inline code keeps together on one line.
        func inline(_ text: ConversationMarkdownDocument.InlineText, font: ResponseFont, inCell: Bool = false) -> NSMutableAttributedString {
            let result = NSMutableAttributedString(string: "")
            for run in text.rendered.runs {
                let intent = run.inlinePresentationIntent ?? []
                var runFont = intent.contains(.code) ? monospaced(13.5) : font
                if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: foreground]
                let string = String(text.rendered[run.range].characters)
                if intent.contains(.code) {
                    attributes[.responseInlineCode] = true
                    if inCell, string.count <= Prose.unbreakableCodeLength { attributes[.responseNoBreak] = true }
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link, ConversationMarkdownDocument.isLiveLink(link) { attributes[.link] = link }
                result.append(NSAttributedString(string: string, attributes: attributes))
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
                // A list item's marker stops belong to its first line only.
                if style.firstLineHeadIndent != style.headIndent { continuation.tabStops = NSParagraphStyle.default.tabStops }
                continuation.firstLineHeadIndent = style.headIndent
                continuation.paragraphSpacingBefore = 0
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
            let range = NSRange(location: start, length: output.length - start)
            let block = ResponseBlockDecoration(indent: indent)
            guard key == .responseQuote else { return output.addAttribute(key, value: block, range: range) }
            // A quote inside a quote keeps its own bar: each range lists every quote around it.
            output.enumerateAttribute(.responseQuote, in: range) { value, part, _ in
                output.addAttribute(.responseQuote, value: (value as? [ResponseBlockDecoration] ?? []) + [block], range: part)
            }
        }

        /// `values` in order. The first block's gap is `firstBefore` when a
        /// container chose it; every other block's comes from its predecessor.
        func sequence(_ values: [Block], indent: CGFloat, after previous: Block?, firstBefore: CGFloat?,
                      inItem: Bool, marker: Marker? = nil) {
            var previous = previous
            for (index, block) in values.enumerated() {
                let chosen = index == 0 ? firstBefore : nil
                emit(block, indent: indent, before: chosen ?? spacing(after: previous, before: block, inItem: inItem),
                     inItem: inItem, marker: index == 0 ? marker : nil)
                previous = block
            }
        }

        func emit(_ block: Block, indent: CGFloat, before: CGFloat, inItem: Bool, marker: Marker?) {
            var before = before
            // A block that cannot start with the marker gets a line of its own for it.
            if let marker, leadsWithMarkerLine(block) {
                appendInline(.init(""), font: body, style: paragraphStyle(indent: indent, before: before), marker: marker)
                before = spacing(after: emptyParagraph, before: block, inItem: true)
            }
            let marker = leadsWithMarkerLine(block) ? nil : marker
            switch block {
            case .paragraph(let content):
                appendInline(content, font: body, style: paragraphStyle(indent: indent, before: before), marker: marker)
            case .heading(let level, let content):
                let size: CGFloat = switch level { case 1: 22; case 2: 19; case 3: 17; default: 15.5 }
                appendInline(content, font: font(size, .semibold), style: paragraphStyle(indent: indent, before: before),
                             marker: marker)
            case .list(let items):
                let gap = items.contains { $0.blocks.count > 1 } ? Prose.looseListGap : Prose.tightListGap
                // Nesting steps by level, however many spaces the source used,
                // decided in source order so a later item never moves an earlier one.
                var indents: [Int] = []
                var previousItem: Block?
                var topKind: MarkerKind?
                for (index, item) in items.enumerated() {
                    while let last = indents.last, last > item.depth { indents.removeLast() }
                    if indents.last != item.depth { indents.append(item.depth) }
                    let level = CGFloat(min(indents.count - 1, 6))
                    let kind: MarkerKind = item.checked != nil ? .task : item.marker == "•" ? .bullet : .number
                    // A different kind of list straight after one reads as a list of its own.
                    let startsList = level == 0 && topKind != nil && topKind != kind
                    if level == 0 { topKind = kind }
                    let markerEnd = indent + Prose.markerColumn + level * Prose.nestedListStep
                    // A task's box is drawn over its character, which stays for copying.
                    let text: NSAttributedString = if let checked = item.checked {
                        NSAttributedString(string: checked ? "☑" : "☐", attributes: [
                            .font: body, .foregroundColor: NSColor.clear, .responseTaskBox: checked])
                    } else {
                        NSAttributedString(string: item.marker, attributes: [.font: body, .foregroundColor: foreground])
                    }
                    let first = index == 0 ? before
                        : max(0, (startsList ? Prose.paragraphGap : gap) + itemTopOverhang(item) - bottomSlack(previousItem))
                    let itemMarker = Marker(text: text, start: markerEnd - Prose.markerColumn, end: markerEnd)
                    if item.blocks.isEmpty {
                        appendInline(.init(""), font: body,
                                     style: paragraphStyle(indent: markerEnd + Prose.markerGap, before: first), marker: itemMarker)
                    }
                    sequence(item.blocks, indent: markerEnd + Prose.markerGap, after: nil, firstBefore: first, inItem: true,
                             marker: itemMarker)
                    previousItem = item.blocks.last ?? emptyParagraph
                }
            case .quote(let quoted):
                let start = output.length
                sequence(quoted, indent: indent + Prose.quoteBar + Prose.quoteGap, after: nil, firstBefore: before,
                         inItem: inItem, marker: marker)
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
                // The gap above is an empty line of that height: a top margin
                // on the table also narrows the width TextKit lays it out in.
                if before > 0 {
                    let gap = paragraphStyle(indent: indent, before: 0, lineSpacing: 0)
                    gap.minimumLineHeight = before
                    gap.maximumLineHeight = before
                    append(NSAttributedString(string: "", attributes: [.font: body]), style: gap)
                }
                let start = output.length
                let nativeTable = NSTextTable()
                nativeTable.numberOfColumns = table.header.count
                nativeTable.collapsesBorders = true
                nativeTable.setWidth(indent, type: responseAbsolute, for: .margin, edge: .minX)
                func cellTexts(keepingCode: Bool) -> [[NSMutableAttributedString]] {
                    ([table.header] + table.rows).enumerated().map { rowIndex, cells in
                        table.header.indices.map { column in
                            inline(cells.indices.contains(column) ? cells[column] : .init(""),
                                   font: font(13, rowIndex == 0 ? .semibold : .regular), inCell: keepingCode)
                        }
                    }
                }
                // The usual automatic table layout: each column is at least
                // its longest unbreakable run (up to a limit) and at most its
                // width on one line. If every column fits on one line, it
                // gets that; otherwise each gets its least, and the room left
                // is shared in proportion to how much more each would take.
                func limits(_ rows: [[NSMutableAttributedString]]) -> (most: [CGFloat], least: [CGFloat]) {
                    let most = table.header.indices.map { column in
                        max(1, rows.map { ceil($0[column].size().width) + 1 }.max() ?? 1)
                    }
                    let least = table.header.indices.map { column in
                        min(most[column], Prose.tableColumnMinimumLimit, rows.map { unbreakableWidth($0[column]) }.max() ?? 1)
                    }
                    return (most, least)
                }
                let available = width - indent - CGFloat(table.header.count) * 2 * Prose.cellPaddingHorizontal
                var rows = cellTexts(keepingCode: true)
                var (most, least) = limits(rows)
                // Too narrow for short code to keep together: let it break at
                // its spaces like the words around it, rather than mid-word.
                if least.reduce(0, +) > available {
                    rows = cellTexts(keepingCode: false)
                    (most, least) = limits(rows)
                }
                let widths: [CGFloat]
                if most.reduce(0, +) <= available {
                    widths = most
                } else {
                    let room = max(0, available - least.reduce(0, +))
                    let stretch = zip(most, least).map { $0 - $1 }
                    let total = stretch.reduce(0, +)
                    widths = least.indices.map { least[$0] + (total > 0 ? room * stretch[$0] / total : 0) }
                }
                // These widths, as computed: TextKit's own automatic layout
                // would weigh them against the cells' content again.
                nativeTable.layoutAlgorithm = .fixedLayoutAlgorithm
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
            output.append(NSAttributedString(string: "\n", attributes: [.font: ResponseFont.systemFont(ofSize: 1), .paragraphStyle: lead,
                                                                        .responseLayoutOnly: true]))
        }
        sequence(values, indent: 0, after: previous, firstBefore: nil, inItem: false)
        guard endsResponse, output.length > 0 else { return output }
        // The last line break would add an empty line under the text. A box
        // keeps it, so its last line keeps the spacing its edge is drawn from.
        let end = output.length - 1
        let endsInBox = output.attribute(.responseCode, at: end, effectiveRange: nil) != nil
            || (output.attribute(.paragraphStyle, at: end, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == false
        if endsInBox {
            output.addAttribute(.responseLayoutOnly, value: true, range: NSRange(location: end, length: 1))
        } else {
            output.deleteCharacters(in: NSRange(location: end, length: 1))
        }
        return output
    }

    /// The widest run in `text` a line cannot break inside: a word, or a short
    /// inline code span kept together.
    private static func unbreakableWidth(_ text: NSAttributedString) -> CGFloat {
        let string = text.string as NSString
        var widest: CGFloat = 1
        var start = 0
        for index in 0...string.length {
            let breaks = index == string.length || (
                CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: index)) ?? " ")
                && text.attribute(.responseNoBreak, at: index, effectiveRange: nil) == nil)
            guard breaks else { continue }
            if index > start {
                widest = max(widest, ceil(text.attributedSubstring(from: NSRange(location: start, length: index - start)).size().width) + 1)
            }
            start = index + 1
        }
        return widest
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
        // Two lists in a row are two lists, spaced as paragraphs.
        if case .list = previous { return Prose.paragraphGap }
        if case .list = block { return Prose.looseListGap }
        return inItem ? Prose.looseListGap : Prose.paragraphGap
    }

    /// Whether a list item's marker needs a line of its own before this block.
    private static func leadsWithMarkerLine(_ block: Block) -> Bool {
        switch block {
        case .paragraph, .heading: false
        case .quote(let quoted): quoted.first.map(leadsWithMarkerLine) ?? true
        default: true
        }
    }

    /// An item's top overhang: none when its marker has a line of its own.
    private static func itemTopOverhang(_ item: ConversationMarkdownDocument.ListItem) -> CGFloat {
        guard let first = item.blocks.first, !leadsWithMarkerLine(first) else { return 0 }
        return topOverhang(first)
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
        case .list(let items): items.first.map(itemTopOverhang) ?? 0
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
        case .list(let items): items.last.map { bottomSlack($0.blocks.last ?? emptyParagraph) } ?? 0
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
