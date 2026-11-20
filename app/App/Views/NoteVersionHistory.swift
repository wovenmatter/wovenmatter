import SwiftUI

/// A note's retained versions, including the side that lost when two machines
/// edited it apart.
struct NoteVersionHistory: View {
    @Bindable var model: ApplicationModel
    let noteID: String
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [NoteVersion] = []
    @State private var selection: String?
    @State private var error: String?
    @State private var restores = false
    @State private var confirmsRestore = false
    @State private var loading = false
    @State private var loadGeneration = UUID()
    @State private var refreshTask: Task<Void, Never>?
    @State private var restoreTask: Task<Void, Never>?

    private var selected: NoteVersion? { versions.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Version history").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Up to 50 versions and 20 MB per document are retained, within a 256 MB workspace limit. Linked external data is not included.")
                .font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(versions) { version in
                            Button { selection = version.id } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(version.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text(version.savedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11))
                                    Text(version.source.displayName).font(.system(size: 11)).foregroundStyle(WovenPalette.mutedForeground)
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selection == version.id ? WovenPalette.foreground.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius))
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
                                    .font(.system(size: 11)).foregroundStyle(WovenPalette.mutedForeground)
                            }
                        }
                    }
                }.scrollIndicators(.never).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 330)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(WovenPalette.danger) }
            HStack {
                Button("Refresh") {
                    refreshTask?.cancel()
                    refreshTask = Task { await load() }
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(loading || restores)
                Spacer()
                Button("Restore version") { confirmsRestore = true }
                    .buttonStyle(WovenPrimaryButtonStyle())
                    .disabled(selected == nil || loading || restores)
            }
        }.padding(24).frame(width: 710)
        .foregroundStyle(WovenPalette.foreground)
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
        defer { if loadGeneration == requestID { loading = false } }
        do {
            let fetched = try await model.documents.versions(noteID: noteID)
            try Task.checkCancellation()
            guard loadGeneration == requestID else { return }
            versions = fetched
            if !versions.contains(where: { $0.id == selection }) { selection = versions.first?.id }
            error = nil
        } catch is CancellationError { }
        catch { if loadGeneration == requestID { self.error = error.localizedDescription } }
    }

    private func restore() {
        guard !loading, !restores, let selected else { return }
        let requestID = UUID()
        loadGeneration = requestID
        refreshTask?.cancel()
        restores = true
        restoreTask = Task { @MainActor in
            defer { if loadGeneration == requestID { restores = false } }
            do {
                try await model.documents.restoreVersion(noteID: noteID, versionID: selected.id)
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
}
