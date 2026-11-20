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
    let content: String
    var document: ConversationMarkdownDocument? = nil
    let isStreaming: Bool
    var showsCopyButton = true
    @Environment(\.conversationLinkHandler) private var linkHandler
    @State private var copied = false
    @State private var pendingExternalURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConversationResponseText(content: content, document: document, isStreaming: isStreaming) { url in
                // Page links only work where a handler routes them (bot chats).
                if let linkHandler { linkHandler(url) } else if WovenAppLink(url) == nil { pendingExternalURL = url }
            }
            .frame(maxWidth: 680, alignment: .leading)

            if showsCopyButton && !isStreaming {
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(content, forType: .string)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: copyTargetSize, height: copyTargetSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(WovenIconButtonStyle())
                .help("Copy complete response")
                .accessibilityLabel(copied ? "Response copied" : "Copy response")
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
    private var copyTargetSize: CGFloat {
        28
    }
}

private struct ConversationResponseText: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let content: String
    let document: ConversationMarkdownDocument?
    let isStreaming: Bool
    let onOpenLink: (URL) -> Void

    func makeNSView(context: Context) -> ConversationResponseViewport {
        ConversationResponseViewport()
    }

    func updateNSView(_ viewport: ConversationResponseViewport, context: Context) {
        viewport.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let textView = viewport.textView
        textView.onOpenLink = onOpenLink
        if textView.apply(content: content, document: document, isStreaming: isStreaming, colorScheme: colorScheme) {
            viewport.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ConversationResponseViewport,
                      context: Context) -> CGSize? {
        nsView.textView.fittingSize(width: proposal.width ?? 680)
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
    private var appliedContent: String?
    private var appliedStreaming: Bool?
    private var appliedColorScheme: ColorScheme?
    private var measuredSize: CGSize?
    private var decorations: [(key: NSAttributedString.Key, range: NSRange)] = []
    /// While streaming: the source before the last stable cut, and the length
    /// of its rendering at the start of the text storage.
    private var stable: (source: String, length: Int)?

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
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
               colorScheme: ColorScheme = .light) -> Bool {
        guard appliedContent != content || appliedStreaming != isStreaming
            || appliedColorScheme != colorScheme else { return false }
        appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let sameColorScheme = appliedColorScheme == colorScheme
        appliedColorScheme = colorScheme
        let selection = selectedRange()
        let previous = selection.length > 0 ? NSString(string: string) : nil
        guard let textStorage else { return false }
        // While a reply streams, the blocks before its last stable cut are
        // already in the text storage: only what follows is parsed, rendered
        // and laid out again, so a chunk costs its own length, not the reply's.
        // The cut stays valid while the reply only grows past what was applied,
        // through the last chunk when it settles.
        let kept: (source: Int, length: Int)
        let tail: NSAttributedString
        if document == nil, let stable, sameColorScheme, let appliedContent,
           content.utf8.starts(with: appliedContent.utf8), stable.length <= textStorage.length {
            kept = (stable.source.utf8.count, stable.length)
            tail = renderStreaming(content, keeping: kept)
        } else if isStreaming, document == nil {
            kept = (0, 0)
            tail = renderStreaming(content, keeping: kept)
        } else {
            stable = nil
            kept = (0, 0)
            tail = ConversationResponseAttributedText.render(document ?? ConversationMarkdownDocument(content))
        }
        textStorage.replaceCharacters(in: NSRange(location: kept.length, length: textStorage.length - kept.length), with: tail)
        measuredSize = nil
        decorations.removeAll { $0.range.location >= kept.length }
        for key in [NSAttributedString.Key.responseCode, .responseQuote, .responseDivider] {
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
    /// reply's new stable cut recorded.
    private func renderStreaming(_ content: String, keeping kept: (source: Int, length: Int)) -> NSAttributedString {
        let start = content.utf8.index(content.startIndex, offsetBy: kept.source)
        let source = content[start...]
        let (blocks, cut) = ConversationMarkdownDocument.blocks(cutting: source)
        let settledCount = cut?.blockCount ?? 0
        let settled = ConversationResponseAttributedText.render(Array(blocks[..<settledCount]), endsResponse: false)
        let tail = NSMutableAttributedString(attributedString: settled)
        tail.append(ConversationResponseAttributedText.render(Array(blocks[settledCount...]), endsResponse: true))
        let end = cut.map { source.utf8.index(source.startIndex, offsetBy: $0.offset) } ?? start
        stable = (String(content[..<end]), kept.length + settled.length)
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
        var height = max(layoutManager.usedRect(for: textContainer).maxY, layoutManager.extraLineFragmentRect.maxY)
        if let textStorage, textStorage.length > 0,
           textStorage.attribute(.responseCode, at: textStorage.length - 1, effectiveRange: nil) != nil { height += 6 }
        let size = CGSize(width: width, height: max(1, ceil(height)))
        measuredSize = size
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        if !decorations.isEmpty, let layoutManager, let textContainer {
            // Include code-box padding and the full line width for partial redraws.
            let visibleRect = NSRect(x: 0, y: dirtyRect.minY - 6,
                                     width: textContainer.size.width, height: dirtyRect.height + 12)
            let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let visibleCharacters = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
            for decoration in decorations where NSIntersectionRange(decoration.range, visibleCharacters).length > 0 {
                let glyphs = layoutManager.glyphRange(forCharacterRange: decoration.range, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                if decoration.key == .responseCode {
                    rect = NSRect(x: 0, y: rect.minY - 6, width: bounds.width, height: rect.height + 12)
                    WovenColors.primary.withAlphaComponent(0.05).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
                } else {
                    WovenColors.foreground.withAlphaComponent(0.16).setFill()
                    if decoration.key == .responseQuote {
                        NSRect(x: max(0, rect.minX - 14), y: rect.minY, width: 2, height: rect.height).fill()
                    } else {
                        NSRect(x: 0, y: rect.midY, width: bounds.width, height: 1).fill()
                    }
                }
            }
        }
        super.draw(dirtyRect)
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
    static let responseTableRow = Self("WovenMatterResponseTableRow")
    static let responseScaledFont = Self("WovenMatterResponseScaledFont")
}

/// Reuses the prepared Markdown parser; only the response's presentation changes.
@MainActor
private enum ConversationResponseAttributedText {
    static func render(_ document: ConversationMarkdownDocument) -> NSAttributedString {
        render(document.blocks, endsResponse: true)
    }

    /// `blocks` rendered on their own. Blocks that do not end the response
    /// keep their last line break, so pieces rendered apart join exactly as
    /// the whole would render.
    static func render(_ values: [ConversationMarkdownDocument.Block], endsResponse: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        // Streaming is conveyed by work activity; answer ink stays stable as
        // paragraphs arrive and the run settles.
        let foreground = WovenColors.foreground

        func paragraphStyle(indent: CGFloat = 0) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            style.paragraphSpacing = 14
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            return style
        }

        func inline(_ text: ConversationMarkdownDocument.InlineText, font: ResponseFont) -> NSMutableAttributedString {
            let result = NSMutableAttributedString(string: "")
            for run in text.rendered.runs {
                let intent = run.inlinePresentationIntent ?? []
                var runFont = intent.contains(.code) ? ResponseFont.monospacedSystemFont(ofSize: 13.5, weight: .regular) : font
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

        func append(_ text: NSAttributedString, style: NSParagraphStyle) {
            let paragraph = NSMutableAttributedString(attributedString: text)
            paragraph.append(NSAttributedString(string: "\n", attributes: [.font: ResponseFont.systemFont(ofSize: 15), .foregroundColor: foreground]))
            let range = NSRange(location: 0, length: paragraph.length)
            paragraph.addAttribute(.paragraphStyle, value: style, range: range)
            if text.string.contains("\n"), style.paragraphSpacing > 0 {
                let interiorStyle = style.mutableCopy() as! NSMutableParagraphStyle
                interiorStyle.paragraphSpacing = 0
                paragraph.addAttribute(.paragraphStyle, value: interiorStyle, range: range)
                let lastLine = (paragraph.string as NSString).paragraphRange(for: NSRange(location: paragraph.length - 1, length: 0))
                paragraph.addAttribute(.paragraphStyle, value: style, range: lastLine)
            }
            output.append(paragraph)
        }

        func blocks(_ values: [ConversationMarkdownDocument.Block], indent: CGFloat = 0, marker: String = "") {
            for (index, block) in values.enumerated() {
                let style = paragraphStyle(indent: indent)
                let prefix = index == 0 ? marker : ""
                if !prefix.isEmpty {
                    style.headIndent = indent + 31
                    style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 31)]
                }
                func appendInline(_ content: ConversationMarkdownDocument.InlineText, font: ResponseFont) {
                    let text = NSMutableAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: foreground])
                    text.append(inline(content, font: font))
                    append(text, style: style)
                }
                switch block {
                case .paragraph(let content):
                    appendInline(content, font: .systemFont(ofSize: 15))
                case .heading(let level, let content):
                    let size: CGFloat = switch level { case 1: 22; case 2: 19; case 3: 17; default: 15.5 }
                    style.paragraphSpacingBefore = level <= 2 ? 6 : 1
                    appendInline(content, font: .systemFont(ofSize: size, weight: .semibold))
                case .list(let items):
                    for item in items {
                        let marker = item.checked.map { $0 ? "☑" : "☐" } ?? item.marker
                        blocks(item.blocks, indent: indent + CGFloat(min(item.depth, 6)) * 17, marker: marker + "\t")
                    }
                case .quote(let quoted):
                    let start = output.length
                    blocks(quoted, indent: indent + 14)
                    output.addAttribute(.responseQuote, value: UUID().uuidString,
                        range: NSRange(location: start, length: output.length - start))
                case .code(let language, let content):
                    let start = output.length
                    style.firstLineHeadIndent = indent + 14
                    style.headIndent = indent + 14
                    style.tailIndent = -14
                    style.paragraphSpacingBefore = 6
                    if let language, !language.isEmpty {
                        style.paragraphSpacing = 6
                        append(NSAttributedString(string: language, attributes: [.font: ResponseFont.systemFont(ofSize: 11.5), .foregroundColor: foreground]), style: style)
                    }
                    style.paragraphSpacingBefore = language?.isEmpty == false ? 0 : 6
                    style.paragraphSpacing = 0
                    style.lineSpacing = 3
                    append(NSAttributedString(string: content, attributes: [.font: ResponseFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: foreground]), style: style)
                    let lastParagraph = (output.string as NSString).paragraphRange(for: NSRange(location: max(start, output.length - 1), length: 0))
                    let lastStyle = style.mutableCopy() as! NSMutableParagraphStyle
                    lastStyle.paragraphSpacing = 20
                    output.addAttribute(.paragraphStyle, value: lastStyle, range: lastParagraph)
                    output.addAttribute(.responseCode, value: UUID().uuidString,
                        range: NSRange(location: start, length: output.length - start))
                case .table(let table):
                    guard !table.header.isEmpty else { continue }
                    let nativeTable = NSTextTable()
                    nativeTable.numberOfColumns = table.header.count
                    nativeTable.collapsesBorders = true
                    nativeTable.setWidth(14, type: responseAbsolute, for: .margin, edge: .maxY)
                    nativeTable.setValue(100, type: responsePercentage, for: .width)
                    for (rowIndex, cells) in ([table.header] + table.rows).enumerated() {
                        for column in table.header.indices {
                            let cell = NSTextTableBlock(table: nativeTable, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                            cell.setValue(100 / CGFloat(table.header.count), type: responsePercentage, for: .width)
                            cell.setWidth(9, type: responseAbsolute, for: .padding)
                            cell.setWidth(0.5, type: responseAbsolute, for: .border)
                            cell.setBorderColor(foreground.withAlphaComponent(0.09))
                            cell.backgroundColor = WovenColors.primary.withAlphaComponent(0.032)
                            let cellStyle = paragraphStyle()
                            cellStyle.paragraphSpacing = 0
                            cellStyle.textBlocks = [cell]
                            if table.alignments.indices.contains(column) {
                                cellStyle.alignment = switch table.alignments[column] { case .leading: .left; case .center: .center; case .trailing: .right }
                            }
                            append(inline(cells.indices.contains(column) ? cells[column] : .init(""), font: .systemFont(ofSize: 13, weight: rowIndex == 0 ? .semibold : .regular)), style: cellStyle)
                        }
                    }
                case .divider:
                    append(NSAttributedString(string: " ", attributes: [.font: ResponseFont.systemFont(ofSize: 15), .responseDivider: true]), style: style)
                }
            }
        }
        blocks(values)
        // A terminal newline creates an extra empty line between text and Copy.
        // Native tables retain their cell-ending paragraph delimiter.
        guard endsResponse else { return output }
        if output.length > 0, case .table = values.last {
            return output
        }
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        return output
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
        VStack(alignment: .trailing, spacing: 8) {
            if !content.isEmpty {
                Text(content)
                    .font(.system(size: 15))
                    .lineSpacing(4)
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
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .background(WovenPalette.primary.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
