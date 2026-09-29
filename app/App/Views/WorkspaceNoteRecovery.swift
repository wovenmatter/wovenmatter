import SwiftUI
import WovenMatterCore

struct WorkspaceNoteRecovery: View {
    @Bindable var model: ApplicationModel
    let noteID: String
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [NoteAssetVersion] = []
    @State private var selection: String?
    @State private var expectedRevision: String?
    @State private var error: String?
    @State private var restores = false
    @State private var confirmsRestore = false
    @State private var loading = false
    @State private var loadGeneration = UUID()
    @State private var refreshTask: Task<Void, Never>?
    @State private var restoreTask: Task<Void, Never>?

    private var selected: NoteAssetVersion? { versions.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Version history").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Up to 50 versions and 20 MB per document are retained, within a 256 MB workspace limit. Linked external data is not included.")
                .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(versions) { version in
                            Button { selection = version.id } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(version.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text(dateLabel(version.createdAt)).font(.system(size: 11))
                                    Text(sourceLabel(version.source)).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selection == version.id ? DashboardPalette.foreground.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius))
                            }.buttonStyle(.plain).disabled(restores).accessibilityAddTraits(selection == version.id ? .isSelected : [])
                        }
                        if versions.isEmpty { Text("No retained versions.").font(.system(size: 12)) }
                    }
                }.scrollIndicators(.never).frame(width: 190)
                Divider()
                ScrollView {
                    if let selected {
                        let document = NoteDocument.decode(selected.content)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(selected.title).font(.system(size: 15, weight: .medium))
                            Text(String(document.plainText.prefix(65_536)))
                                .font(document.kind == .html ? .system(size: 11, design: .monospaced) : .system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            if document.plainText.count > 65_536 {
                                Text("Preview shortened. Restoring includes the complete retained document.")
                                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            }
                        }
                    }
                }.scrollIndicators(.never).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 330)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger) }
            HStack {
                Button("Refresh") {
                    refreshTask?.cancel()
                    refreshTask = Task { await load() }
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(loading || restores)
                Spacer()
                Button("Restore version") { confirmsRestore = true }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled(selected == nil || expectedRevision == nil || loading || restores)
            }
        }.padding(24).frame(width: 710)
        .foregroundStyle(DashboardPalette.foreground)
        .task(id: noteID) {
            refreshTask?.cancel()
            restoreTask?.cancel()
            restores = false
            confirmsRestore = false
            versions = []
            selection = nil
            error = nil
            await load()
        }
        .onDisappear {
            loadGeneration = UUID()
            refreshTask?.cancel()
            restoreTask?.cancel()
            loading = false
            restores = false
            confirmsRestore = false
        }
        .alert("Restore this version?", isPresented: $confirmsRestore) {
            Button("Cancel", role: .cancel) { }
            Button("Restore") { restore() }
        } message: { Text("This replaces the document's title and content. Its current saved state is retained as a version before restoration.") }
    }

    private func load() async {
        let requestID = UUID()
        loadGeneration = requestID
        loading = true
        expectedRevision = nil
        defer { if loadGeneration == requestID { loading = false } }
        do {
            guard await model.flushNoteDrafts(), let database = model.dashboardStore?.database else {
                throw ApplicationModelError.noteDraftSaveFailed
            }
            try Task.checkCancellation()
            guard loadGeneration == requestID else { return }
            try await model.checkpointNoteForHistory(id: noteID)
            try Task.checkCancellation()
            let revision = try await database.readNoteForEditing(id: noteID).revision
            let fetched = try await database.noteAssetVersions(id: noteID)
            try Task.checkCancellation()
            guard loadGeneration == requestID else { return }
            // Publish the revision and matching list together; a partial or old
            // request must not re-enable restoration with stale evidence.
            expectedRevision = revision
            versions = fetched
            if !versions.contains(where: { $0.id == selection }) { selection = versions.first?.id }
            error = nil
        } catch is CancellationError { }
        catch { if loadGeneration == requestID { self.error = error.localizedDescription } }
    }

    private func restore() {
        guard !loading, !restores, let selected, let expectedRevision else { return }
        let requestID = UUID()
        loadGeneration = requestID
        refreshTask?.cancel()
        restores = true
        restoreTask = Task { @MainActor in
            defer { if loadGeneration == requestID { restores = false } }
            do {
                guard await model.flushNoteDrafts() else { throw ApplicationModelError.noteDraftSaveFailed }
                try Task.checkCancellation()
                guard loadGeneration == requestID else { return }
                let result = try await model.restoreRetainedNote(id: noteID, versionID: selected.id, expectedRevision: expectedRevision)
                // A started write returns its definitive result even when the
                // sheet disappears. Refresh app state, then fence sheet state.
                await Task { @MainActor in await model.adoptNoteEditingResponse(result) }.value
                guard !Task.isCancelled, loadGeneration == requestID else { return }
                restores = false
                await load()
            } catch is CancellationError { }
            catch {
                guard loadGeneration == requestID else { return }
                self.error = error.localizedDescription + " Refresh to review the current document before trying again."
            }
        }
    }

    private func dateLabel(_ value: String) -> String {
        (try? WorkspaceAgentToolsModel.date(value))?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
    private func sourceLabel(_ value: String) -> String {
        switch value {
        case "created": "Created"
        case "editor", "editor-checkpoint": "Editor checkpoint"
        case "agent": "Agent edit"
        case "before-agent-edit": "Before agent edit"
        case "restore": "Restored version"
        case "before-restore": "Before restoration"
        default: value
        }
    }
}
