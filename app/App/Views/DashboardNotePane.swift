import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterClient
import WovenMatterCore

struct DashboardNotePane: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    let note: WorkspaceNoteRecord
    let showBack: Bool
    let noteOnLeft: Bool
    let isFocused: Bool
    let reservesLeadingRailControlSpace: Bool
    let reservesTrailingRailControlSpace: Bool
    let focusesTitleOnAppear: Bool
    let onInitialFocusHandled: () -> Void
    let onBack: () -> Void
    let onMove: () -> Void
    let onToggleFocus: () -> Void
    let onClose: () -> Void
    @FocusState private var titleFocused: Bool
    @State private var editorController = DashboardNoteEditorController()
    @State private var showsFormatting = false
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
            get: { NoteDocument.decode(model.noteDraft(for: note).content) },
            set: { updated in
                guard let content = try? updated.encoded() else { return }
                model.updateNoteDraft(note: note, content: content)
            }
        )
    }

    private var currentDocument: NoteDocument {
        document.wrappedValue
    }

    private var hasDatabaseLinks: Bool {
        if currentDocument.databaseLink != nil { return true }
        return currentDocument.blocks.contains { block in
            guard case .table(let table) = block else { return false }
            return table.databaseLink != nil
        }
    }

    private var databaseLinkSignature: String {
        let links = [currentDocument.databaseLink]
            + currentDocument.blocks.map { block -> DatabaseArtifactLink? in
                guard case .table(let table) = block else { return nil }
                return table.databaseLink
            }
        return links.compactMap { link in
            link.map {
                "\($0.sourceID)|\($0.databaseID)|\($0.relativePath)|\($0.sqliteQuery ?? "")"
            }
        }.joined(separator: "\n")
    }

    var body: some View {
        let currentDocument = self.currentDocument
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if showBack {
                    Button {
                        model.flushNoteDrafts()
                        onBack()
                    } label: {
                        DashboardLucideIcon(glyph: .arrowLeft, size: 16).frame(width: 32, height: 32)
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                }
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
                }
                if !showBack {
                    Button(action: onMove) {
                        DashboardLucideIcon(glyph: noteOnLeft ? .arrowRight : .arrowLeft, size: 16)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .help(noteOnLeft ? "Move note right" : "Move note left")
                    Button(action: onToggleFocus) {
                        Image(systemName: isFocused
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .help(isFocused ? "Restore chat and note" : "Focus note")
                }
                Button {
                    model.flushNoteDrafts()
                    onClose()
                } label: {
                    DashboardLucideIcon(glyph: noteOnLeft ? .panelLeftClose : .panelRightClose, size: 16)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(DashboardIconButtonStyle())
            }
            .padding(.leading, reservesLeadingRailControlSpace ? 56 : 12)
            .padding(.trailing, reservesTrailingRailControlSpace ? 56 : 12)
            .frame(height: 56)

            if showsFormatting && currentDocument.kind == .note {
                DashboardNoteFormattingBar(controller: editorController)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    switch currentDocument.kind {
                    case .note:
                        DashboardNoteEditor(document: document, controller: editorController)
                            .accessibilityLabel("Note body")
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
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .background(theme.palette.workspace)
        .onAppear {
            model.prepareNoteDraft(note)
            if focusesTitleOnAppear {
                titleFocused = true
                onInitialFocusHandled()
            }
        }
        .onChange(of: note) { _, updated in model.prepareNoteDraft(updated) }
        .task(id: "\(note.id):\(databaseLinkSignature)") {
            guard hasDatabaseLinks else {
                linkedDataJSON = nil
                linkedDataError = nil
                return
            }
            await refreshLinkedData()
        }
        .onDisappear { model.flushNoteDrafts() }
    }

    private func refreshLinkedData() async {
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
            case .note:
                var loaded: [(table: NoteTableBlock, data: DatabaseTabularData)] = []
                for block in snapshot.blocks {
                    guard case .table(let table) = block,
                          let link = table.databaseLink ?? snapshot.databaseLink else { continue }
                    let data = try await model.linkedData(for: link)
                    guard !Task.isCancelled,
                          activeLinkedDataRefreshID == refreshID else { return }
                    loaded.append((table, data))
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
        "The artifact changed while data was loading. Refresh again to avoid overwriting your edits."
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
            .accessibilityLabel("Resize chat and note panes")
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
