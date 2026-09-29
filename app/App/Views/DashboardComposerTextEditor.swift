import AppKit
import SwiftUI

@MainActor
struct DashboardComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let maximumVisibleLines: Int
    let onSubmit: () -> Void
    let onTab: () -> Bool
    let onCommandNavigation: (DashboardComposerNavigationDirection) -> Bool
    var onMoveSelection: (Int) -> Bool = { _ in false }
    var onEscape: () -> Bool = { false }
    var completionRequest: Binding<Int> = .constant(0)
    var onCaretAtEndChange: (Bool) -> Void = { _ in }
    var onAttachFiles: ([URL]) -> Bool = { _ in false }
    var dictationEditor: DictationEditor? = nil
    var dictationIdentity = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> DashboardComposerScrollView {
        let scrollView = DashboardComposerScrollView()
        scrollView.maximumVisibleLines = maximumVisibleLines
        let textView = scrollView.composerTextView
        textView.delegate = context.coordinator
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.onPrepareInput = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.reconcilePendingCompletion(for: textView)
        }
        textView.placeholderString = placeholder
        textView.setAccessibilityLabel(placeholder)
        textView.string = text
        dictationEditor?.bind(textView, identity: dictationIdentity)
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.onTab = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onTab() ?? false
        }
        textView.onCommandNavigation = { [weak coordinator = context.coordinator] direction in
            coordinator?.parent.onCommandNavigation(direction) ?? false
        }
        textView.onMoveSelection = { [weak coordinator = context.coordinator] direction in
            coordinator?.parent.onMoveSelection(direction) ?? false
        }
        textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEscape() ?? false
        }
        textView.onAttachFiles = { [weak coordinator = context.coordinator] urls in
            coordinator?.parent.onAttachFiles(urls) ?? false
        }
        textView.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.parent.isFocused = true
        }
        scrollView.updateDocumentLayout()
        return scrollView
    }

    func updateNSView(_ scrollView: DashboardComposerScrollView, context: Context) {
        context.coordinator.parent = self
        scrollView.maximumVisibleLines = maximumVisibleLines
        let textView = scrollView.composerTextView
        dictationEditor?.bind(textView, identity: dictationIdentity)
        textView.placeholderString = placeholder
        textView.setAccessibilityLabel(placeholder)

        context.coordinator.reconcileText(for: textView)
        context.coordinator.scheduleCaretReport(for: textView)
        scrollView.updateDocumentLayout()

        context.coordinator.reconcileFocus(for: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: DashboardComposerScrollView,
        context: Context
    ) -> CGSize? {
        nsView.fittingSize(for: proposal)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DashboardComposerTextEditor
        private var appliedCompletionRequest: Int
        private var caretReportGeneration = 0
        private var reportedCaretAtEnd: Bool?

        init(parent: DashboardComposerTextEditor) {
            self.parent = parent
            self.appliedCompletionRequest = parent.completionRequest.wrappedValue
        }

        func reconcilePendingCompletion(for textView: DashboardComposerNativeTextView) {
            // A key can arrive before SwiftUI delivers updateNSView. Read the
            // live binding and settle completion before AppKit edits the draft.
            guard appliedCompletionRequest != parent.completionRequest.wrappedValue else { return }
            reconcileText(for: textView)
        }

        func reconcileText(for textView: DashboardComposerNativeTextView) {
            guard !textView.hasMarkedText() else { return }
            let didComplete = appliedCompletionRequest != parent.completionRequest.wrappedValue
            if textView.string != parent.text {
                let selection = textView.selectedRange()
                textView.string = parent.text
                let location = min(selection.location, parent.text.utf16.count)
                textView.setSelectedRange(NSRange(
                    location: location,
                    length: min(selection.length, parent.text.utf16.count - location)
                ))
            }
            if didComplete {
                let caret = NSRange(location: parent.text.utf16.count, length: 0)
                textView.setSelectedRange(caret)
                textView.scrollRangeToVisible(caret)
                appliedCompletionRequest = parent.completionRequest.wrappedValue
            }
        }

        func scheduleCaretReport(for textView: DashboardComposerNativeTextView) {
            caretReportGeneration += 1
            let generation = caretReportGeneration
            // Selection also changes while SwiftUI applies an updated draft.
            // Report after that update, reading the live selection rather than
            // delivering a captured value that a newer edit may have invalidated.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      self.caretReportGeneration == generation else { return }
                let selection = textView.selectedRange()
                let isAtEnd = selection.length == 0
                    && selection.location == textView.string.utf16.count
                guard self.reportedCaretAtEnd != isAtEnd else { return }
                self.reportedCaretAtEnd = isAtEnd
                self.parent.onCaretAtEndChange(isAtEnd)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? DashboardComposerNativeTextView else { return }
            scheduleCaretReport(for: textView)
        }

        func reconcileFocus(for textView: DashboardComposerNativeTextView) {
            guard let window = textView.window else { return }
            if parent.isFocused, window.firstResponder !== textView {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.applyFocusReconciliation(
                        expectedFocused: true,
                        for: textView
                    )
                }
            } else if !parent.isFocused, window.firstResponder === textView {
                // AppKit can make the native editor first responder before the
                // SwiftUI focus binding has observed textDidBeginEditing. Wait
                // one turn and recheck the live binding so a manual click is
                // not immediately undone by a stale updateNSView pass.
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.applyFocusReconciliation(
                        expectedFocused: false,
                        for: textView
                    )
                }
            }
        }

        func applyFocusReconciliation(
            expectedFocused: Bool,
            for textView: DashboardComposerNativeTextView
        ) {
            guard parent.isFocused == expectedFocused,
                  let window = textView.window
            else { return }
            if expectedFocused, window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            } else if !expectedFocused, window.firstResponder === textView {
                window.makeFirstResponder(nil)
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            if let editor = parent.dictationEditor { DictationModel.shared.activeEditor = editor }
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? DashboardComposerNativeTextView else { return }
            parent.text = textView.string
            scheduleCaretReport(for: textView)
            (textView.enclosingScrollView as? DashboardComposerScrollView)?.updateDocumentLayout()
        }
    }
}

@MainActor
final class DashboardComposerScrollView: NSScrollView {
    static let minimumHeight: CGFloat = 32

    var maximumVisibleLines = 7

    let composerTextView = DashboardComposerNativeTextView()

    // SwiftUI also probes with infinity and huge finite sentinels. Such values
    // cannot describe a real text viewport and must never reach NSView geometry.
    private static let maximumMeasurementWidth: CGFloat = 1_000_000
    private static let initialMeasurementWidth: CGFloat = 320
    private let measurementStorage = NSTextStorage()
    private let measurementLayoutManager = NSLayoutManager()
    private let measurementContainer = NSTextContainer(
        containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
    )
    private var isUpdatingDocumentLayout = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    var preferredHeight: CGFloat {
        min(max(naturalDocumentHeight, Self.minimumHeight), maximumHeight)
    }

    func fittingSize(for proposal: ProposedViewSize) -> CGSize {
        let width = Self.measurementWidth(proposal.width)
            ?? Self.measurementWidth(bounds.width)
            ?? Self.initialMeasurementWidth
        guard let storage = composerTextView.textStorage else {
            return CGSize(width: width, height: Self.minimumHeight)
        }
        // Measurement has its own reusable TextKit objects. Probing a different
        // width must not resize the mounted editor, move its selection, or force
        // another native layout pass while SwiftUI is choosing a size.
        if !measurementStorage.isEqual(to: storage) {
            measurementStorage.setAttributedString(storage)
        }
        let padding = composerTextView.textContainer?.lineFragmentPadding ?? 0
        if measurementContainer.lineFragmentPadding != padding {
            measurementContainer.lineFragmentPadding = padding
        }
        let size = NSSize(
            width: max(1, width - composerTextView.textContainerInset.width * 2),
            height: CGFloat.greatestFiniteMagnitude
        )
        if measurementContainer.containerSize != size {
            measurementContainer.containerSize = size
        }
        let naturalHeight = documentHeight(using: measurementLayoutManager, in: measurementContainer)
        return CGSize(width: width, height: min(max(naturalHeight, Self.minimumHeight), maximumHeight))
    }

    private static func measurementWidth(_ width: CGFloat?) -> CGFloat? {
        guard let width, width.isFinite, width > 0, width <= maximumMeasurementWidth else { return nil }
        return width
    }

    var hasVerticalOverflow: Bool {
        naturalDocumentHeight > contentView.bounds.height + 0.5
    }

    override func layout() {
        super.layout()
        updateDocumentLayout()
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        if hasVerticalOverflow {
            super.scrollWheel(with: event)
        } else if let nextResponder {
            nextResponder.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    func updateDocumentLayout() {
        guard !isUpdatingDocumentLayout else { return }
        let viewport = contentSize
        guard viewport.width.isFinite, viewport.width >= 0,
              viewport.width <= Self.maximumMeasurementWidth,
              viewport.height.isFinite, viewport.height >= 0 else { return }
        isUpdatingDocumentLayout = true
        defer { isUpdatingDocumentLayout = false }
        let width = max(viewport.width, 1)
        var geometryChanged = false
        if composerTextView.frame.width != width {
            composerTextView.frame.size.width = width
            geometryChanged = true
        }
        let containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if let textContainer = composerTextView.textContainer,
           textContainer.containerSize != containerSize {
            textContainer.containerSize = containerSize
            geometryChanged = true
        }
        let frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: max(viewport.height, naturalDocumentHeight)
        )
        if composerTextView.frame != frame {
            composerTextView.frame = frame
            geometryChanged = true
        }
        if geometryChanged { reflectScrolledClipView(contentView) }
    }

    private var naturalDocumentHeight: CGFloat {
        guard let layoutManager = composerTextView.layoutManager,
              let textContainer = composerTextView.textContainer else {
            return Self.minimumHeight
        }
        return documentHeight(using: layoutManager, in: textContainer)
    }

    private func documentHeight(using layoutManager: NSLayoutManager, in textContainer: NSTextContainer) -> CGFloat {
        layoutManager.ensureLayout(for: textContainer)
        var height = layoutManager.usedRect(for: textContainer).maxY
        // A trailing newline has an empty caret line with no glyphs of its own.
        // Include it identically in speculative measurement and native layout.
        if layoutManager.extraLineFragmentTextContainer === textContainer {
            height = max(height, layoutManager.extraLineFragmentRect.maxY)
        }
        return ceil(height + composerTextView.textContainerInset.height * 2)
    }

    private var maximumHeight: CGFloat {
        let lineHeight = composerTextView.layoutManager?.defaultLineHeight(
            for: DashboardComposerNativeTextView.composerFont
        ) ?? DashboardComposerNativeTextView.composerFont.pointSize
        return ceil(
            lineHeight * CGFloat(max(1, maximumVisibleLines))
                + DashboardComposerNativeTextView.lineSpacing
                    * CGFloat(max(1, maximumVisibleLines))
                + composerTextView.textContainerInset.height * 2
        )
    }

    private func configure() {
        measurementStorage.addLayoutManager(measurementLayoutManager)
        measurementLayoutManager.addTextContainer(measurementContainer)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        documentView = composerTextView
    }
}

@MainActor
final class DashboardComposerNativeTextView: NSTextView {
    static let composerFont = NSFont.systemFont(ofSize: 15)
    static let lineSpacing: CGFloat = 4

    var onAttachFiles: (([URL]) -> Bool)?
    var onSubmit: (() -> Void)?
    var onTab: (() -> Bool)?
    var onPrepareInput: (() -> Void)?
    var onCommandNavigation: ((DashboardComposerNavigationDirection) -> Bool)?
    var onMoveSelection: ((Int) -> Bool)?
    var onEscape: (() -> Bool)?
    var onBecomeFirstResponder: (() -> Void)?
    var placeholderString = "" {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        self.init(frame: .zero, textContainer: textContainer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onBecomeFirstResponder?()
        }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        onPrepareInput?()
        if let direction = DashboardComposerNavigationDirection.resolve(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            hasMarkedText: hasMarkedText()
        ), onCommandNavigation?(direction) == true {
            return
        }
        if !hasMarkedText(),
           DashboardComposerKeyAction.normalizedModifiers(event.modifierFlags).isEmpty {
            switch event.keyCode {
            case 125 where onMoveSelection?(1) == true,
                 126 where onMoveSelection?(-1) == true,
                 53 where onEscape?() == true:
                return
            default:
                break
            }
        }
        if event.keyCode == 48,
           !hasMarkedText(),
           DashboardComposerKeyAction.normalizedModifiers(event.modifierFlags).isEmpty,
           onTab?() == true {
            return
        }
        switch DashboardComposerKeyAction.resolve(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags,
            hasMarkedText: hasMarkedText()
        ) {
        case .submit:
            onSubmit?()
        case .insertNewline:
            insertNewlineIgnoringFieldEditor(self)
        case .standard:
            super.keyDown(with: event)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if attach(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if attach(from: .general) { return }
        super.paste(sender)
    }

    private static var temporaryAttachmentFolders: Set<URL> = []

    static func releaseTemporaryAttachments(_ urls: [URL]) {
        for url in urls {
            let folder = url.deletingLastPathComponent()
            guard temporaryAttachmentFolders.remove(folder) != nil else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @discardableResult
    func attach(from pasteboard: NSPasteboard) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return onAttachFiles?(urls) ?? false }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= 25 * 1024 * 1024 else { return false }
        let folder = FileManager.default.temporaryDirectory.appending(path: "wovenmatter-paste-" + UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: "Screenshot.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try png.write(to: file, options: .atomic)
            Self.temporaryAttachmentFolders.insert(folder)
            if onAttachFiles?([file]) == true { return true }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return false
        }
        Self.releaseTemporaryAttachments([file])
        return false
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        (placeholderString as NSString).draw(
            at: NSPoint(
                x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                y: textContainerInset.height
            ),
            withAttributes: [
                .font: Self.composerFont,
                .foregroundColor: NSColor.placeholderTextColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private func configure() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = Self.lineSpacing

        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isEditable = true
        isSelectable = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 0, height: 7)
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        font = Self.composerFont
        textColor = .labelColor
        insertionPointColor = .labelColor
        defaultParagraphStyle = paragraphStyle
        typingAttributes = [
            .font: Self.composerFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]
    }
}

enum DashboardComposerNavigationDirection: Equatable {
    case left
    case right
    case up
    case down

    static func resolve(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> Self? {
        guard !hasMarkedText,
              DashboardComposerKeyAction.normalizedModifiers(modifierFlags) == [.command]
        else { return nil }
        return switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }
}

enum DashboardComposerKeyAction: Equatable {
    case submit
    case insertNewline
    case standard

    static func resolve(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> Self {
        let isReturn = keyCode == 36
            || keyCode == 76
            || charactersIgnoringModifiers == "\r"
            || charactersIgnoringModifiers == "\n"
        guard isReturn, !hasMarkedText else { return .standard }

        let modifiers = normalizedModifiers(modifierFlags)
        if modifiers == [.shift] { return .insertNewline }
        if modifiers.isEmpty { return .submit }
        return .standard
    }

    static func normalizedModifiers(
        _ modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
    }
}
