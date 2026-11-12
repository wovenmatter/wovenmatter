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
    static let noteDatabaseLink = Self("wovenmatter.note.database-link")
    static let noteDatabaseValueID = Self("wovenmatter.note.database-value-id")
    static let notePageItem = Self("wovenmatter.note.page-item")
    static let notePageItemID = Self("wovenmatter.note.page-item-id")
    static let noteTableDefinition = Self("wovenmatter.note.table-definition")
}

struct DashboardNoteTextStatistics: Equatable {
    let words: Int
    let characters: Int

    init(document: NoteDocument) {
        let text = document.plainText
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        self.words = words
        characters = text.count
    }
}

@MainActor
@Observable
final class DashboardNoteEditorController {
    @ObservationIgnored weak var textView: NSTextView?
    @ObservationIgnored weak var boundDictationEditor: DictationEditor?
    @ObservationIgnored private var document = NoteDocument()
    @ObservationIgnored private var onChange: ((NoteDocument) -> Void)?
    @ObservationIgnored private var documentText: NSAttributedString?
    @ObservationIgnored private var undoObservers: [NSObjectProtocol] = []
    private(set) var canUndo = false
    private(set) var canRedo = false

    isolated deinit {
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func bind(
        textView: NSTextView,
        document: NoteDocument,
        onChange: @escaping (NoteDocument) -> Void
    ) {
        if self.textView !== textView {
            removeUndoObservers()
            self.textView = textView
            if let manager = textView.undoManager {
                for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup,
                             Notification.Name.NSUndoManagerDidUndoChange,
                             Notification.Name.NSUndoManagerDidRedoChange,
                             Notification.Name.NSUndoManagerCheckpoint] {
                    undoObservers.append(NotificationCenter.default.addObserver(
                        forName: name, object: manager, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated {
                            if name == .NSUndoManagerDidUndoChange || name == .NSUndoManagerDidRedoChange {
                                self?.didUndoOrRedo()
                            } else {
                                self?.refreshUndoState()
                            }
                        }
                    })
                }
            }
        }
        self.document = document
        documentText = NSAttributedString(attributedString: textView.attributedString())
        self.onChange = onChange
        refreshUndoState()
    }

    func unbind(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        removeUndoObservers()
        if let manager = textView.undoManager {
            if (textView as? NoteTextView)?.sharedUndoManager === manager {
                // Page flows share one history. Closing one flow, such as by
                // collapsing its section, keeps the other flows' undo.
                manager.removeAllActions(withTarget: textView)
                textView.textStorage.map { manager.removeAllActions(withTarget: $0) }
                manager.removeAllActions(withTarget: self)
            } else {
                manager.removeAllActions()
            }
        }
        self.textView = nil
        documentText = nil
        onChange = nil
        refreshUndoState()
    }

    private func removeUndoObservers() {
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        undoObservers.removeAll()
    }

    func refreshUndoState() {
        canUndo = textView?.isEditable == true && textView?.undoManager?.canUndo == true
        canRedo = textView?.isEditable == true && textView?.undoManager?.canRedo == true
    }

    private func didUndoOrRedo() {
        // Native undo can restore text storage before its text-change delegate
        // notification arrives. Publish the restored content for saving/counts,
        // including undo invoked through the standard Edit menu or keyboard.
        // Compare with the actual synchronized storage. Rendering a fresh copy
        // creates different native list objects, even for an unchanged snapshot.
        if let textView,
           documentText.map({ !textView.attributedString().isEqual(to: $0) }) ?? true {
            let updated = NoteAttributedDocument.parse(textView.attributedString(), basedOn: document)
            if updated != document {
                document = updated
                onChange?(updated)
            }
        }
        refreshUndoState()
    }

    func undo() {
        guard let textView, textView.isEditable, let manager = textView.undoManager,
              manager.canUndo else { return }
        textView.window?.makeFirstResponder(textView)
        textView.breakUndoCoalescing()
        manager.undo()
        refreshUndoState()
    }

    func redo() {
        guard let textView, textView.isEditable, let manager = textView.undoManager,
              manager.canRedo else { return }
        textView.window?.makeFirstResponder(textView)
        textView.breakUndoCoalescing()
        manager.redo()
        refreshUndoState()
    }

    func adopt(_ document: NoteDocument) {
        self.document = document
        documentText = textView.map { NSAttributedString(attributedString: $0.attributedString()) }
        refreshUndoState()
    }

    func toggleBold() { toggleFontTrait(.boldFontMask) }
    func toggleItalic() { toggleFontTrait(.italicFontMask) }
    func toggleUnderline() { textView?.underline(nil) }

    var selectedBlockID: String? {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return nil }
        let attributes = storage.attributes(at: min(textView.selectedRange().location, storage.length - 1), effectiveRange: nil)
        return attributes[.noteBlockID] as? String ?? attributes[.noteTableID] as? String
    }

    func focus(blockID: String? = nil, atEnd: Bool = false) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        if let blockID, let storage = textView.textStorage {
            var target: NSRange?
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, stop in
                if (attributes[.noteBlockID] as? String ?? attributes[.noteTableID] as? String) == blockID {
                    if let previous = target { target = NSUnionRange(previous, range) } else { target = range }
                } else if target != nil { stop.pointee = true }
            }
            if let target {
                let location = atEnd ? max(target.location, NSMaxRange(target) - 1) : target.location
                textView.setSelectedRange(NSRange(location: location, length: 0))
                textView.scrollRangeToVisible(textView.selectedRange())
                return
            }
        }
        if atEnd { textView.setSelectedRange(NSRange(location: max(0, textView.string.utf16.count - 1), length: 0)) }
    }

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

    func setParagraphStyle(_ style: NoteParagraphStyle, blockID: String? = nil) {
        guard let textView, textView.isEditable, let storage = textView.textStorage else { return }
        performEdit(action: "Paragraph Style") {
            let selection = editableRange(in: textView)
            var range = paragraphRange(in: textView)
            let paragraph = paragraphStyle(for: style, list: adjacentList(for: style, range: range, in: storage))
            guard textView.shouldChangeText(in: range, replacementString: range.length == 0 ? "\n" : nil) else { return }
            storage.beginEditing()
            // An attributed newline gives an empty item a paragraph of its own,
            // including when the caret is past the document's final newline.
            if range.length == 0 {
                var attributes = textView.typingAttributes
                for key in [NSAttributedString.Key.noteTableID, .noteRowID, .noteColumnID, .noteCellID, .noteTableDefinition] {
                    attributes.removeValue(forKey: key)
                }
                attributes[.noteBlockID] = UUID().uuidString.lowercased()
                storage.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: attributes))
                range.length = 1
            }
            if let blockID { storage.addAttribute(.noteBlockID, value: blockID, range: range) }
            storage.addAttribute(.noteBlockStyle, value: style.rawValue, range: range)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            if style.isList {
                // A converted paragraph can bridge two previously separate lists.
                // Share one native list across the entire contiguous style run so
                // numbering matches the saved document before it is reopened.
                var listRange = range
                _ = storage.attribute(
                    .noteBlockStyle, at: range.location,
                    longestEffectiveRange: &listRange,
                    in: NSRange(location: 0, length: storage.length)
                )
                storage.enumerateAttribute(.paragraphStyle, in: listRange) { value, subrange, _ in
                    guard let existing = value as? NSParagraphStyle,
                          existing.textLists.first !== paragraph.textLists.first,
                          let joined = existing.mutableCopy() as? NSMutableParagraphStyle else { return }
                    joined.textLists = paragraph.textLists
                    storage.addAttribute(.paragraphStyle, value: joined, range: subrange)
                }
            }
            if let headingSize = style.headingSize {
                storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
                    let resized = NSFontManager.shared.convert(font, toSize: headingSize)
                    let bold = NSFontManager.shared.convert(resized, toHaveTrait: .boldFontMask)
                    storage.addAttribute(.font, value: bold, range: subrange)
                }
            }
            storage.endEditing()
            textView.setSelectedRange(selection)
            textView.window?.makeFirstResponder(textView)
            textView.typingAttributes[.noteBlockID] = storage.attribute(.noteBlockID, at: range.location, effectiveRange: nil)
            textView.typingAttributes[.noteBlockStyle] = style.rawValue
            textView.typingAttributes[.paragraphStyle] = paragraph
            textView.didChangeText()
        }
    }

    private func adjacentList(for style: NoteParagraphStyle, range: NSRange, in storage: NSTextStorage) -> NSTextList? {
        guard style.isList else { return nil }
        for location in [range.location, range.location - 1, NSMaxRange(range)] where location >= 0 && location < storage.length {
            let attributes = storage.attributes(at: location, effectiveRange: nil)
            if attributes[.noteBlockStyle] as? String == style.rawValue,
               let list = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textLists.first {
                return list
            }
        }
        return nil
    }

    // Keep structural list edits and their typing state together in undo/redo.
    // Native text insertion alone does not restore the custom block attributes.
    fileprivate func performEdit(action: String, _ edit: () -> Void) {
        guard let textView, let storage = textView.textStorage else { return }
        let previous = NSAttributedString(attributedString: storage)
        let selection = textView.selectedRange()
        let typing = textView.typingAttributes
        let undo = textView.undoManager
        undo?.disableUndoRegistration()
        edit()
        undo?.enableUndoRegistration()
        guard !storage.isEqual(to: previous) else { return }
        undo?.registerUndo(withTarget: self) { controller in
            controller.performEdit(action: action) {
                guard let textView = controller.textView else { return }
                textView.textStorage?.setAttributedString(previous)
                textView.setSelectedRange(selection)
                textView.typingAttributes = typing
                textView.didChangeText()
            }
        }
        undo?.setActionName(action)
        refreshUndoState()
    }

    func toggleHighlight(_ color: NSColor) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = editableRange(in: textView)
        if range.length == 0 {
            let isHighlighted = textView.typingAttributes[.backgroundColor] != nil
            applyAttribute(.backgroundColor, value: isHighlighted ? nil : DashboardColors.noteBackground(color))
            return
        }

        var isFullyHighlighted = true
        storage.enumerateAttribute(.backgroundColor, in: range) { value, _, stop in
            guard value == nil else { return }
            isFullyHighlighted = false
            stop.pointee = true
        }
        applyAttribute(.backgroundColor, value: isFullyHighlighted ? nil : DashboardColors.noteBackground(color))
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
            storage.addAttribute(.backgroundColor, value: DashboardColors.noteBackground(color), range: highlightedRange)
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
        textView.textStorage?.setAttributedString(NoteAttributedDocument.render(document))
        documentText = NSAttributedString(attributedString: textView.attributedString())
        onChange?(document)
        textView.needsDisplay = true
        textView.checkText(in: NSRange(location: 0, length: textView.string.utf16.count),
                           types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:])
        refreshUndoState()
        if let cellID, let range = textView.textStorage?.range(ofNoteAttribute: .noteCellID, value: cellID) {
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
    }
}

struct DashboardNoteEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Binding var document: NoteDocument
    let controller: DashboardNoteEditorController
    var dictationEditor: DictationEditor? = nil
    var dictationIdentity = ""
    /// Layout only: grow to the text's height and pass scrolling to the parent.
    var sizesToContent = false
    /// Page flow editing: task metadata and checkboxes, one component per
    /// paragraph on Enter, and undo fenced at incoming changes. Only Page text
    /// flows set this; an embedded original Note keeps ordinary Notes editing.
    var editsPageFlow = false
    var onFocus: ((DashboardNoteEditorController) -> Void)?
    var onSynchronize: (() -> Void)?
    var sharedUndoManager: UndoManager?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NoteDocumentScrollView()
        scrollView.passesScrollingToParent = sizesToContent
        scrollView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = NoteTextView(usingTextLayoutManager: true)
        textView.sharedUndoManager = sharedUndoManager
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = true
        textView.isEditable = isEnabled
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: editsPageFlow ? 24 : 0, height: 8)
        textView.showsPageTasks = editsPageFlow
        textView.onToggleTask = { [weak coordinator = context.coordinator] id in coordinator?.toggleTask(id) }
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.typingAttributes = NoteAttributedDocument.defaultAttributes
        textView.textStorage?.setAttributedString(NoteAttributedDocument.render(document))
        scrollView.documentView = textView
        context.coordinator.bind(textView)
        controller.boundDictationEditor = dictationEditor
        textView.checkText(in: NSRange(location: 0, length: textView.string.utf16.count),
                           types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:])
        dictationEditor?.bind(textView, identity: dictationIdentity)
        return scrollView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // Measure with TextKit 2. Reading `layoutManager` would permanently
        // switch the view to TextKit 1 and stop the highlight drawing.
        guard sizesToContent, let textView = nsView.documentView as? NSTextView,
              let container = textView.textContainer, let manager = textView.textLayoutManager else { return nil }
        let width = max(80, proposal.width ?? max(80, nsView.frame.width))
        textView.setFrameSize(NSSize(width: width, height: max(40, textView.frame.height)))
        container.containerSize = NSSize(width: max(20, width - textView.textContainerInset.width * 2),
                                         height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: manager.documentRange)
        return CGSize(width: width, height: max(40, ceil(manager.usageBoundsForTextContainer.maxY + textView.textContainerInset.height * 2)))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if scrollView.appearance?.name != appearanceName {
            scrollView.appearance = NSAppearance(named: appearanceName)
            scrollView.documentView?.needsDisplay = true
        }
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEnabled
        dictationEditor?.bind(textView, identity: dictationIdentity)
        controller.bind(textView: textView, document: document) { updated in
            context.coordinator.emit(updated)
        }
        controller.boundDictationEditor = dictationEditor
        guard document != context.coordinator.lastDocument else { return }
        context.coordinator.apply(document, to: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? NSTextView {
            coordinator.parent.controller.unbind(textView)
            textView.delegate = nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DashboardNoteEditor
        var lastDocument: NoteDocument
        private var applying = false
        private var synchronizedText: NSAttributedString?

        init(parent: DashboardNoteEditor) {
            self.parent = parent
            lastDocument = parent.document
        }

        func bind(_ textView: NSTextView) {
            parent.controller.bind(textView: textView, document: parent.document) { [weak self] in
                self?.emit($0)
            }
            restoreTypingAttributes(in: textView)
            synchronizedText = NSAttributedString(attributedString: textView.attributedString())
            parent.onSynchronize?()
        }

        func apply(_ document: NoteDocument, to textView: NSTextView) {
            if parent.editsPageFlow, document != lastDocument, Self.flowText(lastDocument) == Self.flowText(document) {
                // Only Component details changed. The text is unchanged, so keep
                // its undo history and refresh the stored task metadata in place.
                applying = true
                synchronizePageAttributes(document, in: textView)
                lastDocument = document
                parent.controller.adopt(document)
                synchronizedText = NSAttributedString(attributedString: textView.attributedString())
                applying = false
                return
            }
            applying = true
            let previous = lastDocument
            if parent.editsPageFlow {
                // A focused Page flow must never undo a snapshot over incoming
                // agent/component work. Native typing keeps its ordinary undo.
                textView.undoManager?.removeAllActions()
            } else {
                textView.undoManager?.registerUndo(withTarget: parent.controller) { controller in
                    controller.replaceDocument(previous, action: "Agent Edit")
                }
                textView.undoManager?.setActionName("Agent Edit")
            }
            let rendered = NoteAttributedDocument.render(document)
            let selection = NoteAttributedDocument.selectionAfterRefreshingValues(
                textView.selectedRange(), from: textView.attributedString(), to: rendered
            )
            textView.textStorage?.setAttributedString(rendered)
            textView.needsDisplay = true
            textView.setSelectedRange(selection)
            restoreTypingAttributes(in: textView)
            lastDocument = document
            parent.controller.adopt(document)
            synchronizedText = NSAttributedString(attributedString: textView.attributedString())
            textView.checkText(in: NSRange(location: 0, length: textView.string.utf16.count),
                               types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:])
            applying = false
            parent.onSynchronize?()
        }

        /// What a Page flow shows: its blocks and each task's checkbox. Other
        /// fields belong to Component details and never change the text.
        private static func flowText(_ document: NoteDocument) -> NoteDocument {
            var value = document
            let items = (document.boardItems ?? [:])
                .mapValues { BoardItem(task: $0.task.map { BoardTask(status: $0.status) }) }
                .filter { $0.value != BoardItem() }
            value.boardItems = items.isEmpty ? nil : items
            return value
        }

        func emit(_ proposed: NoteDocument) {
            var document = proposed
            if parent.editsPageFlow, let before = synchronizedText, let view = parent.controller.textView {
                let after = view.attributedString()
                let originals = Dictionary(lastDocument.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for index in document.blocks.indices {
                    let block = document.blocks[index]
                    guard let original = originals[block.id],
                          let oldRange = range(of: original, in: before), let newRange = range(of: block, in: after) else { continue }
                    let oldText = NSMutableAttributedString(attributedString: before.attributedSubstring(from: oldRange))
                    let newText = NSMutableAttributedString(attributedString: after.attributedSubstring(from: newRange))
                    oldText.removeAttribute(.notePageItem, range: NSRange(location: 0, length: oldText.length))
                    newText.removeAttribute(.notePageItem, range: NSRange(location: 0, length: newText.length))
                    // Parsing adds explicit native defaults. An untouched block
                    // must keep its exact original runs, or an unrelated agent
                    // edit can look like a conflicting local formatting change.
                    if oldText.isEqual(to: newText) { document.blocks[index] = original }
                }
                synchronizePageAttributes(document, in: view)
                synchronizedText = NSAttributedString(attributedString: view.attributedString())
            }
            lastDocument = document
            parent.controller.adopt(document)
            parent.document = document
        }

        private func range(of block: NoteBlock, in text: NSAttributedString) -> NSRange? {
            let key: NSAttributedString.Key
            if case .table = block { key = .noteTableID } else { key = .noteBlockID }
            var found: NSRange?
            text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard value as? String == block.id else { return }
                if let previous = found { found = NSUnionRange(previous, range) } else { found = range }
            }
            return found
        }

        private func synchronizePageAttributes(_ document: NoteDocument, in view: NSTextView) {
            guard let storage = view.textStorage, storage.length > 0 else { return }
            let string = storage.string as NSString
            var offset = 0, index = 0
            var tables = Set<String>()
            storage.beginEditing()
            while offset < storage.length {
                let range = string.paragraphRange(for: NSRange(location: offset, length: 0))
                let attributes = storage.attributes(at: offset, effectiveRange: nil)
                let block: NoteBlock
                if let tableID = attributes[.noteTableID] as? String {
                    guard let table = document.blocks.first(where: { $0.id == tableID }) else { break }
                    block = table
                    if tables.insert(tableID).inserted { index += 1 }
                } else {
                    guard index < document.blocks.count else { break }
                    block = document.blocks[index]
                    index += 1
                    storage.addAttribute(.noteBlockID, value: block.id, range: range)
                }
                if let item = document.boardItems?[block.id], let encoded = try? JSONEncoder().encode(item) {
                    storage.addAttributes([.notePageItem: encoded, .notePageItemID: block.id], range: range)
                } else {
                    storage.removeAttribute(.notePageItem, range: range)
                    storage.removeAttribute(.notePageItemID, range: range)
                }
                if case .table(let table) = block, let encoded = try? JSONEncoder().encode(table) {
                    storage.addAttribute(.noteTableDefinition, value: encoded, range: range)
                }
                guard range.length > 0 else { break }
                offset = NSMaxRange(range)
            }
            storage.endEditing()
            restoreTypingAttributes(in: view)
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let textView = notification.object as? NSTextView else { return }
            emit(NoteAttributedDocument.parse(textView.attributedString(), basedOn: lastDocument))
        }

        func toggleTask(_ id: String) {
            guard parent.editsPageFlow, let textView = parent.controller.textView, textView.isEditable,
                  let storage = textView.textStorage else { return }
            parent.controller.performEdit(action: "Toggle Task") {
                var changes: [(NSRange, Data)] = []
                storage.enumerateAttribute(.notePageItem, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    let attributes = storage.attributes(at: range.location, effectiveRange: nil)
                    guard (attributes[.noteBlockID] as? String ?? attributes[.noteTableID] as? String) == id,
                          let data = value as? Data, var item = try? JSONDecoder().decode(BoardItem.self, from: data),
                          item.task != nil else { return }
                    let nextStatus: BoardTaskStatus = item.task?.status == .done ? .todo : .done
                    item.task?.status = nextStatus
                    if let encoded = try? JSONEncoder().encode(item) { changes.append((range, encoded)) }
                }
                for (range, data) in changes { storage.addAttribute(.notePageItem, value: data, range: range) }
                textView.didChangeText()
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard !applying, textView.isEditable, !textView.hasMarkedText(), let replacementString else { return true }
            let string = textView.string as NSString
            // Direct text edits detach that value, while native formatting keeps
            // its metadata. Undo restores the text and link together.
            if textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true,
               let storage = textView.textStorage {
                let touchedIDs = NoteAttributedDocument.valueIDs(touchedBy: range, in: storage)
                if !touchedIDs.isEmpty {
                    parent.controller.performEdit(action: "Edit Linked Value") {
                        applying = true
                        var linkedRanges: [NSRange] = []
                        storage.enumerateAttribute(.noteDatabaseValueID, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                            if let id = value as? String, touchedIDs.contains(id) { linkedRanges.append(range) }
                        }
                        for linkedRange in linkedRanges {
                            storage.removeAttribute(.noteDatabaseLink, range: linkedRange)
                            storage.removeAttribute(.noteDatabaseValueID, range: linkedRange)
                        }
                        textView.typingAttributes.removeValue(forKey: .noteDatabaseLink)
                        textView.typingAttributes.removeValue(forKey: .noteDatabaseValueID)
                        textView.insertText(replacementString, replacementRange: range)
                        applying = false
                        emit(NoteAttributedDocument.parse(textView.attributedString(), basedOn: lastDocument))
                    }
                    return false
                }
            }
            if replacementString.isEmpty, range == NSRange(location: 0, length: string.length), string.length > 0,
               textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true,
               let attributes = textView.textStorage?.attributes(at: 0, effectiveRange: nil),
               attributes[.noteTableID] == nil,
               let rawStyle = attributes[.noteBlockStyle] as? String,
               NoteParagraphStyle(rawValue: rawStyle)?.isList == true {
                parent.controller.performEdit(action: "Delete") {
                    textView.textStorage?.setAttributedString(NSAttributedString(string: "\n", attributes: attributes))
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    textView.typingAttributes = attributes
                    textView.didChangeText()
                }
                return false
            }
            guard replacementString == " ", range.length == 0 else { return true }
            let paragraph = string.paragraphRange(for: range)
            guard range.location == paragraph.location + 2,
                  string.substring(with: NSRange(location: paragraph.location, length: 2)) == "1.",
                  let attributes = textView.textStorage?.attributes(at: paragraph.location, effectiveRange: nil),
                  attributes[.noteTableID] == nil,
                  attributes[.noteBlockStyle] as? String == NoteParagraphStyle.paragraph.rawValue else { return true }
            parent.controller.performEdit(action: "Numbered List") {
                applying = true
                textView.insertText("", replacementRange: NSRange(location: paragraph.location, length: 2))
                parent.controller.setParagraphStyle(.numberedList)
                applying = false
                emit(NoteAttributedDocument.parse(textView.attributedString(), basedOn: lastDocument))
            }
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let selection = textView.selectedRange()
            guard !applying, textView.isEditable, !textView.hasMarkedText(), selection.length == 0 else { return false }
            let string = textView.string as NSString
            let range = string.paragraphRange(for: selection)
            let attributes = range.length > 0
                ? textView.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? [:]
                : textView.typingAttributes
            let isEmpty = string.substring(with: range).trimmingCharacters(in: .newlines).isEmpty
            if parent.editsPageFlow, isEmpty,
               commandSelector == #selector(NSTextView.insertNewline(_:)) || commandSelector == #selector(NSTextView.deleteBackward(_:)),
               let data = attributes[.notePageItem] as? Data,
               var item = try? JSONDecoder().decode(BoardItem.self, from: data), item.task != nil {
                parent.controller.performEdit(action: "End Task List") {
                    item.task = nil
                    if let updated = try? JSONEncoder().encode(item) {
                        textView.textStorage?.addAttribute(.notePageItem, value: updated, range: range)
                        textView.typingAttributes[.notePageItem] = updated
                        textView.didChangeText()
                    }
                }
                return true
            }
            if parent.editsPageFlow, attributes[.noteTableID] == nil {
                let pageStyle = (attributes[.noteBlockStyle] as? String).flatMap(NoteParagraphStyle.init(rawValue:)) ?? .paragraph
                if isEmpty, pageStyle.isList,
                   commandSelector == #selector(NSTextView.insertNewline(_:)) || commandSelector == #selector(NSTextView.deleteBackward(_:)) {
                    parent.controller.setParagraphStyle(.paragraph)
                    return true
                }
                if commandSelector == #selector(NSTextView.insertNewline(_:)) {
                    parent.controller.performEdit(action: "New Paragraph") {
                        applying = true
                        let newID = UUID().uuidString.lowercased()
                        if selection.location == range.location {
                            var inserted = textView.typingAttributes
                            inserted[.noteBlockID] = newID
                            if let data = attributes[.notePageItem] as? Data,
                               let item = try? JSONDecoder().decode(BoardItem.self, from: data), item.task != nil,
                               let fresh = try? JSONEncoder().encode(BoardItem(task: BoardTask())) {
                                inserted[.notePageItem] = fresh; inserted[.notePageItemID] = newID
                            } else {
                                inserted.removeValue(forKey: .notePageItem); inserted.removeValue(forKey: .notePageItemID)
                            }
                            textView.insertText(NSAttributedString(string: "\n", attributes: inserted), replacementRange: selection)
                        } else {
                            textView.insertText("\n", replacementRange: selection)
                            parent.controller.setParagraphStyle(pageStyle, blockID: newID)
                        }
                        applying = false
                        emit(NoteAttributedDocument.parse(textView.attributedString(), basedOn: lastDocument))
                    }
                    return true
                }
            }
            guard attributes[.noteTableID] == nil,
                  let rawStyle = attributes[.noteBlockStyle] as? String,
                  let style = NoteParagraphStyle(rawValue: rawStyle), style.isList else { return false }
            if isEmpty && (commandSelector == #selector(NSTextView.insertNewline(_:))
                || (commandSelector == #selector(NSTextView.deleteBackward(_:)) && selection.location == range.location)) {
                parent.controller.setParagraphStyle(.paragraph)
                return true
            }
            guard commandSelector == #selector(NSTextView.insertNewline(_:)) else { return false }
            parent.controller.performEdit(action: "New List Item") {
                applying = true
                textView.insertText("\n", replacementRange: selection)
                parent.controller.setParagraphStyle(style, blockID: UUID().uuidString.lowercased())
                applying = false
                emit(NoteAttributedDocument.parse(textView.attributedString(), basedOn: lastDocument))
            }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let textView = notification.object as? NSTextView else { return }
            restoreTypingAttributes(in: textView)
            if textView.window?.firstResponder === textView { parent.onFocus?(parent.controller) }
        }

        private func restoreTypingAttributes(in textView: NSTextView) {
            guard let storage = textView.textStorage, storage.length > 0 else { return }
            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location <= storage.length else { return }
            let paragraph = (textView.string as NSString).paragraphRange(for: selection)
            let location = min(storage.length - 1, selection.location > paragraph.location ? selection.location - 1 : selection.location)
            var attributes = storage.attributes(at: location, effectiveRange: nil)
            attributes.removeValue(forKey: .noteDatabaseLink)
            attributes.removeValue(forKey: .noteDatabaseValueID)
            textView.typingAttributes = attributes
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocus?(parent.controller)
            if let editor = parent.dictationEditor { DictationModel.shared.activeEditor = editor }
        }
    }
}

private final class NoteDocumentScrollView: NSScrollView {
    var passesScrollingToParent = false
    override func scrollWheel(with event: NSEvent) {
        if passesScrollingToParent { nextResponder?.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

private final class NoteTextView: NSTextView {
    var sharedUndoManager: UndoManager?
    var showsPageTasks = false
    var onToggleTask: ((String) -> Void)?
    private var taskRegions: [(String, NSRect)] = []
    private var taskElements: [PageTaskAccessibilityElement] = []
    // Each note owns its editing history; the window's title fields and other
    // editors must not become targets of these toolbar actions.
    private let noteUndoManager = UndoManager()
    private var standardLinkTextAttributes: [NSAttributedString.Key: Any]?
    private var didCaptureStandardLinkTextAttributes = false
    override var undoManager: UndoManager? { sharedUndoManager ?? noteUndoManager }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let attributed = insertString as? NSAttributedString else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        // Pasted live values are independent locations, even in the same note.
        let copy = NSMutableAttributedString(attributedString: attributed)
        var identities: [String: String] = [:]
        attributed.enumerateAttribute(.noteDatabaseValueID, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let original = value as? String else { return }
            let identity = identities[original] ?? UUID().uuidString.lowercased()
            identities[original] = identity
            copy.addAttribute(.noteDatabaseValueID, value: identity, range: range)
        }
        super.insertText(copy, replacementRange: replacementRange)
    }

    @objc func undo(_ sender: Any?) {
        guard isEditable, let manager = undoManager, manager.canUndo else { return }
        breakUndoCoalescing()
        manager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard isEditable, let manager = undoManager, manager.canRedo else { return }
        breakUndoCoalescing()
        manager.redo()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return isEditable && undoManager?.canUndo == true
        case #selector(redo(_:)): return isEditable && undoManager?.canRedo == true
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        insertionPointColor = DashboardColors.noteForeground()
        if !didCaptureStandardLinkTextAttributes {
            standardLinkTextAttributes = linkTextAttributes
            didCaptureStandardLinkTextAttributes = true
        }
        if DashboardColors.isDark(effectiveAppearance) {
            var attributes = standardLinkTextAttributes ?? [:]
            attributes[.foregroundColor] = DashboardColors.success
            linkTextAttributes = attributes
        } else {
            linkTextAttributes = standardLinkTextAttributes
        }
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        drawHighlights(in: rect)
        super.drawBackground(in: rect)
        drawPageTasks()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (id, _) = taskRegions.first(where: { $0.1.insetBy(dx: -4, dy: -4).contains(point) }), isEditable {
            toggleTask(id)
            return
        }
        super.mouseDown(with: event)
    }

    @discardableResult fileprivate func toggleTask(_ id: String) -> Bool {
        guard isEditable, let onToggleTask else { return false }
        window?.makeFirstResponder(self)
        if let storage = textStorage {
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { values, range, stop in
                guard (values[.noteBlockID] as? String ?? values[.noteTableID] as? String) == id else { return }
                setSelectedRange(NSRange(location: range.location, length: 0))
                stop.pointee = true
            }
        }
        onToggleTask(id)
        return true
    }

    /// The checkboxes are drawn, so expose each one to VoiceOver as a checkbox
    /// that names its task and can be pressed.
    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        return taskElements.isEmpty ? children : children + taskElements
    }

    private func drawPageTasks() {
        taskRegions.removeAll()
        var tasks: [(id: String, label: String, done: Bool, frame: NSRect)] = []
        defer { updateTaskElements(tasks) }
        guard showsPageTasks, let storage = textStorage, let window else { return }
        var drawn = Set<String>()
        storage.enumerateAttribute(.notePageItem, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let attributes = storage.attributes(at: range.location, effectiveRange: nil)
            guard let id = attributes[.noteBlockID] as? String ?? attributes[.noteTableID] as? String,
                  drawn.insert(id).inserted, let data = value as? Data,
                  let item = try? JSONDecoder().decode(BoardItem.self, from: data), let task = item.task else { return }
            let screen = firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
            let line = convert(window.convertFromScreen(screen), from: nil)
            let frame = NSRect(x: 3, y: line.midY - 6, width: 12, height: 12)
            taskRegions.append((id, frame))
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
            let text = (storage.string as NSString).substring(with: paragraph)
                .replacingOccurrences(of: "\u{2028}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            tasks.append((id, text.isEmpty ? "Task" : String(text.prefix(120)), task.status == .done, frame))
            let outline = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            DashboardColors.noteForeground().withAlphaComponent(0.6).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            if task.status == .done {
                DashboardColors.success.setStroke()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: frame.minX + 2, y: frame.midY))
                check.line(to: NSPoint(x: frame.minX + 5, y: frame.maxY - 3))
                check.line(to: NSPoint(x: frame.maxX - 2, y: frame.minY + 3))
                check.lineWidth = 1.5
                check.stroke()
            }
        }
    }

    private func updateTaskElements(_ tasks: [(id: String, label: String, done: Bool, frame: NSRect)]) {
        let changed = tasks.count != taskElements.count
            || zip(tasks, taskElements).contains { task, element in
                task.id != element.taskID || task.label != element.accessibilityLabel()
                    || task.done != element.isChecked
            }
        if changed {
            taskElements = tasks.map { task in
                let element = PageTaskAccessibilityElement(taskID: task.id, owner: self)
                element.setAccessibilityLabel(task.label)
                element.isChecked = task.done
                return element
            }
        }
        for (task, element) in zip(tasks, taskElements) {
            element.setAccessibilityFrameInParentSpace(task.frame.insetBy(dx: -4, dy: -4))
            element.setAccessibilityEnabled(isEditable)
        }
        if changed { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    private func drawHighlights(in rect: NSRect) {
        guard let manager = textLayoutManager,
              let content = manager.textContentManager,
              let storage = textStorage else { return }
        let viewport = manager.textViewportLayoutController.viewportRange ?? content.documentRange
        manager.ensureLayout(for: viewport)
        let start = content.documentRange.location
        let visibleRange = NSRange(
            location: content.offset(from: start, to: viewport.location),
            length: content.offset(from: viewport.location, to: viewport.endLocation)
        )
        guard visibleRange.location >= 0, NSMaxRange(visibleRange) <= storage.length else { return }
        let origin = textContainerOrigin
        storage.enumerateAttribute(.backgroundColor, in: visibleRange) { value, range, _ in
            guard let color = value as? NSColor,
                  let lower = content.location(start, offsetBy: range.location),
                  let upper = content.location(lower, offsetBy: range.length),
                  let textRange = NSTextRange(location: lower, end: upper) else { return }
            // Native list markers inherit the first character's background and
            // paint it over the selection. Draw highlights behind native selection
            // instead, keeping the document attributes for saving and copying.
            manager.addRenderingAttribute(.backgroundColor, value: NSNull(), for: textRange)
            color.setFill()
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                let background = frame.offsetBy(dx: origin.x, dy: origin.y)
                if background.intersects(rect) { background.fill() }
                return true
            }
        }
    }
}

/// A drawn Page task checkbox, as VoiceOver sees it.
private final class PageTaskAccessibilityElement: NSAccessibilityElement {
    let taskID: String
    weak var owner: NoteTextView?
    var isChecked = false {
        didSet { setAccessibilityValue(NSNumber(value: isChecked ? 1 : 0)) }
    }

    init(taskID: String, owner: NoteTextView) {
        self.taskID = taskID
        self.owner = owner
        super.init()
        setAccessibilityRole(.checkBox)
        setAccessibilityParent(owner)
        setAccessibilityValue(NSNumber(value: 0))
        setAccessibilityHelp("Completes or reopens this task.")
    }

    override func accessibilityPerformPress() -> Bool {
        // Accessibility actions arrive on the main thread.
        let owner = owner, id = taskID
        return MainActor.assumeIsolated { owner?.toggleTask(id) ?? false }
    }
}

@MainActor
private enum NoteAttributedDocument {
    static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: DashboardColors.noteForeground(),
    ]

    static func render(_ document: NoteDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var previousStyle: NoteParagraphStyle?
        var list: NSTextList?
        var nativeLists: [NoteTextList: NSTextList] = [:]
        for block in document.normalized().blocks {
            let start = result.length
            switch block {
            case .richText(let richText):
                var paragraph = paragraphStyle(for: richText.style, list: previousStyle == richText.style ? list : nil)
                if let formatting = richText.list {
                    paragraph = restoreList(formatting, to: paragraph, lists: &nativeLists)
                }
                var display = richText
                if document.kind == .canvas {
                    for index in display.runs.indices {
                        display.runs[index].text = display.runs[index].text.replacingOccurrences(of: "\n", with: "\u{2028}")
                    }
                }
                append(display, paragraph: paragraph, to: result)
                previousStyle = richText.style
                list = paragraph.textLists.first
            case .table(let table):
                append(table, to: result)
                if let definition = try? JSONEncoder().encode(table), result.length > start {
                    result.addAttribute(.noteTableDefinition, value: definition, range: NSRange(location: start, length: result.length - start))
                }
                previousStyle = nil
                list = nil
            }
            if document.kind == .canvas, let item = document.boardItems?[block.id],
               let data = try? JSONEncoder().encode(item), result.length > start {
                result.addAttribute(.notePageItem, value: data, range: NSRange(location: start, length: result.length - start))
                result.addAttribute(.notePageItemID, value: block.id, range: NSRange(location: start, length: result.length - start))
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
        let sourceLists = source.blocks.reduce(into: [String: NoteListFormatting]()) { result, block in
            if case .richText(let text) = block, let list = text.list { result[text.id] = list }
        }
        var nativeLists: [ObjectIdentifier: NoteTextList] = [:]
        var usedListIDs: Set<String> = []
        var tables = sourceTables
        var emittedTables: Set<String> = []
        var seenBlockIDs: Set<String> = []
        var parsedItems: [String: BoardItem] = [:]
        var blocks: [NoteBlock] = []
        let string = attributed.string as NSString
        var location = 0
        // Enter at the beginning of a task must leave its identity, assignment
        // and outcome on its existing text, rather than on the new blank line.
        var preferredLocations: [String: Int] = [:]
        if source.kind == .canvas {
            var offset = 0
            while offset < attributed.length {
                let range = string.paragraphRange(for: NSRange(location: offset, length: 0))
                if let id = attributed.attribute(.noteBlockID, at: offset, effectiveRange: nil) as? String,
                   preferredLocations[id] == nil,
                   !string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    preferredLocations[id] = range.location
                }
                guard range.length > 0 else { break }
                offset = NSMaxRange(range)
            }
        }

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
               var table = tables[tableID] ?? (attributes[.noteTableDefinition] as? Data).flatMap({ try? JSONDecoder().decode(NoteTableBlock.self, from: $0) }),
               table.id == tableID {
                if let rowID = attributes[.noteRowID] as? String,
                   let columnID = attributes[.noteColumnID] as? String,
                   let row = table.rows.firstIndex(where: { $0.id == rowID }),
                   let column = table.columns.firstIndex(where: { $0.id == columnID }) {
                    table.rows[row].cells[column].runs = runs(in: attributed, range: contentRange)
                    // Cell fills are table metadata; a run's highlight is separate.
                    // Keep the authored fill when parsing edits in either appearance.
                    tables[tableID] = table
                }
                if emittedTables.insert(tableID).inserted { blocks.append(.table(table)) }
                if let data = attributes[.notePageItem] as? Data,
                   let item = try? JSONDecoder().decode(BoardItem.self, from: data) { parsedItems[tableID] = item }
            } else {
                let proposedID = attributes[.noteBlockID] as? String
                let blockID = proposedID.flatMap {
                    guard source.kind != .canvas || preferredLocations[$0] == nil || preferredLocations[$0] == paragraphRange.location else { return nil }
                    return seenBlockIDs.insert($0).inserted ? $0 : nil
                }
                    ?? UUID().uuidString.lowercased()
                let rawStyle = attributes[.noteBlockStyle] as? String
                let style = rawStyle.flatMap(NoteParagraphStyle.init(rawValue:)) ?? .paragraph
                blocks.append(.richText(NoteRichTextBlock(
                    id: blockID,
                    style: style,
                    runs: runs(in: attributed, range: contentRange),
                    list: captureList(attributes[.paragraphStyle] as? NSParagraphStyle,
                                      previous: proposedID.flatMap { sourceLists[$0] },
                                      lists: &nativeLists, usedIDs: &usedListIDs)
                )))
                if let data = attributes[.notePageItem] as? Data,
                   let item = try? JSONDecoder().decode(BoardItem.self, from: data) {
                    if blockID == proposedID && attributes[.notePageItemID] as? String == blockID { parsedItems[blockID] = item }
                    else if item.task != nil { parsedItems[blockID] = BoardItem(task: BoardTask()) }
                }
            }
            guard paragraphRange.length > 0 else { break }
            location = NSMaxRange(paragraphRange)
        }

        blocks = blocks.map { block in
            if source.kind == .canvas, case .richText(var text) = block {
                for index in text.runs.indices { text.runs[index].text = text.runs[index].text.replacingOccurrences(of: "\u{2028}", with: "\n") }
                return .richText(text)
            }
            guard case .table(let table) = block, let updated = tables[table.id] else { return block }
            return .table(updated)
        }
        var document = source
        document.blocks = blocks
        if source.kind == .canvas {
            parsedItems = parsedItems.filter { $0.value != BoardItem() }
            document.boardItems = parsedItems.isEmpty ? nil : parsedItems
        }
        return document.normalized()
    }

    private static func captureList(
        _ paragraph: NSParagraphStyle?, previous: NoteListFormatting?,
        lists: inout [ObjectIdentifier: NoteTextList], usedIDs: inout Set<String>
    ) -> NoteListFormatting? {
        guard let paragraph, !paragraph.textLists.isEmpty else { return nil }
        let levels = paragraph.textLists.enumerated().map { depth, native in
            let identity = ObjectIdentifier(native)
            if let existing = lists[identity] { return existing }
            var level = NoteTextList(markerFormat: native.markerFormat.rawValue,
                                     options: native.listOptions.rawValue,
                                     startingItemNumber: native.startingItemNumber)
            if let previous, previous.levels.indices.contains(depth) {
                let old = previous.levels[depth]
                if old.markerFormat == level.markerFormat, old.options == level.options,
                   old.startingItemNumber == level.startingItemNumber, !usedIDs.contains(old.id) {
                    level.id = old.id
                }
            }
            lists[identity] = level
            usedIDs.insert(level.id)
            return level
        }
        return NoteListFormatting(levels: levels, headIndent: paragraph.headIndent,
                                  firstLineHeadIndent: paragraph.firstLineHeadIndent,
                                  tabStops: paragraph.tabStops.map {
                                      NoteListTabStop(alignment: $0.alignment.rawValue, location: $0.location)
                                  }, defaultTabInterval: paragraph.defaultTabInterval)
    }

    private static func restoreList(
        _ formatting: NoteListFormatting, to paragraph: NSParagraphStyle,
        lists: inout [NoteTextList: NSTextList]
    ) -> NSParagraphStyle {
        guard let paragraph = paragraph.mutableCopy() as? NSMutableParagraphStyle else { return paragraph }
        paragraph.textLists = formatting.levels.map { level in
            if let existing = lists[level] { return existing }
            let native = NSTextList(markerFormat: .init(rawValue: level.markerFormat),
                                    options: .init(rawValue: level.options),
                                    startingItemNumber: level.startingItemNumber)
            lists[level] = native
            return native
        }
        paragraph.headIndent = formatting.headIndent
        paragraph.firstLineHeadIndent = formatting.firstLineHeadIndent
        paragraph.tabStops = formatting.tabStops.map {
            NSTextTab(textAlignment: NSTextAlignment(rawValue: $0.alignment) ?? .natural,
                      location: $0.location)
        }
        paragraph.defaultTabInterval = formatting.defaultTabInterval
        return paragraph
    }

    private static func append(_ block: NoteRichTextBlock, paragraph: NSParagraphStyle, to result: NSMutableAttributedString) {
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
            let text = run.text.isEmpty && run.databaseLink != nil ? "\u{200B}" : run.text
            result.append(NSAttributedString(string: text, attributes: attributes(for: run, style: block.style).merging(base) { first, _ in first }))
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
                cellBlock.backgroundColor = color(from: cell.backgroundHex).map(DashboardColors.noteBackground)
                    ?? (rowIndex < table.headerRowCount
                        ? DashboardColors.noteBackground(.controlBackgroundColor) : .clear)
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
            .foregroundColor: DashboardColors.noteForeground(color(from: run.foregroundHex) ?? .labelColor),
        ]
        if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let color = color(from: run.highlightHex) { attributes[.backgroundColor] = DashboardColors.noteBackground(color) }
        if let link = run.link.flatMap(URL.init(string:)) { attributes[.link] = link }
        if let link = run.databaseLink, let encoded = try? JSONEncoder().encode(link) {
            attributes[.noteDatabaseLink] = encoded
            attributes[.noteDatabaseValueID] = run.databaseValueID
        }
        return attributes
    }

    private static func runs(in attributed: NSAttributedString, range: NSRange) -> [NoteTextRun] {
        guard range.length > 0 else { return [] }
        var result: [NoteTextRun] = []
        attributed.enumerateAttributes(in: range) { attributes, subrange, _ in
            let raw = (attributed.string as NSString).substring(with: subrange)
                .replacingOccurrences(of: "\u{200B}", with: "")
            let databaseLink = (attributes[.noteDatabaseLink] as? Data).flatMap {
                try? JSONDecoder().decode(DatabaseArtifactLink.self, from: $0)
            }
            guard !raw.isEmpty || databaseLink != nil else { return }
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            let traits = NSFontManager.shared.traits(of: font)
            result.append(NoteTextRun(
                text: raw,
                fontFamily: font.familyName,
                fontSize: font.pointSize,
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask),
                underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                foregroundHex: DashboardColors.documentColorHex(attributes[.foregroundColor] as? NSColor),
                highlightHex: DashboardColors.documentColorHex(attributes[.backgroundColor] as? NSColor),
                link: (attributes[.link] as? URL)?.absoluteString
                    ?? attributes[.link] as? String,
                databaseLink: databaseLink,
                databaseValueID: attributes[.noteDatabaseValueID] as? String
            ))
        }
        return result
    }

    static func valueIDs(touchedBy range: NSRange, in text: NSAttributedString) -> Set<String> {
        guard text.length > 0, range.location <= text.length,
              NSMaxRange(range) <= text.length else { return [] }
        if range.length == 0 {
            guard range.location > 0, range.location < text.length,
                  let left = text.attribute(.noteDatabaseValueID, at: range.location - 1, effectiveRange: nil) as? String,
                  text.attribute(.noteDatabaseValueID, at: range.location, effectiveRange: nil) as? String == left else { return [] }
            return [left]
        }
        var result = Set<String>()
        text.enumerateAttribute(.noteDatabaseValueID, in: range) { value, _, _ in
            if let id = value as? String { result.insert(id) }
        }
        return result
    }

    /// Anchor selection in its paragraph/cell, then account for preceding values
    /// changing width. A selection inside a value remains inside that value.
    static func selectionAfterRefreshingValues(
        _ selection: NSRange, from old: NSAttributedString, to new: NSAttributedString
    ) -> NSRange {
        func range(for key: NSAttributedString.Key, id: String, in text: NSAttributedString, scope: NSRange? = nil) -> NSRange? {
            var result: NSRange?
            text.enumerateAttribute(key, in: scope ?? NSRange(location: 0, length: text.length)) { value, candidate, stop in
                guard value as? String == id else { return }
                result = candidate
                stop.pointee = true
            }
            return result
        }
        func map(_ position: Int) -> Int {
            guard old.length > 0, new.length > 0 else { return min(position, new.length) }
            let probe = min(position, old.length - 1)
            let attributes = old.attributes(at: probe, effectiveRange: nil)
            let key: NSAttributedString.Key = attributes[.noteCellID] == nil ? .noteBlockID : .noteCellID
            guard let id = attributes[key] as? String,
                  let before = range(for: key, id: id, in: old),
                  let after = range(for: key, id: id, in: new) else { return min(position, new.length) }
            var offset = position - before.location
            var inside: Int?
            old.enumerateAttribute(.noteDatabaseValueID, in: before) { value, valueRange, stop in
                guard let id = value as? String,
                      let updated = range(for: .noteDatabaseValueID, id: id, in: new, scope: after) else { return }
                if position <= valueRange.location { stop.pointee = true; return }
                if position < NSMaxRange(valueRange) {
                    inside = updated.location + min(position - valueRange.location, updated.length)
                    stop.pointee = true
                } else {
                    offset += updated.length - valueRange.length
                }
            }
            return inside ?? after.location + min(max(0, offset), after.length)
        }
        let start = min(max(0, map(selection.location)), new.length)
        let end = min(max(start, map(NSMaxRange(selection))), new.length)
        return NSRange(location: start, length: end - start)
    }

    private static func trailingNewlineLength(in string: NSString, range: NSRange) -> Int {
        guard range.length > 0 else { return 0 }
        let last = string.character(at: NSMaxRange(range) - 1)
        return last == 10 || last == 13 ? 1 : 0
    }
}

private func paragraphStyle(for style: NoteParagraphStyle, list: NSTextList? = nil) -> NSParagraphStyle {
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = style.headingSize == nil ? 8 : 10
    switch style {
    case .bulletedList:
        paragraph.textLists = [list ?? NSTextList(markerFormat: .disc, options: 0)]
        paragraph.headIndent = 22
        paragraph.firstLineHeadIndent = 6
    case .numberedList:
        paragraph.textLists = [list ?? NSTextList(markerFormat: .init(rawValue: "{decimal}."), options: 0)]
        paragraph.headIndent = 28
        paragraph.firstLineHeadIndent = 6
    default:
        break
    }
    return paragraph
}

private extension NoteParagraphStyle {
    var isList: Bool { self == .bulletedList || self == .numberedList }

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

    var color: Color { Color(nsColor: DashboardColors.noteBackground(nsColor)) }
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
