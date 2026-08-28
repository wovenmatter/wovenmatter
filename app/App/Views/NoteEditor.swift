import AppKit
import Observation
import SwiftUI
import WovenMatterCore

private extension NSAttributedString.Key {
    static let noteBlockID = Self("wovenmatter.note.block-id")
    static let noteBlockStyle = Self("wovenmatter.note.block-style")
    static let noteTableID = Self("wovenmatter.note.table-id")
    static let noteRowID = Self("wovenmatter.note.row-id")
    static let noteColumnID = Self("wovenmatter.note.column-id")
    static let noteCellID = Self("wovenmatter.note.cell-id")
}

@MainActor
@Observable
final class DashboardNoteEditorController {
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored private var document = NoteDocument()
    @ObservationIgnored private var onChange: ((NoteDocument) -> Void)?

    func bind(
        textView: NSTextView,
        document: NoteDocument,
        onChange: @escaping (NoteDocument) -> Void
    ) {
        self.textView = textView
        self.document = document
        self.onChange = onChange
    }

    func adopt(_ document: NoteDocument) {
        self.document = document
    }

    func toggleBold() { toggleFontTrait(.boldFontMask) }
    func toggleItalic() { toggleFontTrait(.italicFontMask) }
    func toggleUnderline() { textView?.underline(nil) }

    func setFontFamily(_ family: String) {
        applyFont { font in
            NSFontManager.shared.convert(font, toFamily: family)
        }
    }

    func setFontSize(_ size: Double) {
        applyFont { font in
            NSFontManager.shared.convert(font, toSize: size)
        }
    }

    func setParagraphStyle(_ style: NoteParagraphStyle) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = paragraphRange(in: textView)
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(.noteBlockStyle, value: style.rawValue, range: range)
        storage.addAttribute(.paragraphStyle, value: paragraphStyle(for: style), range: range)
        if let headingSize = style.headingSize {
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
                let resized = NSFontManager.shared.convert(font, toSize: headingSize)
                let bold = NSFontManager.shared.convert(resized, toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: bold, range: subrange)
            }
        }
        storage.endEditing()
        textView.didChangeText()
    }

    func toggleHighlight(_ color: NSColor) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = editableRange(in: textView)
        if range.length == 0 {
            let isHighlighted = textView.typingAttributes[.backgroundColor] != nil
            applyAttribute(.backgroundColor, value: isHighlighted ? nil : color)
            return
        }

        var isFullyHighlighted = true
        storage.enumerateAttribute(.backgroundColor, in: range) { value, _, stop in
            guard value == nil else { return }
            isFullyHighlighted = false
            stop.pointee = true
        }
        applyAttribute(.backgroundColor, value: isFullyHighlighted ? nil : color)
    }

    func recolorSelectedHighlights(_ color: NSColor) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = editableRange(in: textView)
        guard range.length > 0 else { return }

        var highlightedRanges: [NSRange] = []
        storage.enumerateAttribute(.backgroundColor, in: range) { value, subrange, _ in
            if value != nil { highlightedRanges.append(subrange) }
        }
        guard !highlightedRanges.isEmpty,
              textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        for highlightedRange in highlightedRanges {
            storage.addAttribute(.backgroundColor, value: color, range: highlightedRange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    func setLink(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        applyAttribute(.link, value: trimmed.flatMap(URL.init(string:)))
    }

    func insertTable(rows: Int = 3, columns: Int = 3) {
        let table = NoteTableBlock(rows: rows, columns: columns, headerRow: true)
        var updated = document
        let selectedID = selectedStringAttribute(.noteBlockID)
        let insertion = selectedID.flatMap { id in
            updated.blocks.firstIndex { $0.id == id }.map { $0 + 1 }
        } ?? updated.blocks.endIndex
        updated.blocks.insert(.table(table), at: insertion)
        replaceDocument(updated, selecting: table.rows[0].cells[0].id, action: "Insert Table")
    }

    func addTableRow() {
        mutateSelectedTable(action: "Add Table Row") { table, rowID, _ in
            let index = rowID.flatMap { id in table.rows.firstIndex { $0.id == id } }
                .map { $0 + 1 } ?? table.rows.count
            table.rows.insert(NoteTableRow(cellCount: table.columns.count), at: index)
        }
    }

    func removeTableRow() {
        mutateSelectedTable(action: "Remove Table Row") { table, rowID, _ in
            guard table.rows.count > 1,
                  let rowID,
                  let index = table.rows.firstIndex(where: { $0.id == rowID }) else { return }
            table.rows.remove(at: index)
            table.headerRowCount = min(table.headerRowCount, table.rows.count)
        }
    }

    func addTableColumn() {
        mutateSelectedTable(action: "Add Table Column") { table, _, columnID in
            let index = columnID.flatMap { id in table.columns.firstIndex { $0.id == id } }
                .map { $0 + 1 } ?? table.columns.count
            table.columns.insert(NoteTableColumn(), at: index)
            for rowIndex in table.rows.indices {
                table.rows[rowIndex].cells.insert(NoteTableCell(), at: index)
            }
        }
    }

    func removeTableColumn() {
        mutateSelectedTable(action: "Remove Table Column") { table, _, columnID in
            guard table.columns.count > 1,
                  let columnID,
                  let index = table.columns.firstIndex(where: { $0.id == columnID }) else { return }
            table.columns.remove(at: index)
            for rowIndex in table.rows.indices {
                table.rows[rowIndex].cells.remove(at: index)
            }
        }
    }

    func deleteTable() {
        guard let tableID = selectedStringAttribute(.noteTableID) else { return }
        var updated = document
        updated.blocks.removeAll { block in
            guard case .table(let table) = block else { return false }
            return table.id == tableID
        }
        replaceDocument(updated, action: "Delete Table")
    }

    private func applyFont(_ transform: (NSFont) -> NSFont) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = editableRange(in: textView)
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        if range.length == 0 {
            let font = (textView.typingAttributes[.font] as? NSFont)
                ?? NSFont.systemFont(ofSize: 14)
            textView.typingAttributes[.font] = transform(font)
        } else {
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                storage.addAttribute(
                    .font,
                    value: transform((value as? NSFont) ?? NSFont.systemFont(ofSize: 14)),
                    range: subrange
                )
            }
            textView.didChangeText()
        }
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        applyFont { font in
            let manager = NSFontManager.shared
            return manager.traits(of: font).contains(trait)
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
        }
    }

    private func applyAttribute(_ key: NSAttributedString.Key, value: Any?) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = editableRange(in: textView)
        if range.length == 0 {
            if let value { textView.typingAttributes[key] = value }
            else { textView.typingAttributes.removeValue(forKey: key) }
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        if let value { storage.addAttribute(key, value: value, range: range) }
        else { storage.removeAttribute(key, range: range) }
        textView.didChangeText()
    }

    private func editableRange(in textView: NSTextView) -> NSRange {
        let range = textView.selectedRange()
        return range.location == NSNotFound ? NSRange(location: 0, length: 0) : range
    }

    private func paragraphRange(in textView: NSTextView) -> NSRange {
        (textView.string as NSString).paragraphRange(for: editableRange(in: textView))
    }

    private func selectedStringAttribute(_ key: NSAttributedString.Key) -> String? {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return nil }
        let location = min(textView.selectedRange().location, storage.length - 1)
        return storage.attribute(key, at: location, effectiveRange: nil) as? String
    }

    private func mutateSelectedTable(
        action: String,
        mutation: (inout NoteTableBlock, String?, String?) -> Void
    ) {
        guard let tableID = selectedStringAttribute(.noteTableID) else { return }
        let rowID = selectedStringAttribute(.noteRowID)
        let columnID = selectedStringAttribute(.noteColumnID)
        var updated = document
        guard let index = updated.blocks.firstIndex(where: { $0.id == tableID }),
              case .table(var table) = updated.blocks[index] else { return }
        mutation(&table, rowID, columnID)
        updated.blocks[index] = .table(table.normalized())
        replaceDocument(updated, selecting: selectedStringAttribute(.noteCellID), action: action)
    }

    fileprivate func replaceDocument(
        _ updated: NoteDocument,
        selecting cellID: String? = nil,
        action: String
    ) {
        guard let textView else { return }
        let previous = document
        textView.undoManager?.registerUndo(withTarget: self) { controller in
            controller.replaceDocument(previous, action: action)
        }
        textView.undoManager?.setActionName(action)
        document = updated.normalized()
        onChange?(document)
        textView.textStorage?.setAttributedString(NoteAttributedDocument.render(document))
        if let cellID, let range = textView.textStorage?.range(ofNoteAttribute: .noteCellID, value: cellID) {
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
    }
}

struct DashboardNoteEditor: NSViewRepresentable {
    @Binding var document: NoteDocument
    let controller: DashboardNoteEditorController

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.typingAttributes = NoteAttributedDocument.defaultAttributes
        textView.textStorage?.setAttributedString(NoteAttributedDocument.render(document))
        scrollView.documentView = textView
        context.coordinator.bind(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.bind(textView: textView, document: document) { updated in
            context.coordinator.emit(updated)
        }
        guard document != context.coordinator.lastDocument else { return }
        context.coordinator.apply(document, to: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DashboardNoteEditor
        var lastDocument: NoteDocument
        private var applying = false

        init(parent: DashboardNoteEditor) {
            self.parent = parent
            lastDocument = parent.document
        }

        func bind(_ textView: NSTextView) {
            parent.controller.bind(textView: textView, document: parent.document) { [weak self] in
                self?.emit($0)
            }
        }

        func apply(_ document: NoteDocument, to textView: NSTextView) {
            applying = true
            let previous = lastDocument
            textView.undoManager?.registerUndo(withTarget: parent.controller) { controller in
                controller.replaceDocument(previous, action: "Agent Edit")
            }
            textView.undoManager?.setActionName("Agent Edit")
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(NoteAttributedDocument.render(document))
            textView.setSelectedRange(NSRange(
                location: min(selection.location, textView.string.utf16.count),
                length: 0
            ))
            lastDocument = document
            parent.controller.adopt(document)
            applying = false
        }

        func emit(_ document: NoteDocument) {
            lastDocument = document
            parent.controller.adopt(document)
            parent.document = document
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let textView = notification.object as? NSTextView else { return }
            emit(NoteAttributedDocument.parse(textView.attributedString(), basedOn: lastDocument))
        }
    }
}

@MainActor
private enum NoteAttributedDocument {
    static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.labelColor,
    ]

    static func render(_ document: NoteDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for block in document.normalized().blocks {
            switch block {
            case .richText(let richText): append(richText, to: result)
            case .table(let table): append(table, to: result)
            }
        }
        return result
    }

    static func parse(_ attributed: NSAttributedString, basedOn source: NoteDocument) -> NoteDocument {
        let sourceTables: [String: NoteTableBlock] = Dictionary(
          uniqueKeysWithValues: source.blocks.compactMap { block -> (String, NoteTableBlock)? in
            guard case .table(let table) = block else { return nil }
            return (table.id, table)
          }
        )
        var tables = sourceTables
        var emittedTables: Set<String> = []
        var seenBlockIDs: Set<String> = []
        var blocks: [NoteBlock] = []
        let string = attributed.string as NSString
        var location = 0

        while location < max(1, attributed.length) {
            let probe = min(location, max(0, attributed.length - 1))
            let paragraphRange = string.paragraphRange(for: NSRange(location: probe, length: 0))
            let contentRange = NSRange(
                location: paragraphRange.location,
                length: max(0, paragraphRange.length - trailingNewlineLength(in: string, range: paragraphRange))
            )
            let attributes = attributed.length > 0
                ? attributed.attributes(at: probe, effectiveRange: nil)
                : defaultAttributes

            if let tableID = attributes[.noteTableID] as? String,
               var table = tables[tableID] {
                if let rowID = attributes[.noteRowID] as? String,
                   let columnID = attributes[.noteColumnID] as? String,
                   let row = table.rows.firstIndex(where: { $0.id == rowID }),
                   let column = table.columns.firstIndex(where: { $0.id == columnID }) {
                    table.rows[row].cells[column].runs = runs(in: attributed, range: contentRange)
                    table.rows[row].cells[column].backgroundHex = colorHex(
                        attributes[.backgroundColor] as? NSColor
                    )
                    tables[tableID] = table
                }
                if emittedTables.insert(tableID).inserted { blocks.append(.table(table)) }
            } else {
                let proposedID = attributes[.noteBlockID] as? String
                let blockID = proposedID.flatMap { seenBlockIDs.insert($0).inserted ? $0 : nil }
                    ?? UUID().uuidString.lowercased()
                let rawStyle = attributes[.noteBlockStyle] as? String
                let style = rawStyle.flatMap(NoteParagraphStyle.init(rawValue:)) ?? .paragraph
                blocks.append(.richText(NoteRichTextBlock(
                    id: blockID,
                    style: style,
                    runs: runs(in: attributed, range: contentRange)
                )))
            }
            guard paragraphRange.length > 0 else { break }
            location = NSMaxRange(paragraphRange)
        }

        blocks = blocks.map { block in
            guard case .table(let table) = block, let updated = tables[table.id] else { return block }
            return .table(updated)
        }
        return NoteDocument(blocks: blocks).normalized()
    }

    private static func append(_ block: NoteRichTextBlock, to result: NSMutableAttributedString) {
        let paragraph = paragraphStyle(for: block.style)
        let base: [NSAttributedString.Key: Any] = [
            .noteBlockID: block.id,
            .noteBlockStyle: block.style.rawValue,
            .paragraphStyle: paragraph,
        ]
        if block.runs.isEmpty {
            result.append(NSAttributedString(string: "\n", attributes: base.merging(defaultAttributes) { first, _ in first }))
            return
        }
        for run in block.runs {
            result.append(NSAttributedString(string: run.text, attributes: attributes(for: run, style: block.style).merging(base) { first, _ in first }))
        }
        result.append(NSAttributedString(string: "\n", attributes: base.merging(defaultAttributes) { first, _ in first }))
    }

    private static func append(_ table: NoteTableBlock, to result: NSMutableAttributedString) {
        let native = NSTextTable()
        native.numberOfColumns = table.columns.count
        native.collapsesBorders = true
        native.hidesEmptyCells = false
        for (rowIndex, row) in table.rows.enumerated() {
            for (columnIndex, cell) in row.cells.enumerated() {
                let cellBlock = NSTextTableBlock(
                    table: native,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
                cellBlock.setBorderColor(.separatorColor)
                cellBlock.setWidth(7, type: .absoluteValueType, for: .padding)
                cellBlock.backgroundColor = color(from: cell.backgroundHex)
                    ?? (rowIndex < table.headerRowCount ? .controlBackgroundColor : .clear)
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [cellBlock]
                paragraph.paragraphSpacing = 0
                let base: [NSAttributedString.Key: Any] = [
                    .noteTableID: table.id,
                    .noteRowID: row.id,
                    .noteColumnID: table.columns[columnIndex].id,
                    .noteCellID: cell.id,
                    .paragraphStyle: paragraph,
                ]
                let runs = cell.runs.isEmpty ? [NoteTextRun(text: "\u{200B}")] : cell.runs
                for run in runs {
                    var attributes = attributes(for: run, style: .paragraph)
                    if rowIndex < table.headerRowCount {
                        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
                        attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    }
                    result.append(NSAttributedString(string: run.text, attributes: attributes.merging(base) { first, _ in first }))
                }
                result.append(NSAttributedString(string: "\n", attributes: base.merging(defaultAttributes) { first, _ in first }))
            }
        }
    }

    private static func attributes(
        for run: NoteTextRun,
        style: NoteParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        let size = run.fontSize ?? style.headingSize ?? 14
        var font = NSFont(name: run.fontFamily ?? "", size: size)
            ?? NSFont.systemFont(ofSize: size)
        if run.bold || style.headingSize != nil {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color(from: run.foregroundHex) ?? NSColor.labelColor,
        ]
        if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let color = color(from: run.highlightHex) { attributes[.backgroundColor] = color }
        if let link = run.link.flatMap(URL.init(string:)) { attributes[.link] = link }
        return attributes
    }

    private static func runs(in attributed: NSAttributedString, range: NSRange) -> [NoteTextRun] {
        guard range.length > 0 else { return [] }
        var result: [NoteTextRun] = []
        attributed.enumerateAttributes(in: range) { attributes, subrange, _ in
            let raw = (attributed.string as NSString).substring(with: subrange)
                .replacingOccurrences(of: "\u{200B}", with: "")
            guard !raw.isEmpty else { return }
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            let traits = NSFontManager.shared.traits(of: font)
            result.append(NoteTextRun(
                text: raw,
                fontFamily: font.familyName,
                fontSize: font.pointSize,
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask),
                underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                foregroundHex: colorHex(attributes[.foregroundColor] as? NSColor),
                highlightHex: colorHex(attributes[.backgroundColor] as? NSColor),
                link: (attributes[.link] as? URL)?.absoluteString
                    ?? attributes[.link] as? String
            ))
        }
        return result
    }

    private static func trailingNewlineLength(in string: NSString, range: NSRange) -> Int {
        guard range.length > 0 else { return 0 }
        let last = string.character(at: NSMaxRange(range) - 1)
        return last == 10 || last == 13 ? 1 : 0
    }
}

@MainActor
func dashboardRenderedNoteDocument(_ document: NoteDocument) -> NSAttributedString {
    NoteAttributedDocument.render(document)
}

@MainActor
func dashboardParsedNoteDocument(
    _ attributed: NSAttributedString,
    basedOn document: NoteDocument
) -> NoteDocument {
    NoteAttributedDocument.parse(attributed, basedOn: document)
}

private func paragraphStyle(for style: NoteParagraphStyle) -> NSParagraphStyle {
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = style.headingSize == nil ? 8 : 10
    switch style {
    case .bulletedList:
        paragraph.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        paragraph.headIndent = 22
        paragraph.firstLineHeadIndent = 6
    case .numberedList:
        paragraph.textLists = [NSTextList(markerFormat: .decimal, options: 0)]
        paragraph.headIndent = 28
        paragraph.firstLineHeadIndent = 6
    default:
        break
    }
    return paragraph
}

private extension NoteParagraphStyle {
    var headingSize: Double? {
        switch self {
        case .heading1: 30
        case .heading2: 25
        case .heading3: 21
        case .heading4: 18
        case .heading5: 16
        case .heading6: 14
        case .paragraph, .bulletedList, .numberedList: nil
        }
    }
}

private func color(from hex: String?) -> NSColor? {
    guard let hex else { return nil }
    let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    guard value.count == 6, let number = Int(value, radix: 16) else { return nil }
    return NSColor(
        red: CGFloat((number >> 16) & 0xff) / 255,
        green: CGFloat((number >> 8) & 0xff) / 255,
        blue: CGFloat(number & 0xff) / 255,
        alpha: 1
    )
}

private func colorHex(_ color: NSColor?) -> String? {
    guard let color = color?.usingColorSpace(.sRGB) else { return nil }
    return String(
        format: "#%02X%02X%02X",
        Int(round(color.redComponent * 255)),
        Int(round(color.greenComponent * 255)),
        Int(round(color.blueComponent * 255))
    )
}

private extension NSTextStorage {
    func range(ofNoteAttribute key: NSAttributedString.Key, value: String) -> NSRange? {
        var result: NSRange?
        enumerateAttribute(key, in: NSRange(location: 0, length: length)) { candidate, range, stop in
            guard candidate as? String == value else { return }
            result = range
            stop.pointee = true
        }
        return result
    }
}

struct DashboardNoteFormattingBar: View {
    let controller: DashboardNoteEditorController
    @State private var fontFamily = "System"
    @State private var fontSize = 14.0
    @State private var link = ""
    @State private var highlightColor = DashboardNoteHighlightColor.yellow
    @State private var showsLinkEditor = false

    private let fontFamilies = ["System", "Helvetica Neue", "Avenir Next", "Georgia", "Menlo"]
    private let fontSizes = [11.0, 12, 13, 14, 16, 18, 21, 24, 30, 36]

    var body: some View {
        DashboardNoteFormattingFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            Menu {
                ForEach(fontFamilies, id: \.self) { family in
                    Button(family) {
                        fontFamily = family
                        controller.setFontFamily(
                            family == "System"
                                ? NSFont.systemFont(ofSize: 14).familyName ?? ".AppleSystemUIFont"
                                : family
                        )
                    }
                }
            } label: {
                DashboardNoteFormattingLabel(
                    title: fontFamily,
                    accessibilityLabel: "Font"
                )
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(DashboardNoteFormattingButtonStyle())
            .fixedSize()
            .help("Font")

            Menu {
                ForEach(fontSizes, id: \.self) { size in
                    Button("\(Int(size)) pt") {
                        fontSize = size
                        controller.setFontSize(size)
                    }
                }
            } label: {
                DashboardNoteFormattingLabel(
                    title: "\(Int(fontSize))",
                    accessibilityLabel: "Font size"
                )
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(DashboardNoteFormattingButtonStyle())
            .fixedSize()
            .help("Font size")

            formatButton("bold", help: "Bold", action: controller.toggleBold)
            formatButton("underline", help: "Underline", action: controller.toggleUnderline)
            formatButton("italic", help: "Italic", action: controller.toggleItalic)

            formatButton("highlighter", help: "Toggle highlight") {
                controller.toggleHighlight(highlightColor.nsColor)
            }

            DashboardNoteHighlightColorControl(
                color: $highlightColor,
                apply: controller.recolorSelectedHighlights
            )

            Menu {
                Button("Bulleted list", systemImage: "list.bullet") {
                    controller.setParagraphStyle(.bulletedList)
                }
                Button("Numbered list", systemImage: "list.number") {
                    controller.setParagraphStyle(.numberedList)
                }
            } label: {
                DashboardNoteFormattingLabel(
                    systemName: "list.bullet",
                    accessibilityLabel: "Lists"
                )
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(DashboardNoteFormattingButtonStyle())
            .fixedSize()
            .help("Lists")

            Menu {
                Button("Body") { controller.setParagraphStyle(.paragraph) }
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") {
                        controller.setParagraphStyle(NoteParagraphStyle.allCases[level])
                    }
                }
            } label: {
                DashboardNoteFormattingLabel(
                    systemName: "paragraphsign",
                    accessibilityLabel: "Heading and style"
                )
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(DashboardNoteFormattingButtonStyle())
            .fixedSize()
            .help("Heading and style")

            formatButton("link", help: "Link") {
                showsLinkEditor.toggle()
            }

            if showsLinkEditor {
                HStack(spacing: 4) {
                    TextField("https://…", text: $link)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                        .onSubmit { controller.setLink(link) }
                    Button("Apply") { controller.setLink(link) }
                        .buttonStyle(.plain)
                    Button("Remove") {
                        controller.setLink(nil)
                        link = ""
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 12))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(DashboardPalette.background.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Menu {
                Button("Insert 3 × 3 Table", systemImage: "tablecells") {
                    controller.insertTable()
                }
                Divider()
                Button("Add Row") { controller.addTableRow() }
                Button("Remove Row") { controller.removeTableRow() }
                Divider()
                Button("Add Column") { controller.addTableColumn() }
                Button("Remove Column") { controller.removeTableColumn() }
                Divider()
                Button("Delete Table", role: .destructive) { controller.deleteTable() }
            } label: {
                DashboardNoteFormattingLabel(
                    systemName: "tablecells",
                    accessibilityLabel: "Tables"
                )
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(DashboardNoteFormattingButtonStyle())
            .fixedSize()
            .help("Tables")
        }
    }

    private func formatButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            DashboardNoteFormattingLabel(
                systemName: systemName,
                accessibilityLabel: help
            )
        }
        .buttonStyle(DashboardNoteFormattingButtonStyle())
        .help(help)
    }
}

private enum DashboardNoteHighlightColor: String, CaseIterable, Identifiable {
    case yellow
    case green

    var id: Self { self }

    var title: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .yellow:
            NSColor(srgbRed: 1, green: 0.915, blue: 0.58, alpha: 1)
        case .green:
            NSColor(srgbRed: 0.78, green: 0.84, blue: 0.81, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

private struct DashboardNoteHighlightColorControl: View {
    @Binding var color: DashboardNoteHighlightColor
    let apply: (NSColor) -> Void

    var body: some View {
        Menu {
            ForEach(DashboardNoteHighlightColor.allCases) { option in
                Button {
                    apply(option.nsColor)
                    color = option
                } label: {
                    Label(
                        option.title,
                        systemImage: option == color ? "checkmark" : "circle"
                    )
                }
            }
        } label: {
            Circle()
                .fill(color.color)
                .overlay {
                    Circle().stroke(DashboardPalette.mutedForeground.opacity(0.28), lineWidth: 1)
                }
                .frame(width: 14, height: 14)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .contentShape(Rectangle())
                .accessibilityLabel("Highlight color")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(DashboardNoteFormattingButtonStyle())
        .fixedSize()
        .help("Highlight color")
    }
}

private struct DashboardNoteFormattingLabel: View {
    var title: String?
    let systemName: String?
    let accessibilityLabel: String

    init(
        title: String? = nil,
        systemName: String? = nil,
        accessibilityLabel: String
    ) {
        self.title = title
        self.systemName = systemName
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .medium))
            }
            if let title {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(DashboardPalette.mutedForeground)
        .padding(.horizontal, title == nil ? 8 : 9)
        .frame(height: 32)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct DashboardNoteFormattingButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || hovered ? theme.palette.themeSoft : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}

private struct DashboardNoteFormattingFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let result = layout(subviews: subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? result.width, height: result.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func layout(subviews: Subviews, width: CGFloat) -> CGSize {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            contentWidth = max(contentWidth, x + size.width)
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: contentWidth, height: y + lineHeight)
    }
}
