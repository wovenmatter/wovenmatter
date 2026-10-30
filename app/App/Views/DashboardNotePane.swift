import AppKit
import SwiftUI
import WovenMatterCore

struct DashboardNotePane: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    let note: WorkspaceNoteRecord
    let focusesTitleOnAppear: Bool
    let onInitialFocusHandled: () -> Void
    let onOpenNote: (String) -> Void
    @FocusState private var titleFocused: Bool
    @State private var editorController = DashboardNoteEditorController()
    @State private var dictationEditor = DictationEditor()
    @State private var documentCache = DashboardNoteDocumentCache()
    @State private var canvasViewState = DashboardCanvasViewState()
    @State private var showsFormatting = false
    @State private var showsVersionHistory = false
    @State private var showsCharacterCount = false
    @State private var linkedDataJSON: String?
    @State private var linkedDataError: String?
    @State private var isRefreshingLinkedData = false
    @State private var activeLinkedDataRefreshID: UUID?

    private var draft: DashboardNoteDraft {
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
            return "\(database.name): \(DashboardDatabaseFreshness.description(database))"
        }.joined(separator: " · ")
    }

    var body: some View {
        let currentDocument = self.currentDocument
        VStack(spacing: 0) {
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
                    .accessibilityLabel("Note title")
                    .layoutPriority(1)
                Spacer()
                if currentDocument.kind == .note {
                    Button { editorController.undo() } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 14)).frame(width: 32, height: 32)
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .disabled(!editorController.canUndo)
                    .help("Undo (⌘Z)").accessibilityLabel("Undo")
                    Button { editorController.redo() } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.system(size: 14)).frame(width: 32, height: 32)
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .disabled(!editorController.canRedo)
                    .help("Redo (⇧⌘Z)").accessibilityLabel("Redo")
                }
                if currentDocument.kind == .canvas && documentIsEditable {
                    DashboardCanvasControls(document: document, viewState: $canvasViewState,
                        assets: (model.workspaceOverview?.notes ?? []).filter { $0.id != note.id },
                        canOpenAssets: true)
                        .disabled(model.noteEditingSuspended)
                }
                Button { showsVersionHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).frame(width: 32, height: 32)
                }.buttonStyle(DashboardIconButtonStyle()).help("Version history").accessibilityLabel("Version history")
                DashboardDatabaseLinkControl(
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
                            DashboardLucideIcon(glyph: .rotate, size: 14)
                                .frame(width: 32, height: 32)
                        }
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .help("Refresh linked data")
                    .disabled(isRefreshingLinkedData)
                }
                if currentDocument.kind == .note {
                    Button {
                        showsFormatting.toggle()
                    } label: {
                        Image(systemName: "textformat")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .help("Format note")
                    DictationMicrophone(editor: dictationEditor, usesNoteToolbarStyle: true)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 56)

            if showsFormatting && currentDocument.kind == .note && documentIsEditable {
                DashboardNoteFormattingBar(controller: editorController)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if !documentIsEditable {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("This note uses a document format this version cannot edit. Its original data is preserved.")
                                .font(.callout)
                                .foregroundStyle(DashboardPalette.mutedForeground)
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
                            DashboardNoteEditor(document: document, controller: editorController,
                                dictationEditor: dictationEditor, dictationIdentity: note.id)
                                .accessibilityLabel("Note body")
                        case .canvas:
                            DashboardCanvasEditor(document: document,
                                assets: (model.workspaceOverview?.notes ?? []).filter { $0.id != note.id },
                                onOpenAsset: onOpenNote, viewState: $canvasViewState)
                        case .spreadsheet:
                            DashboardSpreadsheetEditor(document: document)
                                .accessibilityLabel("Spreadsheet")
                        case .html:
                            DashboardHTMLArtifactView(
                                html: currentDocument.html,
                                linkedDataJSON: linkedDataJSON
                            )
                            .accessibilityLabel("HTML artifact")
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
                        } ? DashboardPalette.warning : DashboardPalette.mutedForeground)
                        .lineLimit(1)
                        .help(linkedDataStatus)
                }

                if let linkedDataError {
                    HStack(spacing: 6) {
                        DashboardLucideIcon(glyph: .alertTriangle, size: 12)
                        Text(linkedDataError).lineLimit(2)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardPalette.warning)
                }

                switch draft.saveState {
                case .failed(let message):
                    HStack(spacing: 6) {
                        DashboardLucideIcon(glyph: .alertCircle, size: 12)
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
                    .foregroundStyle(DashboardPalette.danger)
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
            .padding(.horizontal, currentDocument.kind == .canvas ? 0 : 32)
            .padding(.bottom, currentDocument.kind == .canvas || currentDocument.kind == .note ? 0 : 24)

            if currentDocument.kind == .note {
                let statistics = DashboardNoteTextStatistics(document: currentDocument)
                Button { showsCharacterCount.toggle() } label: {
                    Text(showsCharacterCount
                         ? "\(statistics.characters.formatted()) \(statistics.characters == 1 ? "character" : "characters")"
                         : "\(statistics.words.formatted()) \(statistics.words == 1 ? "word" : "words")")
                        .font(.system(size: 11)).monospacedDigit()
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                }
                .buttonStyle(DashboardIconButtonStyle())
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
        .sheet(isPresented: $showsVersionHistory) { WorkspaceNoteRecovery(model: model, noteID: note.id) }
        .onAppear {
            model.prepareNoteDraft(note)
            if focusesTitleOnAppear {
                titleFocused = true
                onInitialFocusHandled()
            }
        }
        .onChange(of: note) { _, updated in model.prepareNoteDraft(updated) }
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
        .onDisappear { Task { _ = await model.flushNoteDrafts() } }
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
                            throw DashboardInlineDatabaseValueError.conflictingLinks
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
                            throw DashboardInlineDatabaseValueError.scalarRequired
                        }
                        let value = data.rows[0][0]
                        guard value.rangeOfCharacter(from: .newlines) == nil else {
                            throw DashboardInlineDatabaseValueError.multilineValue
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

private enum DashboardInlineDatabaseValueError: LocalizedError {
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

struct DashboardSplitSeparator: View {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let totalWidth: CGFloat
    let noteOnLeft: Bool
    @Binding var chatWidthPercent: Double
    @State private var hovered = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: DashboardMetrics.separatorWidth)
            .overlay {
                Capsule()
                    .fill(dragging ? theme.palette.themeRing : hovered ? theme.palette.themeStrong : theme.palette.border)
                    .frame(width: 2, height: 32)
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("dashboard-workspace-split"))
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
                    chatWidthPercent = Double(DashboardMetrics.defaultChatWidthPercent)
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        chatWidthPercent = Double(DashboardMetrics.defaultChatWidthPercent)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize chat and asset panes")
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
        let contentWidth = max(1, totalWidth - DashboardMetrics.separatorWidth)
        let chatPixels = noteOnLeft
            ? totalWidth - dividerCenter - DashboardMetrics.separatorWidth / 2
            : dividerCenter - DashboardMetrics.separatorWidth / 2
        commit(Double((chatPixels / contentWidth) * 100))
    }

    private func commit(_ proposed: Double) {
        let bounds = dashboardChatWidthBounds(totalWidth: totalWidth)
        chatWidthPercent = (min(max(proposed, bounds.lowerBound), bounds.upperBound) * 10).rounded() / 10
    }
}
