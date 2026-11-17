import AppKit
import SwiftUI
import WovenMatterCore

struct DesktopNotePane: View {
    @Environment(\.wovenTheme) private var theme
    @Bindable var model: ApplicationModel
    let note: WorkspaceNoteRecord
    let focusesTitleOnAppear: Bool
    let onInitialFocusHandled: () -> Void
    let onOpenNote: (String) -> Void
    var onOpenSession: ((String) -> Void)?
    var embedded = false
    var onEditorFocus: ((NoteEditorController) -> Void)?
    @FocusState private var titleFocused: Bool
    @State private var editorController = NoteEditorController()
    @State private var activePageEditor: NoteEditorController?
    @State private var dictationEditor = DictationEditor()
    @State private var documentCache = NoteDocumentCache()
    @State private var canvasViewState = CanvasViewState()
    @State private var showsFormatting = false
    @State private var sheetHistory = SheetUndoHistory()
    @State private var artifactHistory = ArtifactCodeHistory()
    @State private var sheetDictation = DictationEditor()
    @State private var showsVersionHistory = false
    @State private var showsCharacterCount = false
    @State private var linkedDataJSON: String?
    @State private var linkedDataError: String?
    @State private var isRefreshingLinkedData = false
    @State private var activeLinkedDataRefreshID: UUID?

    private var draft: NoteDraft {
        model.noteDraft(for: note)
    }

    private var title: Binding<String> {
        Binding(
            get: { model.noteDraft(for: note).title },
            set: { model.updateNoteDraft(note: note, title: $0) }
        )
    }

    private var document: Binding<NoteDocument> {
        Binding(
            get: { documentCache.value(noteID: note.id, source: model.noteDraft(for: note).content) },
            set: { updated in
                guard !model.noteEditingSuspended, documentIsEditable, let content = try? documentCache.encode(updated, noteID: note.id) else { return }
                model.updateNoteDraft(note: note, content: content)
            }
        )
    }

    /// The Sheet's document, recording each local edit for undo.
    private var sheetDocument: Binding<NoteDocument> {
        Binding(get: { document.wrappedValue }, set: { updated in
            let before = document.wrappedValue
            document.wrappedValue = updated
            sheetHistory.recordLocal(from: before, to: document.wrappedValue)
        })
    }

    private var artifactCode: String? { currentDocument.kind == .html ? currentDocument.html : nil }

    private func canUndo(_ kind: NoteArtifactKind) -> Bool {
        switch kind {
        case .note: editorController.canUndo
        case .canvas: activePageEditor?.canUndo == true || !canvasViewState.undoStack.isEmpty
        case .spreadsheet: sheetHistory.canUndo
        case .html: artifactHistory.canUndo
        }
    }

    private func canRedo(_ kind: NoteArtifactKind) -> Bool {
        switch kind {
        case .note: editorController.canRedo
        case .canvas: activePageEditor?.canRedo == true || !canvasViewState.redoStack.isEmpty
        case .spreadsheet: sheetHistory.canRedo
        case .html: artifactHistory.canRedo
        }
    }

    private func undo(_ kind: NoteArtifactKind) {
        switch kind {
        case .note: editorController.undo()
        case .canvas:
            if activePageEditor?.canUndo == true { activePageEditor?.undo() }
            else { var value = document.wrappedValue; canvasViewState.undo(&value); document.wrappedValue = value }
        case .spreadsheet: if let value = sheetHistory.undo(current: document.wrappedValue) { document.wrappedValue = value }
        case .html: restoreArtifactCode(artifactHistory.undo(current: currentDocument.html))
        }
    }

    private func redo(_ kind: NoteArtifactKind) {
        switch kind {
        case .note: editorController.redo()
        case .canvas:
            if activePageEditor?.canRedo == true { activePageEditor?.redo() }
            else { var value = document.wrappedValue; canvasViewState.redo(&value); document.wrappedValue = value }
        case .spreadsheet: if let value = sheetHistory.redo(current: document.wrappedValue) { document.wrappedValue = value }
        case .html: restoreArtifactCode(artifactHistory.redo(current: currentDocument.html))
        }
    }

    /// Restores earlier Artifact code. Saved inputs are kept: the store merges
    /// them separately from the code.
    private func restoreArtifactCode(_ html: String?) {
        guard let html else { return }
        var value = document.wrappedValue
        value.html = html
        document.wrappedValue = value
    }

    private func bindSheetDictation() {
        if let window = NSApp.keyWindow, let field = window.firstResponder as? NSTextView, field.isFieldEditor {
            sheetDictation.bind(field, identity: "sheet:\(note.id)")
        } else {
            sheetDictation.unbind()
        }
    }

    /// Starts Page dictation at the end of the text when no text has the cursor yet.
    private func startPageDictation() {
        canvasViewState.focusEndRequest += 1
        Task { @MainActor in
            for _ in 0..<20 {
                if let dictation = activePageEditor?.boundDictationEditor {
                    DictationModel.shared.toggle(editor: dictation)
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private var documentIsEditable: Bool {
        documentCache.isEditable(noteID: note.id, source: draft.content)
    }

    private var currentDocument: NoteDocument {
        document.wrappedValue
    }

    private var databaseLinks: [DatabaseArtifactLink] {
        [currentDocument.databaseLink].compactMap { $0 }
            + currentDocument.blocks.flatMap { block -> [DatabaseArtifactLink] in
                switch block {
                case .table(let table): return [table.databaseLink].compactMap { $0 }
                case .richText(let text): return text.runs.compactMap(\.databaseLink)
                }
            }
    }

    private var hasDatabaseLinks: Bool { !databaseLinks.isEmpty }

    private var databaseLinkSignature: String {
        databaseLinks.map {
            "\($0.sourceID)|\($0.databaseID)|\($0.sqliteQuery ?? "")"
        }.joined(separator: "\n")
    }

    private var linkedDataStatus: String {
        var seen = Set<String>()
        return databaseLinks.compactMap { link -> String? in
            guard let database = model.databasesSnapshot.database(
                sourceID: link.sourceID, databaseID: link.databaseID
            ), seen.insert(database.id).inserted else { return nil }
            return "\(database.name): \(DatabaseFreshness.description(database))"
        }.joined(separator: " · ")
    }

    var body: some View {
        let currentDocument = self.currentDocument
        VStack(spacing: 0) {
            if !embedded {
            HStack(spacing: 8) {
                TextField(
                    currentDocument.kind == .note
                        ? "Untitled Note"
                        : "Untitled \(currentDocument.kind.displayName)",
                    text: title
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
                    .lineLimit(1)
                    .focused($titleFocused)
                    .accessibilityLabel("\(currentDocument.kind.displayName) title")
                    .frame(minWidth: currentDocument.kind == .canvas ? 100 : nil)
                    .layoutPriority(1)
                Spacer()
                if documentIsEditable {
                    Button { undo(currentDocument.kind) } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14)).frame(width: 32, height: 32)
                    }
                    .buttonStyle(WovenIconButtonStyle())
                    .disabled(!canUndo(currentDocument.kind))
                    .help(currentDocument.kind == .html ? "Undo the last code change" : "Undo (⌘Z)").accessibilityLabel("Undo")
                    Button { redo(currentDocument.kind) } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 14)).frame(width: 32, height: 32)
                    }
                    .buttonStyle(WovenIconButtonStyle())
                    .disabled(!canRedo(currentDocument.kind))
                    .help(currentDocument.kind == .html ? "Redo the code change" : "Redo (⇧⌘Z)").accessibilityLabel("Redo")
                }
                Button { showsVersionHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).frame(width: 32, height: 32)
                }.buttonStyle(WovenIconButtonStyle()).help("Version history").accessibilityLabel("Version history")
                DatabaseLinkControl(
                    document: document,
                    snapshot: model.databasesSnapshot
                )
                if hasDatabaseLinks {
                    Button {
                        Task { await refreshLinkedData() }
                    } label: {
                        if isRefreshingLinkedData {
                            ProgressView().controlSize(.small).frame(width: 32, height: 32)
                        } else {
                            LucideIcon(glyph: .rotate, size: 14)
                                .frame(width: 32, height: 32)
                        }
                    }
                    .buttonStyle(WovenIconButtonStyle())
                    .help("Refresh linked data")
                    .disabled(isRefreshingLinkedData)
                }
                if currentDocument.kind == .canvas && documentIsEditable {
                    PageAddComponentButton(inserter: PageComponentInserter(model: model, document: document,
                        viewState: $canvasViewState, folderID: note.folderID))
                }
                if currentDocument.kind != .html && documentIsEditable {
                    Button {
                        showsFormatting.toggle()
                        // Formatting applies to Page text; start in it when none is active.
                        if currentDocument.kind == .canvas, showsFormatting, activePageEditor == nil { canvasViewState.focusEndRequest += 1 }
                    } label: {
                        Image(systemName: "textformat")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(WovenIconButtonStyle())
                    .help("Format \(currentDocument.kind.displayName.lowercased())")
                    .accessibilityLabel("Format \(currentDocument.kind.displayName.lowercased())")
                    switch currentDocument.kind {
                    case .note:
                        DictationMicrophone(editor: dictationEditor, usesNoteToolbarStyle: true)
                    case .canvas:
                        if let dictation = activePageEditor?.boundDictationEditor {
                            DictationMicrophone(editor: dictation, usesNoteToolbarStyle: true)
                        } else {
                            Button { startPageDictation() } label: {
                                Image(systemName: "mic").font(.system(size: 14)).frame(width: 32, height: 32)
                            }
                            .buttonStyle(WovenIconButtonStyle()).help("Dictate on this Mac").accessibilityLabel("Start dictation")
                        }
                    case .spreadsheet:
                        // Dictation goes into the cell being edited when recording stops.
                        DictationMicrophone(editor: sheetDictation, onActivate: bindSheetDictation, usesNoteToolbarStyle: true)
                    case .html:
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 56)

            }

            if showsFormatting && (currentDocument.kind == .note || currentDocument.kind == .canvas) && documentIsEditable {
                NoteFormattingBar(controller: currentDocument.kind == .canvas ? (activePageEditor ?? editorController) : editorController)
                    .disabled(currentDocument.kind == .canvas && (activePageEditor == nil || titleFocused))
                    .padding(.horizontal, 32).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showsFormatting && currentDocument.kind == .spreadsheet && documentIsEditable {
                SpreadsheetFormattingBar(document: sheetDocument)
                    .padding(.horizontal, 32).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if !documentIsEditable {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("This note uses a document format this version cannot edit. Its original data is preserved.")
                                .font(.callout)
                                .foregroundStyle(WovenPalette.mutedForeground)
                            ScrollView {
                                Text(draft.content)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .scrollIndicators(.never)
                        }
                    } else {
                        switch currentDocument.kind {
                        case .note:
                            NoteEditor(document: document, controller: editorController,
                                dictationEditor: dictationEditor, dictationIdentity: note.id,
                                sizesToContent: embedded, onFocus: onEditorFocus)
                                .accessibilityLabel("Note body")
                        case .canvas:
                            PageEditor(model: model, document: document, viewState: $canvasViewState,
                                noteID: note.id, folderID: note.folderID, onOpenAsset: onOpenNote,
                                onOpenSession: onOpenSession, onFocus: { activePageEditor = $0 }, onSectionFocus: { activePageEditor = nil })
                        case .spreadsheet:
                            SpreadsheetEditor(document: sheetDocument)
                                .accessibilityLabel("Sheet")
                        case .html where currentDocument.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                            AppBuildPrompt()
                        case .html:
                            PersistentArtifactView(document: document, linkedDataJSON: linkedDataJSON,
                                savedState: (try? NoteDocument.editableDocument(from: note.content))?.artifactState ?? [:],
                                currentState: {
                                    guard let asset = model.workspaceOverview?.notes.first(where: { $0.id == note.id }) else { return [:] }
                                    return (try? NoteDocument.editableDocument(from: asset.content))?.artifactState ?? [:]
                                },
                                saveState: { model.enqueueArtifactInput(noteID: note.id, edit: $0, after: $1) },
                                reportUnsaved: { model.setArtifactInputsUnsaved(generation: $0, $1) })
                            .accessibilityLabel("App")
                        }
                    }
                }

                if !linkedDataStatus.isEmpty {
                    Text(linkedDataStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(databaseLinks.contains { link in
                            model.databasesSnapshot.database(
                                sourceID: link.sourceID, databaseID: link.databaseID
                            )?.offline == true
                        } ? WovenPalette.warning : WovenPalette.mutedForeground)
                        .lineLimit(1)
                        .help(linkedDataStatus)
                }

                if let linkedDataError {
                    HStack(spacing: 6) {
                        LucideIcon(glyph: .alertTriangle, size: 12)
                        Text(linkedDataError).lineLimit(2)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(WovenPalette.warning)
                }

                if let notice = draft.reconciliationNotice {
                    HStack(alignment: .top, spacing: 8) {
                        Text(notice)
                        Spacer(minLength: 4)
                        Button("Dismiss") { model.dismissNoteReconciliationNotice(noteID: note.id) }
                            .buttonStyle(.plain).underline()
                    }
                    .font(.system(size: 12)).foregroundStyle(WovenPalette.warning)
                    .padding(.horizontal, currentDocument.kind == .canvas ? 24 : 0)
                }
                switch draft.saveState {
                case .failed(let message):
                    HStack(spacing: 6) {
                        LucideIcon(glyph: .alertCircle, size: 12)
                        Text(message)
                            .lineLimit(2)
                        Button("Retry") { model.retryNoteDraft(note: note) }
                            .buttonStyle(.plain)
                            .underline()
                        Button("Save a copy") {
                            Task { await model.preserveCurrentNoteDraftAsCopy(noteID: note.id) }
                        }
                        .buttonStyle(.plain)
                        .underline()
                        .help("Keep your writing in a new note and retain the Mac's current version.")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(WovenPalette.danger)
                case .saved, .saving:
                    EmptyView()
                }
            }
            .frame(
                maxWidth: currentDocument.kind == .note ? 768 : .infinity,
                maxHeight: .infinity,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, embedded || currentDocument.kind == .canvas ? 0 : 32)
            .padding(.bottom, currentDocument.kind == .canvas || currentDocument.kind == .note ? 0 : 24)

            if !embedded && (currentDocument.kind == .note || currentDocument.kind == .canvas) {
                let statistics = NoteTextStatistics(document: currentDocument)
                Button { showsCharacterCount.toggle() } label: {
                    Text(showsCharacterCount
                         ? "\(statistics.characters.formatted()) \(statistics.characters == 1 ? "character" : "characters")"
                         : "\(statistics.words.formatted()) \(statistics.words == 1 ? "word" : "words")")
                        .font(.system(size: 11)).monospacedDigit()
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                }
                .buttonStyle(WovenIconButtonStyle())
                .help(showsCharacterCount ? "Click to show words. Characters include spaces and line breaks."
                                          : "Click to show characters")
                .accessibilityLabel(showsCharacterCount ? "Note character count" : "Note word count")
                .accessibilityValue(showsCharacterCount ? "\(statistics.characters)" : "\(statistics.words)")
                .accessibilityHint(showsCharacterCount ? "Show word count" : "Show character count")
                .frame(maxWidth: .infinity, alignment: .trailing)
                // One bottom gutter keeps the count clear of the scrolling
                // editor without stacking extra space beneath its viewport.
                .padding(.horizontal, 12)
            }
        }
        .disabled(model.noteActionIDs.contains(note.id))
        .background(theme.palette.workspace)
        .disabled(model.noteEditingSuspended)
        .allowsHitTesting(!model.noteEditingSuspended)
        .sheet(isPresented: $showsVersionHistory) { WorkspaceNoteRecovery(model: model, noteID: note.id) }
        .onAppear {
            model.prepareNoteDraft(note)
            if focusesTitleOnAppear {
                titleFocused = true
                onInitialFocusHandled()
            }
        }
        .onChange(of: note) { _, updated in model.prepareNoteDraft(updated) }
        .onChange(of: note.id) { _, _ in
            sheetHistory = SheetUndoHistory(); artifactHistory = ArtifactCodeHistory(); sheetDictation.unbind()
        }
        // Each change to an Artifact's code, usually by an agent, is one undo step.
        .onChange(of: artifactCode) { old, new in
            if let old, let new { artifactHistory.observe(old: old, new: new) }
        }
        .onChange(of: draft.conflictComponentRemaps) { _, remaps in
            if let id = activePageEditor?.selectedBlockID, let copyID = remaps[id] {
                canvasViewState.selected = [copyID]
                canvasViewState.revealCardID = copyID
            }
        }
        .onChange(of: model.databasesSnapshot) { _, _ in
            guard hasDatabaseLinks else { return }
            Task { await refreshLinkedData() }
        }
        .task(id: "\(note.id):\(databaseLinkSignature)") {
            guard hasDatabaseLinks else {
                activeLinkedDataRefreshID = nil
                isRefreshingLinkedData = false
                linkedDataJSON = nil
                linkedDataError = nil
                return
            }
            await refreshLinkedData()
        }
        .onDisappear { sheetDictation.unbind(); Task { _ = await model.flushNoteDrafts() } }
    }

    private func refreshLinkedData() async {
        guard hasDatabaseLinks else { return }
        let refreshID = UUID()
        activeLinkedDataRefreshID = refreshID
        isRefreshingLinkedData = true
        defer {
            if activeLinkedDataRefreshID == refreshID {
                activeLinkedDataRefreshID = nil
                isRefreshingLinkedData = false
            }
        }
        let snapshot = currentDocument
        linkedDataError = nil
        do {
            switch snapshot.kind {
            case .html:
                if let link = snapshot.databaseLink {
                    let data = try await model.linkedData(for: link)
                    guard !Task.isCancelled,
                          activeLinkedDataRefreshID == refreshID,
                          currentDocument.kind == .html,
                          currentDocument.databaseLink == link else { return }
                    linkedDataJSON = data.json
                }
            case .spreadsheet:
                if let link = snapshot.databaseLink {
                    let original = snapshot.blocks.compactMap { block -> NoteTableBlock? in
                        guard case .table(let table) = block else { return nil }
                        return table
                    }.first
                    let data = try await model.linkedData(for: link)
                    guard !Task.isCancelled,
                          activeLinkedDataRefreshID == refreshID else { return }
                    var latest = currentDocument
                    guard latest.kind == .spreadsheet,
                          latest.databaseLink == link,
                          let original,
                          let index = latest.blocks.firstIndex(where: { $0.id == original.id }),
                          case .table(let existing) = latest.blocks[index],
                          existing == original else {
                        linkedDataError = linkedDataChangedMessage
                        return
                    }
                    latest.blocks[index] = .table(data.applying(to: existing))
                    if latest != currentDocument { document.wrappedValue = latest }
                }
            case .note, .canvas:
                var loaded: [(table: NoteTableBlock, data: DatabaseTabularData)] = []
                for block in snapshot.blocks {
                    guard case .table(let table) = block,
                          let link = table.databaseLink ?? snapshot.databaseLink else { continue }
                    let data = try await model.linkedData(for: link)
                    guard !Task.isCancelled,
                          activeLinkedDataRefreshID == refreshID else { return }
                    loaded.append((table, data))
                }
                var values: [(blockID: String, id: String, runs: [NoteTextRun], value: String)] = []
                var scalarQueries: [String: DatabaseTabularData] = [:]
                var valueIDs = Set<String>()
                for block in snapshot.blocks {
                    guard case .richText(let text) = block else { continue }
                    var seen = Set<String>()
                    for run in text.runs {
                        guard let link = run.databaseLink, let id = run.databaseValueID,
                              seen.insert(id).inserted else { continue }
                        let indices = text.runs.indices.filter { text.runs[$0].databaseValueID == id }
                        let expected = indices.map { text.runs[$0] }
                        guard valueIDs.insert(id).inserted,
                              let first = indices.first, let last = indices.last,
                              last - first + 1 == indices.count,
                              expected.allSatisfy({ $0.databaseLink == link }) else {
                            throw InlineDatabaseValueError.conflictingLinks
                        }
                        let key = "\(link.sourceID)|\(link.databaseID)|\(link.sqliteQuery ?? "")"
                        let data: DatabaseTabularData
                        if let cached = scalarQueries[key] {
                            data = cached
                        } else {
                            data = try await model.linkedData(for: link)
                            scalarQueries[key] = data
                        }
                        guard !Task.isCancelled, activeLinkedDataRefreshID == refreshID else { return }
                        guard data.columns.count == 1, data.rows.count == 1, data.rows[0].count == 1 else {
                            throw InlineDatabaseValueError.scalarRequired
                        }
                        let value = data.rows[0][0]
                        guard value.rangeOfCharacter(from: .newlines) == nil else {
                            throw InlineDatabaseValueError.multilineValue
                        }
                        values.append((text.id, id, expected, value))
                    }
                }
                guard activeLinkedDataRefreshID == refreshID else { return }
                var latest = currentDocument
                var skippedChangedTable = false
                for item in loaded {
                    guard let index = latest.blocks.firstIndex(where: { $0.id == item.table.id }),
                          case .table(let existing) = latest.blocks[index],
                          existing == item.table else {
                        skippedChangedTable = true
                        continue
                    }
                    latest.blocks[index] = .table(item.data.applying(to: existing))
                }
                for value in values {
                    guard let index = latest.blocks.firstIndex(where: { $0.id == value.blockID }),
                          case .richText(var text) = latest.blocks[index],
                          text.refreshDatabaseValue(id: value.id, expectedRuns: value.runs, value: value.value) else {
                        skippedChangedTable = true
                        continue
                    }
                    latest.blocks[index] = .richText(text)
                }
                if latest != currentDocument { document.wrappedValue = latest }
                if skippedChangedTable { linkedDataError = linkedDataChangedMessage }
            }
        } catch {
            guard !Task.isCancelled,
                  activeLinkedDataRefreshID == refreshID else { return }
            linkedDataError = error.localizedDescription
        }
    }

    private var linkedDataChangedMessage: String {
        "This note changed while data was loading. Your edits were kept. Refresh again."
    }

}

private enum InlineDatabaseValueError: LocalizedError {
    case scalarRequired
    case multilineValue
    case conflictingLinks

    var errorDescription: String? {
        switch self {
        case .scalarRequired:
            "An inline value needs a query returning exactly one row and one column. Ask your agent to fix the link."
        case .multilineValue:
            "This linked value contains multiple lines. Ask your agent to display it in a table."
        case .conflictingLinks:
            "An inline value has conflicting database links. Ask your agent to fix the link."
        }
    }
}

struct SplitSeparator: View {
    @Environment(\.wovenTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let totalWidth: CGFloat
    let noteOnLeft: Bool
    @Binding var chatWidthPercent: Double
    @State private var hovered = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: WovenMetrics.separatorWidth)
            .overlay {
                Capsule()
                    .fill(dragging ? theme.palette.themeRing : hovered ? theme.palette.themeStrong : theme.palette.border)
                    .frame(width: 2, height: 32)
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("workspace-split"))
                    .onChanged { value in
                        dragging = true
                        updateWidth(dividerCenter: value.location.x)
                    }
                    .onEnded { value in
                        updateWidth(dividerCenter: value.location.x)
                        dragging = false
                    }
            )
            .onTapGesture(count: 2) {
                if reduceMotion {
                    chatWidthPercent = Double(WovenMetrics.defaultChatWidthPercent)
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        chatWidthPercent = Double(WovenMetrics.defaultChatWidthPercent)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize chat and artifact panes")
            .accessibilityValue("Chat \(chatWidthPercent, specifier: "%.1f") percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: commit(chatWidthPercent + 1)
                case .decrement: commit(chatWidthPercent - 1)
                @unknown default: break
                }
            }
            .help("Drag to resize · double-click to reset")
    }

    private func updateWidth(dividerCenter: CGFloat) {
        let contentWidth = max(1, totalWidth - WovenMetrics.separatorWidth)
        let chatPixels = noteOnLeft
            ? totalWidth - dividerCenter - WovenMetrics.separatorWidth / 2
            : dividerCenter - WovenMetrics.separatorWidth / 2
        commit(Double((chatPixels / contentWidth) * 100))
    }

    private func commit(_ proposed: Double) {
        let bounds = chatWidthBounds(totalWidth: totalWidth)
        chatWidthPercent = (min(max(proposed, bounds.lowerBound), bounds.upperBound) * 10).rounded() / 10
    }
}

/// Sheet undo: each local edit is a step, with typing in quick succession
/// merged into one. A change from elsewhere clears the history, so undo never
/// restores an old Sheet over someone else's work.
@MainActor @Observable final class SheetUndoHistory {
    private var undoStack: [NoteDocument] = []
    private var redoStack: [NoteDocument] = []
    @ObservationIgnored private var current: NoteDocument?
    @ObservationIgnored private var lastEdit = Date.distantPast
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func recordLocal(from before: NoteDocument, to after: NoteDocument, at now: Date = .now) {
        guard before.normalized() != after.normalized() else { return }
        // Creating the Sheet's grid when it first opens is not an edit.
        guard before.blocks.contains(where: { if case .table = $0 { true } else { false } }) else { current = after; return }
        if !matches(before) { undoStack.removeAll(); redoStack.removeAll() }
        if undoStack.isEmpty || now.timeIntervalSince(lastEdit) > 1 {
            undoStack.append(before)
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
        lastEdit = now
        redoStack.removeAll()
        current = after
    }

    func undo(current document: NoteDocument) -> NoteDocument? {
        guard matches(document) else { undoStack.removeAll(); redoStack.removeAll(); return nil }
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(document); current = previous; lastEdit = .distantPast
        return previous
    }

    func redo(current document: NoteDocument) -> NoteDocument? {
        guard matches(document) else { undoStack.removeAll(); redoStack.removeAll(); return nil }
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(document); current = next; lastEdit = .distantPast
        return next
    }

    private func matches(_ document: NoteDocument) -> Bool {
        current.map { $0.normalized() == document.normalized() } ?? true
    }
}

/// Artifact undo steps through code changes seen while the Artifact is open,
/// usually an agent's edits. Saved inputs are not part of it.
@MainActor @Observable final class ArtifactCodeHistory {
    private var undoStack: [String] = []
    private var redoStack: [String] = []
    @ObservationIgnored private var restoring: String?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func observe(old: String, new: String) {
        guard old != new else { return }
        if restoring == new { restoring = nil; return }
        restoring = nil
        undoStack.append(old)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo(current: String) -> String? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current); restoring = previous
        return previous
    }

    func redo(current: String) -> String? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current); restoring = next
        return next
    }
}
