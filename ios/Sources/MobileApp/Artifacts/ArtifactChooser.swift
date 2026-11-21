import SwiftUI
import WovenProtocol

/// Opened from the open artifact's title: its name, every artifact and the
/// other recent ones, and New Artifact.
struct ArtifactChooser: View {
  @Bindable var model: MobileModel
  let record: WorkspaceNoteRecord
  @Environment(\.dismiss) private var dismiss
  @Environment(\.wovenTheme) private var theme
  @State private var title = ""

  private var documents: DocumentsStore { model.app.documents }

  var body: some View {
    NavigationStack {
      List {
        Section("Name") {
          TextField(record.kind.untitledName, text: $title)
            .submitLabel(.done)
            .onSubmit(rename)
            .frame(minHeight: 44)
            .listRowBackground(theme.palette.themeWhisper)
            .accessibilityLabel("\(record.kind.displayName) title")
            .accessibilityIdentifier("artifact-rename")
        }
        Section("Artifacts") {
          Button {
            dismiss()
            model.closeArtifact()
          } label: {
            Label("All artifacts", glyph: .libraryBig).frame(minHeight: 44, alignment: .leading)
          }
          .foregroundStyle(WovenPalette.foreground)
          .listRowBackground(theme.palette.themeWhisper)
          .accessibilityIdentifier("chooser-all-artifacts")
          ForEach(recents) { artifact in
            ArtifactRow(artifact: artifact) {
              dismiss()
              model.open(artifactID: artifact.id)
            }
            .listRowBackground(theme.palette.themeWhisper)
          }
        }
        Section("New Artifact") {
          ForEach(NoteArtifactKind.allCases, id: \.self) { kind in
            Button {
              dismiss()
              model.createArtifact(kind)
            } label: {
              HStack(spacing: 12) {
                ArtifactKindIcon(kind: kind, size: 20).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                  Text(kind.displayName)
                  Text(kind.newArtifactDetail).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
                }
              }
              .frame(minHeight: 44, alignment: .leading)
            }
            .foregroundStyle(WovenPalette.foreground)
            .listRowBackground(theme.palette.themeWhisper)
            .accessibilityIdentifier("chooser-new-\(kind.rawValue)")
          }
        }
      }
      .mobilePageSurface()
      .navigationTitle(record.kind.displayName)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { rename(); dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .onAppear { title = documents.title(of: record) }
    .onDisappear(perform: rename)
  }

  /// The artifacts changed most recently, pinned first, other than this one.
  private var recents: [WorkspaceNoteRecord] {
    (model.app.workspace.workspaceOverview?.notes ?? [])
      .filter { $0.id != record.id }
      .sorted { ($0.isPinned ? 1 : 0, $0.updatedAt ?? .distantPast, $0.id) > ($1.isPinned ? 1 : 0, $1.updatedAt ?? .distantPast, $1.id) }
      .prefix(8).map { $0 }
  }

  /// Renames through the document, so the new title saves with its edits and
  /// shows at once.
  private func rename() {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != documents.title(of: record) else { return }
    documents.updateNote(id: record.id, title: trimmed)
  }
}
