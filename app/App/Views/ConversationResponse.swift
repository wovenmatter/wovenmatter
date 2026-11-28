import AppKit
private typealias ResponseFont = NSFont
private let responseAbsolute = NSTextBlock.ValueType.absoluteValueType
import SwiftUI
import WovenProtocol

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
        /// Reasoning as plain lines, for the live thought's three-line window:
        /// no boxes, bars, tables or rules, no gaps between blocks, every line
        /// box `plainLinePitch` tall, its last line's too.
        case plainReasoning

        /// The plain style's one line pitch. N lines are N pitches tall, so a
        /// window N pitches tall at the text's end shows N whole lines.
        @MainActor static let plainLinePitch: CGFloat =
            ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 15 * Style.plainReasoning.scale)))
            + ConversationMetrics.Prose.lineSpacing

        var scale: CGFloat { self == .reply ? 1 : 0.9 }
        var inkOpacity: CGFloat {
            switch self {
            case .reply: 1
            case .commentary: 0.88
            case .reasoning, .plainReasoning: 0.62
            }
        }
    }

    let content: String
    let isStreaming: Bool
    /// The reply was cut off (its turn stopped or failed): its unfinished
    /// last line shows as what it was becoming, never as raw Markdown.
    var isCut = false
    var showsCopyButton = true
    /// While the turn runs, its dots hold the row Copy takes once it ends.
    var showsRunningDots = false
    var style: Style = .reply
    /// The files the reply refers to, as chips after Copy once it settles.
    var fileRow: ConversationFileRow?
    /// Drawn right after the text's last line, centred on it (a disclosure chevron).
    var trailingAccessory: AnyView?
    /// The accessory's width, which decides whether it fits after the last line.
    var trailingAccessoryWidth: CGFloat = 10
    @Environment(\.conversationLinkHandler) private var linkHandler
    @State private var copied = false
    @Environment(\.conversationCopyLead) private var copyLead
    @State private var pendingExternalURL: URL?
    /// The last file a link in the text asked to open.
    @State private var fileOpenRequest: ConversationFileOpenRequest?
    /// The text as placed, measured once at its placed width, for the accessory.
    @State private var placed: ConversationPlacedText?

    var body: some View {
        // Reasoning shows without the provider's own metadata lines; a cut
        // reply without its unfinished table start or open inline markup.
        let shown = style == .reasoning || style == .plainReasoning ? ConversationResponseAttributedText.withoutProviderMarkup(content)
            : isCut ? ConversationMarkdownDocument.finishingCutText(content) : content
        let accessory = trailingAccessory.flatMap { _ in placed.map(accessoryPlacement) }
        // The files the reply refers to, as chips under it once it settles; a
        // link in the text to one of them opens it as its chip does.
        let files = !showsCopyButton || isStreaming || showsRunningDots ? []
            : fileRow.map { _ in ConversationFileRow.files(in: content) } ?? []
        VStack(alignment: .leading, spacing: 0) {
            ConversationResponseText(content: shown, isStreaming: isStreaming, style: style,
                                     onPlaced: trailingAccessory == nil ? nil : { placed = $0 },
                                     openableFiles: Set(files.compactMap { LibraryFileReference.path($0.source) }),
                                     onOpenFile: { fileOpenRequest = ConversationFileOpenRequest(path: $0) }) { url in
                // Page links only work where a handler routes them (bot chats).
                if let linkHandler { linkHandler(url) } else if WovenAppLink(url) == nil { pendingExternalURL = url }
            }
            .frame(maxWidth: ConversationMetrics.column, alignment: .leading)
            // An accessory on a line of its own below the text gets room for
            // it. The room comes from the same measurement as the placement,
            // and neither changes the width the text is laid out at.
            .padding(.bottom, accessory.flatMap { accessory in placed.map { max(0, accessory.maxY - $0.height) } } ?? 0)
            .overlay(alignment: .topLeading) {
                if let trailingAccessory, let accessory {
                    trailingAccessory
                        .frame(width: accessory.width, height: accessory.height, alignment: .center)
                        .offset(x: accessory.minX, y: accessory.minY)
                }
            }

            if showsCopyButton {
                // One row, the same height while the reply streams and once it
                // settles, so nothing moves when the turn ends.
                // Files the reply refers to follow Copy in the same row, which
                // wraps, an entry gap under the text; with none the row is just
                // Copy, close under it. The text above never moves for them.
                ZStack(alignment: .leading) {
                    if showsRunningDots {
                        ConversationRunningDots()
                    } else if !isStreaming, let fileRow, !files.isEmpty {
                        FlowLayout(horizontalSpacing: ConversationMetrics.rowGap, verticalSpacing: ConversationMetrics.rowGap) {
                            copyButton.frame(height: ConversationMetrics.actionRowHeight)
                            fileRow.chips(files, opening: fileOpenRequest)
                        }
                    } else if !isStreaming {
                        copyButton
                    }
                }
                // One height in every state: the dots, Copy alone, and Copy with
                // the files' first line (the chips are as tall as the row).
                .frame(minHeight: ConversationMetrics.actionRowHeight)
                // Copy's hover box reaches past the row; it stays a label gap
                // clear of the text (more with files).
                .padding(.top, files.isEmpty
                    ? ConversationMetrics.labelGap + (PanelControlButton.size - ConversationMetrics.actionRowHeight) / 2
                    : ConversationMetrics.entryGap)
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

    /// The trailing accessory's frame in the text: right after the last line
    /// when it fits there, else at the start of the next line, or of the
    /// first when the text shows none, so it always exists inside the column.
    /// All of it comes from one measurement at the placed width.
    private func accessoryPlacement(_ placed: ConversationPlacedText) -> CGRect {
        let gap = ConversationMetrics.labelGap
        let width = trailingAccessoryWidth
        if let lastLine = placed.lastLine, lastLine.maxX + gap + width <= placed.width {
            return CGRect(x: lastLine.maxX + gap, y: lastLine.minY, width: width, height: lastLine.height)
        }
        let height = placed.lastLine?.height ?? ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 15 * style.scale)))
        let top = placed.lastLine.map { $0.maxY + ConversationMetrics.Prose.lineSpacing } ?? 0
        return CGRect(x: 0, y: top, width: width, height: height)
    }

    private var copyButton: some View {
        Button {
            // The whole answer: anything shown above the text (a visual reply) first.
            let press = ConversationVisualReplyText.press()
            Task { @MainActor in
                let lead = await copyLead?()
                // A Copy pressed later on another answer that has already written wins.
                guard ConversationVisualReplyText.claim(press) else { return }
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(lead.map { $0 + "\n\n" + content } ?? content, forType: .string)
            }
        } label: {
            // A step above the muted text, so the glyph's thin strokes read as a control.
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WovenPalette.foreground.opacity(0.72))
                // The hover box of the other icon buttons (the panel buttons).
                .frame(width: PanelControlButton.size, height: PanelControlButton.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(WovenIconButtonStyle())
        // It takes the action row's height in the layout, its hover box
        // reaching past it, and its glyph lines up with the text edge.
        .padding(.vertical, -(PanelControlButton.size - ConversationMetrics.actionRowHeight) / 2)
        .padding(.leading, -(PanelControlButton.size - 13) / 2)
        .help("Copy complete response")
        .accessibilityLabel(copied ? "Response copied" : "Copy response")
    }
}

/// A response's text as placed: its width and height, and its last line
/// (nil when it shows none), all from one layout at that width.
struct ConversationPlacedText: Equatable {
    let width: CGFloat
    let height: CGFloat
    let lastLine: CGRect?
}

private struct ConversationResponseText: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    let content: String
    let isStreaming: Bool
    let style: ConversationResponse.Style
    /// Told how the text is placed, once laid out at its placed width.
    var onPlaced: ((ConversationPlacedText) -> Void)?
    /// The paths of the files with chips under the reply, and what opening one does.
    var openableFiles: Set<String> = []
    var onOpenFile: ((String) -> Void)?
    let onOpenLink: (URL) -> Void

    func makeNSView(context: Context) -> ConversationResponseViewport {
        ConversationResponseViewport()
    }

    func updateNSView(_ viewport: ConversationResponseViewport, context: Context) {
        viewport.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let textView = viewport.textView
        textView.onOpenLink = onOpenLink
        textView.onOpenFile = onOpenFile
        textView.onPressWhileGrowing = isStreaming ? transcriptInteraction : nil
        textView.onSelect = transcriptInteraction
        viewport.onPlaced = onPlaced
        if textView.apply(content: content, isStreaming: isStreaming, style: style, colorScheme: colorScheme) {
            viewport.invalidateIntrinsicContentSize()
            viewport.placeText()
        }
        // After the text, so its links to files follow the chips as they are now.
        textView.openableFiles = openableFiles
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

    /// Told how the text is placed (its width, height and last line), once
    /// per change, measured at the width it is placed at: never at a width
    /// SwiftUI only asked about.
    var onPlaced: ((ConversationPlacedText) -> Void)?
    private var reported: ConversationPlacedText?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateVisibleFrame()
        placeText()
    }

    /// Lays the text out for the width it is placed at, and reports it.
    func placeText() {
        guard bounds.width > 0 else { return }
        textView.place(width: bounds.width)
        guard let onPlaced else { return }
        let size = textView.fittingSize(width: bounds.width)
        let placed = ConversationPlacedText(width: bounds.width, height: size.height, lastLine: textView.lastLineRect)
        if placed == reported { return }
        reported = placed
        DispatchQueue.main.async { onPlaced(placed) }
    }

    override func layout() {
        super.layout()
        placeText()
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
final class ConversationResponseNativeTextView: NSTextView, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate,
    @preconcurrency NSTextStorageDelegate {
    // Bounds follow the viewport; text and selection retain document coordinates.
    override var textContainerOrigin: NSPoint { .zero }
    var onOpenLink: ((URL) -> Void)?
    /// The paths of the files the reply's row has chips for: a link to one
    /// of them is a link, and opening it is `onOpenFile`, what its chip does.
    var openableFiles: Set<String> = [] {
        didSet {
            if openableFiles != oldValue, let textStorage {
                linkFiles(in: NSRange(location: 0, length: textStorage.length), of: textStorage)
            }
        }
    }
    var onOpenFile: ((String) -> Void)?
    /// Hands the transcript's scroll to the reader while the reply grows.
    var onPressWhileGrowing: (@MainActor () -> Void)?
    /// The reader selected text, by pointer or keyboard: the transcript keeps it in view.
    var onSelect: (@MainActor () -> Void)?
    private var applying = false
    private var appliedContent: String?
    private var appliedStreaming: Bool?
    private var appliedColorScheme: ColorScheme?
    private var appliedStyle: ConversationResponse.Style?
    /// Sizes measured for the current text, by width: the placed width's on
    /// the displayed text, any other width's on a detached copy.
    private var measuredSizes: [(width: CGFloat, size: CGSize)] = []
    /// The width the displayed text is laid out for: the width it is placed
    /// at. Only placement changes it; measuring another width never does.
    private var layoutWidth = ConversationMetrics.column
    private var decorations: [(key: NSAttributedString.Key, range: NSRange, block: ResponseBlockDecoration?)] = []
    /// The reply's blocks, in order, each with the length of its rendering in
    /// the text storage: a new width renders again only the blocks that
    /// follow it, without parsing anything.
    private var pieces: [(block: ConversationMarkdownDocument.Block, length: Int)] = []
    /// While streaming: the source's length in UTF-8 before the last stable
    /// cut, the length of its rendering at the start of the text storage, its
    /// last block, and how many of `pieces` it holds.
    private var stable: Stable?
    private typealias Stable = (source: Int, length: Int, last: ConversationMarkdownDocument.Block?, pieces: Int)

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: ConversationMetrics.column, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        storage.delegate = self
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
        var kept: Stable = (0, 0, nil, 0)
        var tail: (text: NSAttributedString, pieces: [(block: ConversationMarkdownDocument.Block, length: Int)])
        if let stable, samePresentation, let appliedContent,
           content.utf8.starts(with: appliedContent.utf8), stable.length <= textStorage.length, stable.pieces <= pieces.count {
            kept = stable
            tail = renderStreaming(content, keeping: kept, style: style)
            // Nothing after the kept part: its last line break, which the
            // whole reply would drop, must not stay.
            if tail.text.length == 0, kept.length > 0 {
                kept = (0, 0, nil, 0)
                tail = renderStreaming(content, keeping: kept, style: style)
            }
        } else if isStreaming {
            tail = renderStreaming(content, keeping: kept, style: style)
        } else {
            stable = nil
            let blocks = ConversationMarkdownDocument(content).blocks
            let rendered = ConversationResponseAttributedText.renderPieces(blocks, after: nil, endsResponse: true,
                                                                           style: style, width: layoutWidth)
            tail = (rendered.text, Array(zip(blocks, rendered.lengths)).map { (block: $0.0, length: $0.1) })
        }
        textStorage.replaceCharacters(in: NSRange(location: kept.length, length: textStorage.length - kept.length), with: tail.text)
        pieces.removeSubrange(kept.pieces...)
        pieces += tail.pieces
        measuredSizes.removeAll()
        decorations.removeAll { $0.range.location >= kept.length }
        collectDecorations(in: tail.text, at: kept.length)
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
    private func renderStreaming(_ content: String, keeping kept: Stable, style: ConversationResponse.Style)
        -> (text: NSAttributedString, pieces: [(block: ConversationMarkdownDocument.Block, length: Int)]) {
        let start = content.utf8.index(content.startIndex, offsetBy: kept.source)
        let (blocks, cut) = ConversationMarkdownDocument.blocks(cutting: content[start...])
        typealias Rendered = (text: NSAttributedString, lengths: [Int])
        func render(cutAt settledCount: Int) -> (settled: Rendered, rest: Rendered, count: Int, last: ConversationMarkdownDocument.Block?) {
            let last = settledCount > 0 ? blocks[settledCount - 1] : kept.last
            return (ConversationResponseAttributedText.renderPieces(Array(blocks[..<settledCount]), after: kept.last,
                                                                     endsResponse: false, style: style, width: layoutWidth),
                    ConversationResponseAttributedText.renderPieces(Array(blocks[settledCount...]), after: last,
                                                                    endsResponse: true, style: style, width: layoutWidth),
                    settledCount, last)
        }
        var cutOffset = cut?.offset ?? 0
        var parts = render(cutAt: cut?.blockCount ?? 0)
        // A cut with nothing visible after it would keep the settled blocks'
        // last line break, which the whole reply drops: don't cut there yet.
        if parts.rest.text.length == 0, parts.settled.text.length > 0 {
            cutOffset = 0
            parts = render(cutAt: 0)
        }
        let tail = NSMutableAttributedString(attributedString: parts.settled.text)
        tail.append(parts.rest.text)
        stable = (kept.source + cutOffset, kept.length + parts.settled.text.length, parts.last, kept.pieces + parts.count)
        return (tail, Array(zip(blocks, parts.settled.lengths + parts.rest.lengths)).map { (block: $0.0, length: $0.1) })
    }

    /// The boxes, bars and shading `text` asks for, placed at `offset` in the
    /// text storage. Inline code last: it draws over code boxes and table fills.
    private func collectDecorations(in text: NSAttributedString, at offset: Int) {
        let whole = NSRange(location: 0, length: text.length)
        for key in [NSAttributedString.Key.responseCode, .responseDivider, .responseTable] {
            text.enumerateAttribute(key, in: whole) { value, range, _ in
                if let block = value as? ResponseBlockDecoration {
                    decorations.append((key, NSRange(location: range.location + offset, length: range.length), block))
                }
            }
        }
        // Nested quotes overlap: each keeps its own range and bar.
        var quotes: [(block: ResponseBlockDecoration, range: NSRange)] = []
        text.enumerateAttribute(.responseQuote, in: whole) { value, range, _ in
            for block in value as? [ResponseBlockDecoration] ?? [] {
                if let index = quotes.firstIndex(where: { $0.block === block }) {
                    quotes[index].range = NSUnionRange(quotes[index].range, range)
                } else {
                    quotes.append((block, range))
                }
            }
        }
        for quote in quotes {
            decorations.append((.responseQuote, NSRange(location: quote.range.location + offset, length: quote.range.length), quote.block))
        }
        for key in [NSAttributedString.Key.responseInlineCode, .responseTaskBox] {
            text.enumerateAttribute(key, in: whole) { value, range, _ in
                if value != nil { decorations.append((key, NSRange(location: range.location + offset, length: range.length), nil)) }
            }
        }
    }

    /// Lays the displayed blocks that follow the width out again for
    /// `layoutWidth`, each after the block before it, as the whole reply would
    /// render them there. Their text is the same at any width, so the
    /// selection stays.
    private func followWidth() {
        guard let textStorage, followsWidth(textStorage) else { return }
        applying = true
        defer { applying = false }
        let selection = selectedRange()
        let before = textStorage.string
        render(textStorage, at: layoutWidth, recordingPieces: true)
        if let kept = stable {
            stable?.length = pieces.prefix(kept.pieces).reduce(0) { $0 + $1.length }
        }
        decorations.removeAll()
        collectDecorations(in: textStorage, at: 0)
        if textStorage.string == before { setSelectedRange(selection) }
    }

    /// Whether `storage` holds the reply's blocks and some of them follow the width.
    private func followsWidth(_ storage: NSAttributedString) -> Bool {
        guard appliedStyle != nil, storage.length == pieces.reduce(0, { $0 + $1.length }) else { return false }
        return pieces.contains { $0.length > 0 && ConversationResponseAttributedText.followsWidth($0.block) }
    }

    /// Renders the blocks of `storage` that follow the width again at `width`.
    private func render(_ storage: NSTextStorage, at width: CGFloat, recordingPieces: Bool) {
        guard let style = appliedStyle else { return }
        let lastShown = pieces.lastIndex { $0.length > 0 }
        var location = 0
        storage.beginEditing()
        for index in pieces.indices {
            var length = pieces[index].length
            if length > 0, ConversationResponseAttributedText.followsWidth(pieces[index].block) {
                let text = ConversationResponseAttributedText.render([pieces[index].block], after: index > 0 ? pieces[index - 1].block : nil,
                                                                     endsResponse: index == lastShown, style: style, width: width)
                storage.replaceCharacters(in: NSRange(location: location, length: length), with: text)
                length = text.length
                if recordingPieces { pieces[index].length = length }
            }
            location += length
        }
        storage.endEditing()
    }

    /// The text's last line: where its glyphs end, and its height without the
    /// line spacing below it.
    var lastLineRect: CGRect? {
        guard let layoutManager, let textStorage, textStorage.length > 0 else { return nil }
        let string = textStorage.string as NSString
        var last = string.length - 1
        while last > 0, string.character(at: last) == 0x0A { last -= 1 }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: last, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let style = textStorage.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle
        return CGRect(x: used.minX, y: used.minY, width: used.width,
                      height: max(1, used.height - (last < string.length - 1 ? style?.lineSpacing ?? 0 : 0)))
    }

    /// The text's size at `width`. The placed width is measured on the
    /// displayed text; any other width SwiftUI asks about is measured on a
    /// detached copy, so asking never changes what is displayed, and the
    /// answer for a width is the same whatever was asked before.
    func fittingSize(width: CGFloat) -> CGSize {
        let width = max(1, width)
        if let known = measuredSizes.first(where: { $0.width == width }) { return known.size }
        let size: CGSize
        if width == layoutWidth, let textContainer, let layoutManager, let textStorage {
            if textContainer.size.width != width {
                textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
            }
            size = Self.measure(textStorage, layoutManager: layoutManager, container: textContainer, width: width)
        } else {
            size = detachedSize(width: width)
        }
        measuredSizes.append((width, size))
        if measuredSizes.count > 4 { measuredSizes.removeFirst() }
        return size
    }

    /// Lays the displayed text out for the width it is placed at.
    func place(width: CGFloat) {
        let width = max(1, width)
        guard let textContainer else { return }
        if width != layoutWidth {
            layoutWidth = width
            followWidth()
        }
        if textContainer.size.width != width {
            textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
    }

    /// The size at `width` of a copy of the text, rendered for that width.
    private func detachedSize(width: CGFloat) -> CGSize {
        guard let textStorage else { return CGSize(width: width, height: 1) }
        let storage = NSTextStorage(attributedString: textStorage)
        if width != layoutWidth, followsWidth(storage) { render(storage, at: width, recordingPieces: false) }
        let layoutManager = NSLayoutManager()
        layoutManager.delegate = self
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        return Self.measure(storage, layoutManager: layoutManager, container: container, width: width)
    }

    private static func measure(_ storage: NSTextStorage, layoutManager: NSLayoutManager, container: NSTextContainer,
                                width: CGFloat) -> CGSize {
        layoutManager.ensureLayout(for: container)
        var height = layoutManager.usedRect(for: container).maxY
        if storage.length > 0, (storage.string as NSString).character(at: storage.length - 1) == 0x0A {
            // Text ending in a box keeps its last line break: measure to the
            // box's edge, not to the empty line after it.
            height = layoutManager.extraLineFragmentRect.minY
            if storage.attribute(.responseCode, at: storage.length - 1, effectiveRange: nil) != nil {
                height += ConversationMetrics.Prose.codePadding - ConversationMetrics.Prose.codeLineSpacing
            }
        }
        return CGSize(width: width, height: max(1, ceil(height)))
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
                    drawWrapMarks(NSIntersectionRange(glyphs, visibleGlyphs), boxText: block.indent + ConversationMetrics.blockInset,
                                  layoutManager: layoutManager, text: textStorage)
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
                    // On the pixel grid, so the 1pt border is crisp at any scale.
                    let frame = backingAlignedRect(first.union(last), options: .alignAllEdgesNearest)
                    let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                            xRadius: ConversationMetrics.blockRadius, yRadius: ConversationMetrics.blockRadius)
                    WovenColors.primary.withAlphaComponent(0.032).setFill()
                    path.fill()
                    // A step stronger in Dark, as a visual reply's frame is.
                    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    WovenColors.foreground.withAlphaComponent(isDark ? 0.14 : 0.09).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                    // One rule under every row but the last, one device pixel
                    // tall on the pixel grid, where the row's border is laid out.
                    let pixel = 1 / (window?.backingScaleFactor ?? 1)
                    WovenColors.foreground.withAlphaComponent(0.09).setFill()
                    var rowBottoms: [Int: CGFloat] = [:]
                    textStorage.enumerateAttribute(.paragraphStyle, in: decoration.range) { value, range, _ in
                        guard let cell = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock,
                              cell.width(for: .border, edge: .maxY) > 0 else { return }
                        let bounds = layoutManager.boundsRect(for: cell, glyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
                        rowBottoms[cell.startingRow] = max(rowBottoms[cell.startingRow] ?? 0, bounds.maxY)
                    }
                    for bottom in rowBottoms.values {
                        let rule = NSRect(x: frame.minX + 1, y: bottom - Prose.tableRule / 2 - pixel / 2, width: frame.width - 2, height: pixel)
                        backingAlignedRect(rule, options: [.alignMinXNearest, .alignMaxXNearest, .alignMinYNearest, .alignHeightNearest]).fill()
                    }
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
            // The glyphs' drawn baseline, raised text's (the plain style's) included.
            let baseline = fragment.minY + layoutManager.location(forGlyphAt: pieceGlyphs.location).y
            // Around the code's own line box, so stacked lines never touch,
            // and never past the text's left edge, where it would be cut off.
            let minX = max(0, bounds.minX - ConversationMetrics.hair)
            let rect = NSRect(x: minX, y: baseline - font.ascender - 1,
                              width: bounds.maxX + ConversationMetrics.hair - minX, height: font.ascender - font.descender + 2)
            NSBezierPath(roundedRect: rect, xRadius: ConversationMetrics.tight, yRadius: ConversationMetrics.tight).fill()
        }
    }

    /// A quiet wrap mark before each wrapped code line's first character, in
    /// its hanging indent and never left of the box's text edge `boxText`:
    /// drawn, not text, so selection and copying never see it.
    private func drawWrapMarks(_ glyphs: NSRange, boxText: CGFloat, layoutManager: NSLayoutManager, text: NSTextStorage) {
        guard glyphs.length > 0 else { return }
        let characters = text.string as NSString
        var index = glyphs.location
        while index < NSMaxRange(glyphs) {
            var line = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &line)
            index = NSMaxRange(line)
            let first = layoutManager.characterIndexForGlyph(at: line.location)
            // A line that starts a paragraph is a line of the code, not a wrap.
            guard first > 0, characters.character(at: first - 1) != 0x0A,
                  let code = text.attribute(.font, at: first, effectiveRange: nil) as? NSFont, code.isFixedPitch else { continue }
            let font = NSFont.systemFont(ofSize: (code.pointSize * 0.85).rounded())
            let mark = NSAttributedString(string: "↪", attributes: [
                .font: font, .foregroundColor: WovenColors.foreground.withAlphaComponent(0.5 * (appliedStyle?.inkOpacity ?? 1))])
            let size = mark.size()
            let textStart = layoutManager.lineFragmentUsedRect(forGlyphAt: line.location, effectiveRange: nil).minX
            let baseline = fragment.minY + layoutManager.location(forGlyphAt: line.location).y
            // Centred on the code's x-height, a little before its text.
            let x = max(boxText, textStart - size.width - ConversationMetrics.hair)
            let markBaseline = baseline - code.xHeight / 2 + font.xHeight / 2
            mark.draw(at: NSPoint(x: x, y: markBaseline - font.ascender))
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
            // The surface's colour: white on the dark green fill, the dark
            // surface on the pale green fill in Dark.
            WovenColors.background.setStroke()
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

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        ResponseLineBreaks.allowsBreak(in: layoutManager, before: charIndex)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByHyphenatingBeforeCharacterAt charIndex: Int) -> Bool {
        ResponseLineBreaks.allowsBreak(in: layoutManager, before: charIndex)
    }

    /// Text that changes keeps its links to files that have chips.
    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) { linkFiles(in: editedRange, of: textStorage) }
    }

    /// Makes each link to a file in `range` a link when the reply's file row
    /// has a chip for it, and plain text when it has none.
    private func linkFiles(in range: NSRange, of storage: NSTextStorage) {
        storage.enumerateAttribute(.responseFileLink, in: range) { value, part, _ in
            guard let path = value as? String else { return }
            if openableFiles.contains(path) {
                storage.addAttribute(.link, value: URL(fileURLWithPath: path), range: part)
            } else {
                storage.removeAttribute(.link, range: part)
            }
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if !applying, selectedRange().length > 0 { onSelect?() }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let path = textStorage?.attribute(.responseFileLink, at: charIndex, effectiveRange: nil) as? String {
            if openableFiles.contains(path) { onOpenFile?(path) }
            return true
        }
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, ConversationMarkdownDocument.isLiveLink(url) { onOpenLink?(url) }
        // Always consume the click; opening still requires the existing confirmation.
        return true
    }
}


/// How short inline code keeps together: whole (in a table cell); on one
/// line when a line can hold it, else between its spaces (short code in
/// prose); or only between its spaces.
private enum ResponseNoBreak: Int {
    case whole
    case line
    case words
}

/// Where a reply's lines may break, for the displayed text and for
/// measuring a table before it is displayed.
@MainActor
private final class ResponseLineBreaks: NSObject, @preconcurrency NSLayoutManagerDelegate {
    static let shared = ResponseLineBreaks()

    /// Lines do not break inside text kept together, except after a space in
    /// text kept together only by its words, or in short code wider than the
    /// line it would move to.
    static func allowsBreak(in layoutManager: NSLayoutManager, before charIndex: Int) -> Bool {
        guard let text = layoutManager.textStorage, charIndex > 0, charIndex < text.length,
              let kept = text.attribute(.responseNoBreak, at: charIndex, effectiveRange: nil) as? ResponseNoBreak,
              text.attribute(.responseNoBreak, at: charIndex - 1, effectiveRange: nil) != nil else { return true }
        let previous = (text.string as NSString).character(at: charIndex - 1)
        guard previous == 0x20 || previous == 0x09 else { return false }
        switch kept {
        case .whole: return false
        case .words: return true
        case .line:
            var span = NSRange()
            _ = text.attribute(.responseNoBreak, at: charIndex, longestEffectiveRange: &span,
                               in: (text.string as NSString).paragraphRange(for: NSRange(location: charIndex, length: 0)))
            let style = text.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle
            let container = layoutManager.textContainers.first?.size.width ?? .greatestFiniteMagnitude
            let tail = style.map { $0.tailIndent <= 0 ? container + $0.tailIndent : $0.tailIndent } ?? container
            return text.attributedSubstring(from: span).size().width > ConversationMetrics.Prose.proseCodeLineShare * (tail - (style?.headIndent ?? 0))
        }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        Self.allowsBreak(in: layoutManager, before: charIndex)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByHyphenatingBeforeCharacterAt charIndex: Int) -> Bool {
        Self.allowsBreak(in: layoutManager, before: charIndex)
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
    /// Text a line does not break inside (short inline code), as a `ResponseNoBreak`.
    static let responseNoBreak = Self("WovenMatterResponseNoBreak")
    /// The text of a link to a local file, as the file's path.
    static let responseFileLink = Self("WovenMatterResponseFileLink")
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

    /// How much short inline code in a table cell keeps together: all of it
    /// on one line; one word whole, several words each whole but free to
    /// break between them; or each breaking at its spaces like the text
    /// around it.
    private enum CellCode { case whole, wholeWords, words }

    private static let emptyParagraph = Block.paragraph(.init(""))

    /// `values` rendered on their own, after `previous` (nil at the start of
    /// the response). Every gap is spacing above a block's first line, chosen
    /// from that block and the one before it, never from the one after: a
    /// streaming reply renders what follows its stable cut again with each
    /// chunk, after the last block before the cut, so pieces rendered apart
    /// join exactly as the whole renders. Blocks that do not end the response
    /// keep their last line break.
    /// `width` is the text's width, which tables share out among their
    /// columns and which caps how far a wrapped code line indents.
    static func render(_ values: [Block], after previous: Block?, endsResponse: Bool,
                       style responseStyle: ConversationResponse.Style, width: CGFloat) -> NSAttributedString {
        renderPieces(values, after: previous, endsResponse: endsResponse, style: responseStyle, width: width).text
    }

    /// Whether a block renders differently at another width: a table shares
    /// it out among its columns, code caps how far its wrapped lines indent,
    /// and a list spaces an item by whether the item above it wraps.
    static func followsWidth(_ block: Block) -> Bool {
        switch block {
        case .table, .code, .list: true
        case .quote(let quoted): quoted.contains(where: followsWidth)
        default: false
        }
    }

    /// `text` without the lines that are only a provider's metadata tag, such
    /// as `<tools-used-before-summary>WebFetch</tools-used-before-summary>`:
    /// a hyphenated tag name, opened and closed on one line, or self-closing.
    static func withoutProviderMarkup(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return providerMarkupLine.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static let providerMarkupLine = try! NSRegularExpression(
        pattern: #"^[ \t]*<([a-z][a-z0-9]*(?:-[a-z0-9]+)+)(?:[ \t][^<>\n]*)?(?:/>|>[^<>\n]*</\1>)[ \t]*(?:\n|$)"#,
        options: [.anchorsMatchLines, .caseInsensitive])

    /// `render`'s text, with the length of each block's part of it: a block
    /// rendered again on its own, after the block before it, is exactly that
    /// part, and the last block with any text is the one that ends it.
    static func renderPieces(_ values: [Block], after previous: Block?, endsResponse: Bool,
                             style responseStyle: ConversationResponse.Style, width: CGFloat) -> (text: NSAttributedString, lengths: [Int]) {
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
        func headingFont(_ level: Int) -> ResponseFont {
            let size: CGFloat = switch level { case 1: 22; case 2: 19; case 3: 17; default: 15.5 }
            return font(size, .semibold)
        }

        func paragraphStyle(indent: CGFloat, before: CGFloat, lineSpacing: CGFloat = Prose.lineSpacing) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.paragraphSpacingBefore = before
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            return style
        }

        /// In a table cell, short inline code keeps together on one line as
        /// far as `cellCode` allows. Code is a little smaller than the text
        /// around it, in a cell as in prose.
        func inline(_ text: ConversationMarkdownDocument.InlineText, font: ResponseFont, inCell: Bool = false,
                    cellCode: CellCode = .whole, keeping kept: Set<String> = []) -> NSMutableAttributedString {
            let result = NSMutableAttributedString(string: "")
            for run in text.rendered.runs {
                let intent = run.inlinePresentationIntent ?? []
                var runFont = intent.contains(.code) ? monospaced(inCell ? Prose.cellCodeSize : Prose.inlineCodeSize) : font
                if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: foreground]
                let string = String(text.rendered[run.range].characters)
                if intent.contains(.code) {
                    attributes[.responseInlineCode] = true
                    // Short code keeps together: whole in a table cell, as far
                    // as the table allows; in prose, on one line when a line
                    // can hold it; else it may still break at its spaces,
                    // never inside a flag.
                    if inCell, string.count <= Prose.unbreakableCodeLength {
                        let whole = cellCode == .whole || kept.contains(string) || (cellCode == .wholeWords && !string.contains(" "))
                        attributes[.responseNoBreak] = whole ? ResponseNoBreak.whole : ResponseNoBreak.words
                    } else if !inCell, string.count <= Prose.proseCodeOnOneLine {
                        attributes[.responseNoBreak] = ResponseNoBreak.line
                    }
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link {
                    if ConversationMarkdownDocument.isLiveLink(link) {
                        attributes[.link] = link
                    } else if let path = LibraryFileReference.path(link.absoluteString) {
                        // A link to a local file is a link only while the reply
                        // has a chip for that file (see `openableFiles`).
                        attributes[.responseFileLink] = path
                    }
                }
                result.append(NSAttributedString(string: string, attributes: attributes))
            }
            // In prose, a short link moves to the next line whole, with the
            // brackets around it and the punctuation after it, as short code
            // does (`allowsBreak`).
            if !inCell {
                let string = result.string as NSString
                var links: [NSRange] = []
                for key in [NSAttributedString.Key.link, .responseFileLink] {
                    result.enumerateAttribute(key, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                        if value != nil, range.length <= Prose.shortLinkLength { links.append(range) }
                    }
                }
                // UTF-16 code units of ( [ and ) ] , . (a surrogate is none of them).
                let opening: Set<unichar> = [0x28, 0x5B], closing: Set<unichar> = [0x29, 0x5D, 0x2C, 0x2E]
                for link in links {
                    var range = link
                    if range.location > 0, opening.contains(string.character(at: range.location - 1)) {
                        range = NSRange(location: range.location - 1, length: range.length + 1)
                    }
                    while NSMaxRange(range) < string.length, closing.contains(string.character(at: NSMaxRange(range))) {
                        range.length += 1
                    }
                    result.addAttribute(.responseNoBreak, value: ResponseNoBreak.line, range: range)
                }
            }
            return result
        }

        /// Each source line is its own paragraph. The first takes `style`;
        /// the lines after it continue the block, at its content indent with
        /// no gap above, so they space like wrapped lines.
        func append(_ text: NSAttributedString, style: NSParagraphStyle, into target: NSMutableAttributedString? = nil) {
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
            (target ?? output).append(paragraph)
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

        // The plain style's lines: each as tall as a line of its text, with
        // nothing between them, whatever block it came from.
        let plain = responseStyle == .plainReasoning
        // Every line box is the pitch tall, line spacing included, the last
        // line's too; TextKit puts the extra height above the text, so the
        // text is raised by it to sit where a line with spacing below would.
        let pitch = ConversationResponse.Style.plainLinePitch
        let raise = pitch - ceil(NSLayoutManager().defaultLineHeight(for: body))
        func plainLine(_ text: NSAttributedString, after prefix: String = "") {
            let line = NSMutableAttributedString(string: prefix, attributes: [.font: body, .foregroundColor: foreground])
            line.append(text)
            line.addAttribute(.baselineOffset, value: raise, range: NSRange(location: 0, length: line.length))
            let style = paragraphStyle(indent: 0, before: 0, lineSpacing: 0)
            style.minimumLineHeight = pitch
            style.maximumLineHeight = pitch
            append(line, style: style)
        }

        /// A block as plain lines: code line by line, a table row by row, a
        /// list item after its marker, a quote's blocks, and a rule as nothing.
        func emitPlain(_ block: Block, prefix: String = "") {
            switch block {
            case .paragraph(let content):
                plainLine(inline(content, font: body), after: prefix)
            case .heading(_, let content):
                plainLine(inline(content, font: font(15, .semibold)), after: prefix)
            case .list(let items):
                for item in items {
                    let marker = item.continuation ? "" : (item.checked.map { $0 ? "☑" : "☐" } ?? item.marker) + " "
                    guard let first = item.blocks.first else { plainLine(NSAttributedString(), after: marker); continue }
                    if !marker.isEmpty, leadsWithMarkerLine(first) { plainLine(NSAttributedString(), after: marker) }
                    emitPlain(first, prefix: leadsWithMarkerLine(first) ? "" : marker)
                    item.blocks.dropFirst().forEach { emitPlain($0) }
                }
            case .quote(let quoted):
                for (index, block) in quoted.enumerated() { emitPlain(block, prefix: index == 0 ? prefix : "") }
            case .code(_, let content):
                if !prefix.isEmpty { plainLine(NSAttributedString(), after: prefix) }
                for line in content.components(separatedBy: "\n") {
                    plainLine(NSAttributedString(string: line, attributes: [.font: monospaced(13), .foregroundColor: foreground]))
                }
            case .table(let table):
                if !prefix.isEmpty { plainLine(NSAttributedString(), after: prefix) }
                for cells in [table.header] + table.rows {
                    let row = NSMutableAttributedString()
                    for (index, cell) in cells.enumerated() {
                        if index > 0 { row.append(NSAttributedString(string: " · ", attributes: [.font: body, .foregroundColor: foreground])) }
                        row.append(inline(cell, font: body))
                    }
                    plainLine(row)
                }
            case .divider:
                break
            }
        }

        /// `values` in order. The first block's gap is `firstBefore` when a
        /// container chose it; every other block's comes from its predecessor.
        func sequence(_ values: [Block], indent: CGFloat, after previous: Block?, firstBefore: CGFloat?,
                      itemGap: CGFloat?, marker: Marker? = nil) {
            var previous = previous
            for (index, block) in values.enumerated() {
                let chosen = index == 0 ? firstBefore : nil
                emit(block, indent: indent, before: chosen ?? spacing(after: previous, before: block, itemGap: itemGap),
                     itemGap: itemGap, marker: index == 0 ? marker : nil)
                previous = block
            }
        }

        func emit(_ block: Block, indent: CGFloat, before: CGFloat, itemGap: CGFloat?, marker: Marker?) {
            if plain { return emitPlain(block) }
            var before = before
            // A block that cannot start with the marker gets a line of its own for it.
            if let marker, leadsWithMarkerLine(block) {
                appendInline(.init(""), font: body, style: paragraphStyle(indent: indent, before: before), marker: marker)
                before = spacing(after: emptyParagraph, before: block, itemGap: itemGap ?? Prose.nestedListGap)
            }
            let marker = leadsWithMarkerLine(block) ? nil : marker
            switch block {
            case .paragraph(let content):
                appendInline(content, font: body, style: paragraphStyle(indent: indent, before: before), marker: marker)
            case .heading(let level, let content):
                appendInline(content, font: headingFont(level), style: paragraphStyle(indent: indent, before: before),
                             marker: marker)
            case .list(let items):
                // Nesting steps by level, however many spaces the source used,
                // decided in source order so a later item never moves an earlier one.
                var indents: [Int] = []
                var previousItem: Block?
                // The kind of list at each open level, so a list straight after
                // a sibling list of another kind, at any depth, reads as its own.
                var kinds: [MarkerKind?] = []
                // Whether the item above wraps at this width: the gap under an
                // item comes from that item alone, so an item that starts to
                // wrap while it streams never moves itself or what is above it.
                var previousWraps = false
                /// An item takes more than one line at this width: it holds
                /// more than one block, or its first paragraph is wider than
                /// its line.
                func wraps(_ item: ConversationMarkdownDocument.ListItem, textIndent: CGFloat) -> Bool {
                    guard item.blocks.count == 1 else { return item.blocks.count > 1 }
                    let text: NSAttributedString
                    switch item.blocks[0] {
                    case .paragraph(let content): text = inline(content, font: body)
                    case .heading(let level, let content): text = inline(content, font: headingFont(level))
                    default: return true
                    }
                    return text.string.contains("\n") || text.size().width > width - textIndent
                }
                for (index, item) in items.enumerated() {
                    while let last = indents.last, last > item.depth { indents.removeLast(); kinds.removeLast() }
                    if indents.last != item.depth { indents.append(item.depth); kinds.append(nil) }
                    let level = CGFloat(min(indents.count - 1, 6))
                    let kind: MarkerKind = item.checked != nil ? .task : item.marker == "•" ? .bullet : .number
                    // A different kind of list straight after one reads as a list of its own.
                    // An item's blocks after its nested list continue it, at its text indent.
                    let startsList = !item.continuation && kinds[kinds.count - 1].map { $0 != kind } == true
                    if !item.continuation { kinds[kinds.count - 1] = kind }
                    let markerEnd = indent + Prose.markerColumn + level * Prose.nestedListStep
                    // A task's box is drawn over its character, which stays for copying.
                    let text: NSAttributedString = if let checked = item.checked {
                        NSAttributedString(string: checked ? "☑" : "☐", attributes: [
                            .font: body, .foregroundColor: NSColor.clear, .responseTaskBox: checked])
                    } else {
                        NSAttributedString(string: item.marker, attributes: [.font: body, .foregroundColor: foreground])
                    }
                    // Top-level items stand further apart than a nested list's,
                    // and further under an item that wraps; an item's later
                    // blocks take its level's one-line gap.
                    let itemGap = level == 0 ? Prose.listGap : Prose.nestedListGap
                    let underGap = !previousWraps ? itemGap : level == 0 ? Prose.wrappedListGap : Prose.wrappedNestedListGap
                    // A citation line after an item's nested list belongs to what it
                    // cites: a label gap above it, its line raised a little more into
                    // that gap (which moves what follows up with it), and the next
                    // item the wrapped-item gap below it, once, since the item it
                    // closes takes several lines.
                    let citation = item.continuation && isCitationLine(item.blocks.first)
                    let gap = startsList ? ConversationMetrics.sectionGap
                        : citation ? ConversationMetrics.labelGap : underGap
                    let first = index == 0 ? before : max(0, gap + itemTopOverhang(item) - bottomSlack(previousItem))
                    let itemMarker = Marker(text: text, start: markerEnd - Prose.markerColumn, end: markerEnd)
                    if item.blocks.isEmpty {
                        appendInline(.init(""), font: body,
                                     style: paragraphStyle(indent: markerEnd + Prose.markerGap, before: first), marker: itemMarker)
                    }
                    let itemStart = output.length
                    sequence(item.blocks, indent: markerEnd + Prose.markerGap, after: nil, firstBefore: first, itemGap: itemGap,
                             marker: item.continuation ? nil : itemMarker)
                    if citation {
                        // A line box shorter than the text's by the raise: TextKit
                        // keeps the text's descent, so the text moves up by it.
                        // The citation's own line only: blocks after it keep their styles.
                        let height = NSLayoutManager().defaultLineHeight(for: body) - Prose.citationRaise
                        let line = (output.string as NSString).paragraphRange(for: NSRange(location: itemStart, length: 0))
                        output.enumerateAttribute(.paragraphStyle, in: line) { value, range, _ in
                            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
                            style.minimumLineHeight = height
                            style.maximumLineHeight = height
                            output.addAttribute(.paragraphStyle, value: style, range: range)
                        }
                    }
                    previousItem = item.blocks.last ?? emptyParagraph
                    // A continuation closes an item that takes several lines.
                    previousWraps = item.continuation || wraps(item, textIndent: markerEnd + Prose.markerGap)
                }
            case .quote(let quoted):
                let start = output.length
                sequence(quoted, indent: indent + Prose.quoteBar + Prose.quoteGap, after: nil, firstBefore: before,
                         itemGap: itemGap, marker: marker)
                // Quoted text is a step quieter than the text around it: the
                // step commentary takes from the reply's ink.
                let quoted = foreground.withAlphaComponent(responseStyle.inkOpacity * ConversationResponse.Style.commentary.inkOpacity)
                let range = NSRange(location: start, length: output.length - start)
                output.enumerateAttribute(.foregroundColor, in: range) { value, part, _ in
                    if (value as? NSColor) == foreground { output.addAttribute(.foregroundColor, value: quoted, range: part) }
                }
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
                // Each code line is its own paragraph. One that wraps continues
                // two cells right of its own leading whitespace, so a wrap never
                // reads as a line of its own, and never past half the box.
                let code = monospaced(13)
                let cell = (" " as NSString).size(withAttributes: [.font: code]).width
                let halfBox = max(0, (width - style.headIndent - ConversationMetrics.blockInset) / 2)
                for (index, line) in content.components(separatedBy: "\n").enumerated() {
                    let lineStyle = style.mutableCopy() as! NSMutableParagraphStyle
                    if index > 0 { lineStyle.paragraphSpacingBefore = 0 }
                    let lead = leadingWidth(of: line, cell: cell, from: style.headIndent, tabs: style)
                    lineStyle.headIndent = style.headIndent + min(lead + Prose.codeContinuationCells * cell, halfBox)
                    output.append(NSAttributedString(string: line + "\n", attributes: [
                        .font: code, .foregroundColor: foreground, .paragraphStyle: lineStyle]))
                }
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
                // Cells are rendered once for each way of keeping code together,
                // and their limits measured once, whatever widths are tried.
                var renderedCells: [String: [[NSMutableAttributedString]]] = [:]
                func cellTexts(_ code: CellCode, keeping kept: Set<String> = []) -> [[NSMutableAttributedString]] {
                    let key = "\(code) " + kept.sorted().joined(separator: "\u{1F}")
                    if let known = renderedCells[key] { return known }
                    let rows = ([table.header] + table.rows).enumerated().map { rowIndex, cells in
                        table.header.indices.map { column in
                            inline(cells.indices.contains(column) ? cells[column] : .init(""),
                                   font: font(13, rowIndex == 0 ? .semibold : .regular), inCell: true, cellCode: code, keeping: kept)
                        }
                    }
                    renderedCells[key] = rows
                    return rows
                }
                var measuredLimits: [String: (most: [CGFloat], least: [CGFloat])] = [:]
                // The usual automatic table layout: each column is at least
                // its longest unbreakable run (up to a limit) and at most its
                // width on one line. If every column fits on one line, it
                // gets that (stretched to the full width when nearly there); otherwise each gets its least, and the room left
                // is shared in proportion to how much more each would take.
                func limits(_ rows: [[NSMutableAttributedString]], keepingShortCells: Bool = true) -> (most: [CGFloat], least: [CGFloat]) {
                    let key = "\(ObjectIdentifier(rows[0][0]).hashValue) \(keepingShortCells)"
                    if let known = measuredLimits[key] { return known }
                    let most = table.header.indices.map { column in
                        max(1, rows.map { ceil($0[column].size().width) + 1 }.max() ?? 1)
                    }
                    // A column is never narrower than a run it may not break: code
                    // kept whole, or a short cell ("7,098 bytes"). The limit only
                    // caps runs a line may still break, such as a long word or URL.
                    let least = table.header.indices.map { column in
                        let runs = rows.map { row in
                            keepingShortCells && row[column].length <= Prose.shortCellLength
                                ? (kept: ceil(row[column].size().width) + 1, word: CGFloat(1)) : unbreakableWidths(row[column])
                        }
                        let kept = runs.map(\.kept).max() ?? 1
                        let word = min(Prose.tableColumnMinimumLimit, runs.map(\.word).max() ?? 1)
                        return min(most[column], max(kept, word))
                    }
                    measuredLimits[key] = (most, least)
                    return (most, least)
                }
                // In a narrow column cells keep less padding, so their text gets the room.
                let narrow = width < Prose.narrowTableWidth
                let padX = narrow ? Prose.narrowCellPaddingHorizontal : Prose.cellPaddingHorizontal
                let padY = narrow ? Prose.narrowCellPaddingVertical : Prose.cellPaddingVertical
                let available = width - indent - CGFloat(table.header.count) * 2 * padX
                /// The columns' widths for `rows`: their natural widths when
                /// they fit, else each column's least and a share of the rest.
                /// With `pinningCode`, a column mostly of code keeps its least
                /// and the others share the room.
                func columnWidths(_ rows: [[NSMutableAttributedString]], pinningCode: Bool = false) -> [CGFloat] {
                    let (most, least) = limits(rows)
                    var widths: [CGFloat]
                    let natural = most.reduce(0, +)
                    if natural <= available {
                        // A table nearly as wide as the text fills it, sharing the
                        // spare width by natural width, so it does not stop just
                        // short of the boxes around it; a narrower one hugs its content.
                        let fills = natural >= Prose.tableFillShare * available
                        widths = most.map { fills ? $0 + (available - natural) * $0 / natural : $0 }
                    } else {
                        // Each gets its least, and the room left is shared in
                        // proportion to how much more each would take.
                        func share(_ least: [CGFloat]) -> [CGFloat] {
                            let room = max(0, available - least.reduce(0, +))
                            let stretch = most.indices.map { pinningCode && codeColumns.contains($0) ? 0 : most[$0] - least[$0] }
                            let total = stretch.reduce(0, +)
                            return least.indices.map { least[$0] + (total > 0 ? room * stretch[$0] / total : 0) }
                        }
                        widths = share(least)
                        // Minima wider than the text together: short cells break
                        // between their words too.
                        if widths.reduce(0, +) > available {
                            widths = share(limits(rows, keepingShortCells: false).least)
                        }
                        // Still too wide: the widest columns give way, down to a
                        // common width, and break their words where they must, so
                        // no cell is ever cut off.
                        if widths.reduce(0, +) > available {
                            var left = max(CGFloat(widths.count), available), count = CGFloat(widths.count)
                            var level = left / count
                            for value in widths.sorted() {
                                guard value * count > left else { left -= value; count -= 1; continue }
                                level = left / count
                                break
                            }
                            widths = widths.map { min($0, max(1, level.rounded(.down))) }
                        }
                    }
                    return widths
                }
                /// The table's cells at `widths`, as displayed.
                func tableCells(_ rows: [[NSMutableAttributedString]], _ widths: [CGFloat], into target: NSMutableAttributedString? = nil) {
                    let nativeTable = NSTextTable()
                    nativeTable.numberOfColumns = table.header.count
                    nativeTable.collapsesBorders = true
                    nativeTable.setWidth(indent, type: responseAbsolute, for: .margin, edge: .minX)
                    // These widths, as computed: TextKit's own automatic layout
                    // would weigh them against the cells' content again.
                    nativeTable.layoutAlgorithm = .fixedLayoutAlgorithm
                    for (rowIndex, cells) in rows.enumerated() {
                        for (column, text) in cells.enumerated() {
                            let cell = NSTextTableBlock(table: nativeTable, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                            cell.setValue(widths[column], type: responseAbsolute, for: .width)
                            cell.setWidth(padX, type: responseAbsolute, for: .padding, edge: .minX)
                            cell.setWidth(padX, type: responseAbsolute, for: .padding, edge: .maxX)
                            cell.setWidth(padY, type: responseAbsolute, for: .padding, edge: .minY)
                            // A cell's last line keeps its line spacing below it.
                            cell.setWidth(padY - Prose.cellLineSpacing, type: responseAbsolute,
                                          for: .padding, edge: .maxY)
                            if rowIndex < rows.count - 1 {
                                // Room for the rule under the row, which the view draws
                                // on the pixel grid (TextKit's would land on half points).
                                cell.setWidth(Prose.tableRule, type: responseAbsolute, for: .border, edge: .maxY)
                            }
                            cell.setBorderColor(.clear)
                            let cellStyle = paragraphStyle(indent: 0, before: 0, lineSpacing: Prose.cellLineSpacing)
                            cellStyle.textBlocks = [cell]
                            if table.alignments.indices.contains(column) {
                                cellStyle.alignment = switch table.alignments[column] { case .leading: .left; case .center: .center; case .trailing: .right }
                            }
                            append(text, style: cellStyle, into: target)
                        }
                    }
                }
                // Columns mostly of code (a column of commands).
                let codeColumns: Set<Int> = Set(table.header.indices.filter { column in
                    var code = 0, all = 0
                    for row in table.rows where row.indices.contains(column) {
                        let text = inline(row[column], font: body)
                        all += text.length
                        text.enumerateAttribute(.responseInlineCode, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                            if value != nil { code += range.length }
                        }
                    }
                    return all > 0 && 2 * code > all
                })
                /// One way to lay the table out: how its code keeps together
                /// (and which spans of several words stay whole), and its widths.
                typealias Choice = (code: CellCode, kept: Set<String>, widths: [CGFloat])
                /// `widths` with each column at least its least for `rows`, the
                /// points that takes coming from one other column, or from all
                /// of them by the room each has past its least.
                func fitting(_ widths: [CGFloat], _ rows: [[NSMutableAttributedString]]) -> [[CGFloat]] {
                    let least = limits(rows).least
                    var raised = widths
                    for column in raised.indices where raised[column] < least[column] { raised[column] = least[column] }
                    let need = raised.reduce(0, +) - widths.reduce(0, +)
                    guard need > 0 else { return [raised] }
                    let donors = raised.indices.filter { raised[$0] == widths[$0] && raised[$0] > least[$0] }
                    var result: [[CGFloat]] = donors.compactMap { donor in
                        guard raised[donor] - need >= least[donor] else { return nil }
                        var one = raised
                        one[donor] -= need
                        return one
                    }
                    let room = donors.reduce(0) { $0 + raised[$1] - least[$1] }
                    if room >= need {
                        var shared = raised
                        for donor in donors { shared[donor] -= need * (raised[donor] - least[donor]) / room }
                        result.append(shared)
                    }
                    return result
                }
                let whole = cellTexts(.whole)
                let choice: Choice
                if limits(whole).most.reduce(0, +) <= available {
                    choice = (.whole, [], columnWidths(whole))
                } else if let known = Self.tableChoices[Self.tableChoiceKey(whole, width: width, indent: indent, size: font(13).pointSize)] {
                    choice = known
                } else {
                    // Too narrow for the table's natural width. Of the ways
                    // considered, the one laid out shortest, as displayed, by a
                    // line or more; then the one breaking the fewest code spans;
                    // then the earliest, natural shares first. So code breaks
                    // only where that makes the table shorter.
                    let line = (NSLayoutManager().defaultLineHeight(for: font(13)) + Prose.cellLineSpacing) / 2
                    var best: (choice: Choice, height: CGFloat, broken: Int)?
                    var measuredChoices: [Choice] = []
                    @discardableResult
                    /// With `onlyIfShorter`, a candidate wins only by being a line shorter.
                    func consider(_ candidate: Choice, onlyIfShorter: Bool = false) -> Bool {
                        guard !measuredChoices.contains(where: { $0.code == candidate.code && $0.kept == candidate.kept && $0.widths == candidate.widths })
                        else { return false }
                        measuredChoices.append(candidate)
                        let text = NSMutableAttributedString()
                        tableCells(cellTexts(candidate.code, keeping: candidate.kept), candidate.widths, into: text)
                        let measured = Self.measuredTable(text, width: width)
                        guard best.map({ measured.height < $0.height - line
                            || (!onlyIfShorter && abs(measured.height - $0.height) <= line && measured.broken < $0.broken) }) ?? true
                        else { return false }
                        best = (candidate, measured.height, measured.broken)
                        return true
                    }
                    // Code kept whole: natural shares, and a column of code at its least.
                    let wholeFits = limits(whole).least.reduce(0, +) <= available
                    if wholeFits {
                        consider((.whole, [], columnWidths(whole)))
                        consider((.whole, [], columnWidths(whole, pinningCode: true)))
                    }
                    // Code of several words broken between its words (or, too
                    // narrow even for that, every span free to break at its spaces).
                    let splitCode: CellCode = limits(cellTexts(.wholeWords)).least.reduce(0, +) <= available ? .wholeWords : .words
                    let split = cellTexts(splitCode)
                    let splitWidths = columnWidths(split)
                    if split != whole {
                        consider((splitCode, [], splitWidths))
                        consider((splitCode, [], columnWidths(split, pinningCode: true)))
                        // The split's shares with code kept whole again, from the other columns.
                        if wholeFits { for widths in fitting(splitWidths, whole) { consider((.whole, [], widths)) } }
                        // Then each broken span kept whole in turn, shortest
                        // first, where that is no taller: the shortest few, so
                        // a long table costs a few layouts, not one per command.
                        if var current = best, current.broken > 0, current.choice.code != .whole {
                            var spans: [String] = []
                            for row in table.rows {
                                for cell in row {
                                    for run in cell.rendered.runs where run.inlinePresentationIntent?.contains(.code) == true {
                                        let string = String(cell.rendered[run.range].characters)
                                        if string.contains(" "), string.count <= Prose.unbreakableCodeLength, !spans.contains(string) { spans.append(string) }
                                    }
                                }
                            }
                            let code = monospaced(Prose.cellCodeSize)
                            func spanWidth(_ span: String) -> CGFloat { (span as NSString).size(withAttributes: [.font: code]).width }
                            for span in spans.sorted(by: { spanWidth($0) < spanWidth($1) }).prefix(Prose.tableSpansTriedWhole) {
                                let kept = current.choice.kept.union([span])
                                for widths in fitting(current.choice.widths, cellTexts(current.choice.code, keeping: kept)) {
                                    consider((current.choice.code, kept, widths))
                                }
                                if let improved = best { current = improved }
                            }
                        }
                    }
                    // Then a few points moved between the two widest prose
                    // columns, either way, where that makes the table a line
                    // shorter: a row that wraps for one word gets it back.
                    if let current = best {
                        let widths = current.choice.widths
                        let prose = widths.indices.filter { !codeColumns.contains($0) }.sorted { widths[$0] > widths[$1] }
                        if prose.count >= 2 {
                            let least = limits(cellTexts(current.choice.code, keeping: current.choice.kept)).least
                            for (from, to) in [(prose[0], prose[1]), (prose[1], prose[0])] {
                                for shift in Prose.tableColumnShifts where widths[from] - shift >= least[from] {
                                    var shifted = widths
                                    shifted[from] -= shift
                                    shifted[to] += shift
                                    consider((current.choice.code, current.choice.kept, shifted), onlyIfShorter: true)
                                }
                            }
                        }
                    }
                    choice = best?.choice ?? (splitCode, [], splitWidths)
                    Self.rememberTableChoice(choice, for: Self.tableChoiceKey(whole, width: width, indent: indent, size: font(13).pointSize))
                }
                tableCells(cellTexts(choice.code, keeping: choice.kept), choice.widths)
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
        if previous == nil, !plain, topOverhang(values.first) > 0 {
            let lead = NSMutableParagraphStyle()
            lead.minimumLineHeight = 0.01
            lead.maximumLineHeight = 0.01
            output.append(NSAttributedString(string: "\n", attributes: [.font: ResponseFont.systemFont(ofSize: 1), .paragraphStyle: lead,
                                                                        .responseLayoutOnly: true]))
        }
        var ends: [Int] = []
        var before = previous
        for block in values {
            sequence([block], indent: 0, after: before, firstBefore: nil, itemGap: nil)
            ends.append(output.length)
            before = block
        }
        func pieces() -> (text: NSAttributedString, lengths: [Int]) {
            (output, ends.indices.map { ends[$0] - ($0 > 0 ? ends[$0 - 1] : 0) })
        }
        guard endsResponse, output.length > 0 else { return pieces() }
        // The last line break would add an empty line under the text. A box
        // keeps it, so its last line keeps the spacing its edge is drawn from.
        let end = output.length - 1
        let endsInBox = output.attribute(.responseCode, at: end, effectiveRange: nil) != nil
            || (output.attribute(.paragraphStyle, at: end, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == false
        if endsInBox {
            output.addAttribute(.responseLayoutOnly, value: true, range: NSRange(location: end, length: 1))
        } else {
            output.deleteCharacters(in: NSRange(location: end, length: 1))
            ends = ends.map { min($0, output.length) }
        }
        return pieces()
    }

    /// Which way of sharing a narrow table's width was chosen, by table and width.
    private static var tableChoices: [String: (code: CellCode, kept: Set<String>, widths: [CGFloat])] = [:]

    private static func rememberTableChoice(_ choice: (code: CellCode, kept: Set<String>, widths: [CGFloat]), for key: String) {
        if tableChoices.count > 256 { tableChoices.removeAll() }
        tableChoices[key] = choice
    }

    /// A table's cells (their text, and where their code runs) and the width it is laid out at.
    private static func tableChoiceKey(_ rows: [[NSMutableAttributedString]], width: CGFloat, indent: CGFloat, size: CGFloat) -> String {
        var key = "\(width) \(indent) \(size)"
        for row in rows {
            for cell in row {
                key += "\u{1F}"
                cell.enumerateAttribute(.responseInlineCode, in: NSRange(location: 0, length: cell.length)) { value, range, _ in
                    key += (value == nil ? "" : "\u{1}") + (cell.string as NSString).substring(with: range)
                }
            }
            key += "\u{1E}"
        }
        return key
    }

    /// A table's height laid out as the reply lays it out, at `width`, and
    /// how many of its code spans run across more than one line.
    private static func measuredTable(_ text: NSAttributedString, width: CGFloat) -> (height: CGFloat, broken: Int) {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        layoutManager.delegate = ResponseLineBreaks.shared
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        var broken = 0
        storage.enumerateAttribute(.responseInlineCode, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 1 else { return }
            let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = layoutManager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            if first.minY != last.minY { broken += 1 }
        }
        return (layoutManager.usedRect(for: container).maxY, broken)
    }

    /// The widest runs in `text` a line cannot break inside: code kept
    /// whole (with room for its shading), and plain words, which a line can
    /// still break when it must.
    private static func unbreakableWidths(_ text: NSAttributedString) -> (kept: CGFloat, word: CGFloat) {
        let string = text.string as NSString
        var kept: CGFloat = 1, word: CGFloat = 1
        var start = 0
        func isKept(_ index: Int) -> Bool {
            text.attribute(.responseNoBreak, at: index, effectiveRange: nil) as? ResponseNoBreak == .whole
        }
        for index in 0...string.length {
            let breaks = index == string.length || (
                // A surrogate half (an emoji) is part of a word, never a space.
                UnicodeScalar(string.character(at: index)).map { CharacterSet.whitespacesAndNewlines.contains($0) } == true
                && !isKept(index))
            guard breaks else { continue }
            if index > start {
                let range = NSRange(location: start, length: index - start)
                let width = ceil(text.attributedSubstring(from: range).size().width) + 1
                if (start..<index).contains(where: isKept) {
                    kept = max(kept, width + 2 * ConversationMetrics.hair + 2)
                } else {
                    word = max(word, width)
                }
            }
            start = index + 1
        }
        return (kept, word)
    }

    /// How far `line`'s leading spaces and tabs reach past `start`, where it
    /// begins: a cell for a space, the next of `style`'s tab stops for a tab.
    private static func leadingWidth(of line: String, cell: CGFloat, from start: CGFloat, tabs style: NSParagraphStyle) -> CGFloat {
        var x = start
        for character in line {
            if character == " " {
                x += cell
            } else if character == "\t" {
                let interval = style.defaultTabInterval
                x = style.tabStops.first { $0.location > x }?.location
                    ?? (interval > 0 ? (floor(x / interval) + 1) * interval : x + cell)
            } else {
                break
            }
        }
        return x - start
    }

    /// The spacing above `block`'s first line: the visible gap between the two
    /// blocks' edges, adjusted for where those edges sit around their lines.
    /// `itemGap` is the gap between the items of the list `block` is in, nil outside one.
    private static func spacing(after previous: Block?, before block: Block, itemGap: CGFloat?) -> CGFloat {
        max(0, gap(after: previous, before: block, itemGap: itemGap) + topOverhang(block) - bottomSlack(previous))
    }

    /// Visible space between two blocks: text to text, or to a box's edge.
    private static func gap(after previous: Block?, before block: Block, itemGap: CGFloat?) -> CGFloat {
        guard let previous else { return 0 }
        // A heading attaches to what follows it.
        if case .heading(let level, _) = previous { return level <= 2 ? Prose.majorHeadingAttach : Prose.minorHeadingAttach }
        if case .heading(let level, _) = block { return level <= 2 ? Prose.majorHeadingGap : Prose.minorHeadingGap }
        if isRule(previous) || isRule(block) { return Prose.ruleGap }
        if isBox(previous) || isBox(block) { return Prose.paragraphGap }
        // Two lists in a row are two lists, spaced as paragraphs.
        if case .list = previous {
            // Two lists in a row are two lists, a section apart.
            if case .list = block { return ConversationMetrics.sectionGap }
            return Prose.paragraphGap
        }
        if case .list = block { return itemGap == nil ? Prose.paragraphToListGap : Prose.nestedListGap }
        return itemGap ?? Prose.paragraphGap
    }

    /// A paragraph of one line holding only links, perhaps in parentheses or
    /// brackets, separated by commas, "·" or spaces: "([changes.html](…))".
    private static func isCitationLine(_ block: Block?) -> Bool {
        guard case .paragraph(let content) = block else { return false }
        var links = 0
        for run in content.rendered.runs {
            let text = String(content.rendered[run.range].characters)
            if run.link != nil {
                if text.contains("\n") { return false }
                links += 1
            } else if !text.allSatisfy({ " \t()[],·".contains($0) }) {
                return false
            }
        }
        return links > 0
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
        guard let first = item.blocks.first, item.continuation || !leadsWithMarkerLine(first) else { return 0 }
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
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @State private var expanded = false
    /// The width the row offers the bubble, whatever the bubble decides.
    @State private var offeredWidth: CGFloat?

    /// A long message shows this many lines until opened.
    private static var collapsedLines: Int { 6 }
    /// It collapses only when that hides at least this many more.
    private static var hiddenLines: Int { 3 }

    var body: some View {
        let naturalContentWidth = self.naturalContentWidth
        let isLong = collapses(naturalContentWidth: naturalContentWidth)
        VStack(alignment: .trailing, spacing: ConversationMetrics.rowGap) {
            if !content.isEmpty {
                Text(content)
                    .font(.system(size: 15))
                    .lineSpacing(ConversationMetrics.Prose.lineSpacing)
                    .lineLimit(isLong && !expanded ? Self.collapsedLines : nil)
                    .foregroundStyle(WovenPalette.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            attachments()
            if isLong {
                Button(expanded ? "Show less" : "Show full message") {
                    // The reader opened or closed it: the transcript stops following first.
                    transcriptInteraction()
                    withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(WovenPalette.mutedForeground)
            }
        }
        .frame(maxWidth: isLong ? max(naturalContentWidth, ConversationUserBubbleMeasure.controlWidth) : naturalContentWidth,
               alignment: .trailing)
        .padding(ConversationMetrics.bubbleInsets)
        .background(WovenPalette.primary.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.composerRadius, style: .continuous))
        // The bubble sits at the end of all the room the row offers, which is
        // measured here: the room never depends on what the bubble decides.
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { offeredWidth = $0 }
    }
    /// Whether the message is long enough that collapsing it earns the row
    /// its control: its lines at the width it has before any widening for
    /// the control, the room offered or its longest line, whichever is less.
    private func collapses(naturalContentWidth: CGFloat) -> Bool {
        let room = offeredWidth.map { $0 - ConversationMetrics.bubbleInsets.leading - ConversationMetrics.bubbleInsets.trailing }
        return ConversationUserBubbleMeasure.lineCount(content, width: min(naturalContentWidth, room ?? naturalContentWidth))
            >= Self.collapsedLines + Self.hiddenLines
    }

    /// The width of the message's longest line, within the bubble's limit.
    private var naturalContentWidth: CGFloat {
        if hasAttachments { return 420 }
        return ConversationUserBubbleMeasure.naturalWidth(content)
    }
}

/// A user message's measurements, each made once for its text (and width):
/// the bubble asks for them on every pass.
@MainActor
enum ConversationUserBubbleMeasure {
    /// Keyed by the text's exact bytes: two spellings that read the same can lay out differently.
    private struct Lines: Hashable {
        let content: WorkTimelineExactText
        let width: CGFloat
    }

    private static var widths = WorkTimelineGenerations<WorkTimelineExactText, CGFloat>(
        limit: 512, costLimit: 4 * 1_024 * 1_024)
    private static var lines = WorkTimelineGenerations<Lines, Int>(limit: 512, costLimit: 4 * 1_024 * 1_024)

    /// How many lines the message takes at `width`.
    static func lineCount(_ content: String, width: CGFloat) -> Int {
        let key = Lines(content: WorkTimelineExactText(content), width: width)
        if let kept = lines.value(key) { return kept }
        let font = ResponseFont.systemFont(ofSize: 15)
        let spacing = ConversationMetrics.Prose.lineSpacing
        let style = NSMutableParagraphStyle()
        style.lineSpacing = spacing
        let height = (content as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: [.font: font, .paragraphStyle: style]).height
        let line = NSLayoutManager().defaultLineHeight(for: font)
        let count = Int(((height + spacing) / (line + spacing)).rounded())
        lines.insert(key, count, cost: content.utf8.count)
        return count
    }

    /// The width of the message's longest line, within the bubble's limit.
    static func naturalWidth(_ content: String) -> CGFloat {
        let key = WorkTimelineExactText(content)
        if let kept = widths.value(key) { return kept }
        let font = ResponseFont.systemFont(ofSize: 15)
        let longestLine = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = min(586, max(1, ceil(longestLine)))
        widths.insert(key, width, cost: content.utf8.count)
        return width
    }

    /// Room for the control under a message that collapses, however narrow its lines.
    static let controlWidth: CGFloat = {
        let font = ResponseFont.systemFont(ofSize: 12.5, weight: .medium)
        return ceil(["Show full message", "Show less"].map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
    }()
}
