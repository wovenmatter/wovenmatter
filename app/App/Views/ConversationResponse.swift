import AppKit
import SwiftUI

/// One selectable text surface and one copy action for the complete response.
struct ConversationResponse: View {
    let content: String
    var document: ConversationMarkdownDocument? = nil
    let isStreaming: Bool
    var showsCopyButton = true
    @State private var copied = false
    @State private var pendingExternalURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConversationResponseText(content: content, document: document, isStreaming: isStreaming) {
                pendingExternalURL = $0
            }
            .frame(maxWidth: 680, alignment: .leading)

            if showsCopyButton { Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(content, forType: .string)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DashboardIconButtonStyle())
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
}

private struct ConversationResponseText: NSViewRepresentable {
    let content: String
    let document: ConversationMarkdownDocument?
    let isStreaming: Bool
    let onOpenLink: (URL) -> Void

    func makeNSView(context: Context) -> ConversationResponseViewport {
        ConversationResponseViewport()
    }

    func updateNSView(_ viewport: ConversationResponseViewport, context: Context) {
        let textView = viewport.textView
        textView.onOpenLink = onOpenLink
        if textView.apply(content: content, document: document, isStreaming: isStreaming) {
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
    private var measuredSize: CGSize?
    private var decorations: [(key: NSAttributedString.Key, range: NSRange)] = []

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
        linkTextAttributes = [.foregroundColor: NSColor(DashboardPalette.success), .underlineStyle: 0]
        setAccessibilityLabel("Agent response")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func apply(content: String, document: ConversationMarkdownDocument?, isStreaming: Bool) -> Bool {
        guard appliedContent != content || appliedStreaming != isStreaming else { return false }
        let selection = selectedRange()
        let previous = selection.length > 0 ? NSString(string: string) : nil
        let rendered = ConversationResponseAttributedText.render(
            document ?? ConversationMarkdownDocument(content), isStreaming: isStreaming
        )
        textStorage?.setAttributedString(rendered)
        measuredSize = nil
        decorations.removeAll(keepingCapacity: true)
        for key in [NSAttributedString.Key.responseCode, .responseQuote, .responseDivider] {
            rendered.enumerateAttribute(key, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
                if value != nil { decorations.append((key, range)) }
            }
        }
        // Streaming appends keep the selection; once the selected text itself
        // changes (a replacement, or a rerendered prefix), it no longer
        // identifies what the user chose.
        let end = NSMaxRange(selection)
        let selectionUnchanged = previous.map { end <= $0.length && end <= rendered.length
            && $0.substring(to: end) == (rendered.string as NSString).substring(to: end) } ?? false
        setSelectedRange(selectionUnchanged ? selection : NSRange(location: 0, length: 0))
        appliedContent = content
        appliedStreaming = isStreaming
        return true
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
                    NSColor(DashboardPalette.primary).withAlphaComponent(0.05).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
                } else {
                    NSColor(DashboardPalette.foreground).withAlphaComponent(0.16).setFill()
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
        if let url, ConversationMarkdownDocument.isSafeExternalLink(url) { onOpenLink?(url) }
        // Always consume the click; opening still requires the existing confirmation.
        return true
    }
}

private extension NSAttributedString.Key {
    static let responseCode = Self("WovenMatterResponseCode")
    static let responseQuote = Self("WovenMatterResponseQuote")
    static let responseDivider = Self("WovenMatterResponseDivider")
}

/// Reuses the prepared Markdown parser; only the response's presentation changes.
@MainActor
private enum ConversationResponseAttributedText {
    static func render(_ document: ConversationMarkdownDocument, isStreaming: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let foreground = NSColor(DashboardPalette.foreground).withAlphaComponent(isStreaming ? 0.76 : 1)

        func paragraphStyle(indent: CGFloat = 0) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            style.paragraphSpacing = 14
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            return style
        }

        func inline(_ text: ConversationMarkdownDocument.InlineText, font: NSFont) -> NSMutableAttributedString {
            let result = NSMutableAttributedString()
            for run in text.rendered.runs {
                let intent = run.inlinePresentationIntent ?? []
                var runFont = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular) : font
                if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: foreground]
                if intent.contains(.code) { attributes[.backgroundColor] = NSColor(DashboardPalette.primary).withAlphaComponent(0.075) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link, ConversationMarkdownDocument.isSafeExternalLink(link) { attributes[.link] = link }
                result.append(NSAttributedString(string: String(text.rendered[run.range].characters), attributes: attributes))
            }
            return result
        }

        func append(_ text: NSAttributedString, style: NSParagraphStyle) {
            let paragraph = NSMutableAttributedString(attributedString: text)
            paragraph.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: foreground]))
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
                func appendInline(_ content: ConversationMarkdownDocument.InlineText, font: NSFont) {
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
                        append(NSAttributedString(string: language, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: foreground]), style: style)
                    }
                    style.paragraphSpacingBefore = language?.isEmpty == false ? 0 : 6
                    style.paragraphSpacing = 0
                    style.lineSpacing = 3
                    append(NSAttributedString(string: content, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: foreground]), style: style)
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
                    nativeTable.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)
                    nativeTable.setValue(100, type: .percentageValueType, for: .width)
                    for (rowIndex, cells) in ([table.header] + table.rows).enumerated() {
                        for column in table.header.indices {
                            let cell = NSTextTableBlock(table: nativeTable, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                            cell.setValue(100 / CGFloat(table.header.count), type: .percentageValueType, for: .width)
                            cell.setWidth(9, type: .absoluteValueType, for: .padding)
                            cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                            cell.setBorderColor(foreground.withAlphaComponent(0.09))
                            cell.backgroundColor = NSColor(DashboardPalette.primary).withAlphaComponent(0.032)
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
                    append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 15), .responseDivider: true]), style: style)
                }
            }
        }
        blocks(document.blocks)
        // A terminal newline creates an extra empty line between text and Copy.
        // Native tables retain their cell-ending paragraph delimiter.
        if output.length > 0, case .table = document.blocks.last {
            return output
        }
        if output.length > 0 { output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1)) }
        return output
    }
}
