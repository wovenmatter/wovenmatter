import SwiftUI
import WovenProtocol

/// An artifact's retained versions, newest first, including the side that
/// lost when two machines edited it apart. Restoring keeps the current
/// document as a version first.
struct ArtifactVersionHistory: View {
  @Bindable var model: MobileModel
  let artifactID: String
  @Environment(\.dismiss) private var dismiss
  @Environment(\.wovenTheme) private var theme
  @State private var versions: [NoteVersion] = []
  @State private var loaded = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      List {
        ForEach(versions) { version in
          NavigationLink(value: version.id) {
            VStack(alignment: .leading, spacing: 3) {
              Text(version.title.isEmpty ? "Untitled" : version.title).font(.body.weight(.medium)).lineLimit(1)
              Text(version.savedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
              Text(version.source.displayName).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
            }
            .frame(minHeight: 44, alignment: .leading)
          }
          .listRowBackground(theme.palette.themeWhisper)
          .accessibilityIdentifier("version-\(version.id)")
        }
        if loaded && versions.isEmpty {
          Text("No retained versions.").foregroundStyle(WovenPalette.mutedForeground)
            .listRowBackground(Color.clear)
        }
        if let error {
          Text(error).font(.callout).foregroundStyle(WovenPalette.danger).listRowBackground(Color.clear)
        }
      }
      .refreshable { await load() }
      .mobilePageSurface()
      .navigationTitle("Version history")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .navigationDestination(for: String.self) { id in
        if let version = versions.first(where: { $0.id == id }) {
          ArtifactVersionPreview(model: model, artifactID: artifactID, version: version) { dismiss() }
        }
      }
      .task { await load() }
    }
  }

  private func load() async {
    do {
      versions = try await model.app.documents.versions(noteID: artifactID)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
    loaded = true
  }
}

/// One retained version as it reads, with Restore.
private struct ArtifactVersionPreview: View {
  @Bindable var model: MobileModel
  let artifactID: String
  let version: NoteVersion
  let restored: () -> Void
  @State private var confirms = false
  @State private var restoring = false
  @State private var error: String?

  var body: some View {
    let document = NoteDocument.decode(version.content)
    let text = document.kind == .spreadsheet ? document.spreadsheetTable.plainText : document.plainText
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text(version.title.isEmpty ? "Untitled" : version.title).font(.title3.weight(.semibold))
        Text("\(version.source.displayName) · \(version.savedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).foregroundStyle(WovenPalette.mutedForeground)
        Text(String(text.prefix(65_536)))
          .font(document.kind == .html ? .system(.caption, design: .monospaced) : .body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
        if text.count > 65_536 {
          Text("Preview shortened. Restoring includes the complete retained document.")
            .font(.caption).foregroundStyle(WovenPalette.mutedForeground)
        }
        if let error { Text(error).font(.callout).foregroundStyle(WovenPalette.danger) }
      }
      .padding(20)
    }
    .mobilePageSurface()
    .navigationTitle("Version")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Restore") { confirms = true }.disabled(restoring).accessibilityIdentifier("version-restore")
      }
    }
    .alert("Restore this version?", isPresented: $confirms) {
      Button("Cancel", role: .cancel) {}
      Button("Restore") { restore() }
    } message: {
      Text("This replaces the document's title and content. Its current saved state is retained as a version before restoration.")
    }
  }

  private func restore() {
    restoring = true
    Task {
      defer { restoring = false }
      do {
        try await model.app.documents.restoreVersion(noteID: artifactID, versionID: version.id)
        restored()
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
