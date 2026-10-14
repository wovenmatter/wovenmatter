import SwiftUI
import QuickLook
import CompanionClient
import WovenMatterCompanion

struct SavedArtifactDetailsPane: View {
  @Bindable var model: CompanionModel
  let artifact: CompanionArtifactManifest
  @State private var preview: URL?
  @State private var opening = false
  @State private var failure: String?
  var body: some View {
    List {
      Section {
        Button(opening ? "Opening…" : "Open") { Task { await open() } }.disabled(opening)
      }
      if let failure { Text(failure).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
    }.mobileNavigationPage(artifact.title).quickLookPreview($preview)
  }
  private func open() async {
    opening = true; failure = nil; defer { opening = false }
    do {
      let source = try await model.artifactURL(artifact.id)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedArtifact-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let name = URL(fileURLWithPath: artifact.title).lastPathComponent
      let target = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "Artifact" : name)
      try FileManager.default.copyItem(at: source, to: target); preview = target
    } catch { failure = error.localizedDescription }
  }
}
