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
                            }.buttonStyle(.plain).accessibilityAddTraits(selection == version.id ? .isSelected : [])
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
                Button("Refresh") { load() }.buttonStyle(SettingsQuietButtonStyle())
                Spacer()
                Button("Restore version") { confirmsRestore = true }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled(selected == nil || expectedRevision == nil || restores)
            }
        }.padding(24).frame(width: 710)
        .foregroundStyle(DashboardPalette.foreground)
        .onAppear { load() }
        .alert("Restore this version?", isPresented: $confirmsRestore) {
            Button("Cancel", role: .cancel) { }
            Button("Restore") { restore() }
        } message: { Text("This replaces the document's title and content. Its current saved state is retained as a version before restoration.") }
    }

    private func load() {
        do {
            guard model.flushNoteDrafts(), let database = model.dashboardStore?.database else {
                throw ApplicationModelError.noteDraftSaveFailed
            }
            try database.checkpointNote(id: noteID)
            expectedRevision = try database.readNoteForEditing(id: noteID).revision
            versions = try database.noteAssetVersions(id: noteID)
            if !versions.contains(where: { $0.id == selection }) { selection = versions.first?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func restore() {
        guard let selected, let expectedRevision, let database = model.dashboardStore?.database else { return }
        restores = true
        Task { @MainActor in
            defer { restores = false }
            do {
                guard model.flushNoteDrafts() else { throw ApplicationModelError.noteDraftSaveFailed }
                let result = try database.restoreNoteAssetVersion(noteID: noteID, versionID: selected.id, expectedRevision: expectedRevision)
                await model.adoptNoteEditingResponse(result)
                load()
            } catch { self.error = error.localizedDescription + " Refresh to review the current document before trying again." }
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
