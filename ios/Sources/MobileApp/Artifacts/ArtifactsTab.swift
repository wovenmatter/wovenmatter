import SwiftUI
import WovenProtocol

/// The Artifacts tab: the artifact open now (`model.artifactID`), edited in
/// place through the device's own core, or with none open every artifact in
/// the library. The open artifact is remembered across launches.
struct ArtifactsTab: View {
  @Bindable var model: MobileModel
  @SceneStorage("artifacts.open") private var storedID = ""
  @State private var restored = false

  private var record: WorkspaceNoteRecord? {
    model.artifactID.flatMap { id in model.app.workspace.workspaceOverview?.notes.first { $0.id == id } }
  }

  var body: some View {
    Group {
      if let record {
        ArtifactScreen(model: model, record: record).id(record.id)
      } else if model.artifactID != nil, model.app.workspace.workspaceOverview == nil {
        // The library is still being read; the artifact shows once it is listed.
        Color.clear
      } else {
        ArtifactLibrary(model: model)
      }
    }
    .onAppear {
      guard !restored else { return }
      restored = true
      if model.artifactID == nil, !storedID.isEmpty { model.artifactID = storedID }
    }
    .onChange(of: model.artifactID) { _, id in storedID = id ?? "" }
    // An artifact trashed or deleted anywhere closes here.
    .onChange(of: model.app.workspace.workspaceOverview?.notes.map(\.id)) { _, ids in
      if let id = model.artifactID, let ids, !ids.contains(id) { model.artifactID = nil }
    }
  }
}

extension MobileModel {
  /// New Artifact: creates one in this device's library and opens it.
  func createArtifact(_ kind: NoteArtifactKind) {
    Task {
      guard let id = await app.workspace.createNote(folderID: nil, kind: kind) else { return }
      open(artifactID: id)
    }
  }

  /// Back to every artifact.
  func closeArtifact() {
    artifactID = nil
  }
}
