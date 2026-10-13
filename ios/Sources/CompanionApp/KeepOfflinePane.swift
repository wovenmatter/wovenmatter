import SwiftUI
import QuickLook
import CompanionClient
import WovenMatterCompanion

struct KeepOfflinePane: View {
  @Bindable var model: CompanionModel
  @State private var artifacts: [CompanionArtifactManifest] = []
  @State private var search = ""
  var body: some View {
    List {
      Section("Conversations") {
        ForEach(model.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { conversation in
          ChatOfflineToggle(model: model, conversationID: conversation.id, title: conversation.title)
        }
      }
      Section("Saved artifacts") {
        ForEach(artifacts.filter { !$0.deleted && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { item in
          ArtifactOfflineToggle(model: model, artifact: item)
        }
      }
    }.searchable(text: $search, prompt: "Conversations and saved artifacts")
      .mobileNavigationPage("Keep Offline")
      .task(id: model.state.cursor) { artifacts = await model.store?.artifacts.manifests().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } ?? [] }
  }
}

struct ChatOfflineToggle: View {
  @Bindable var model: CompanionModel
  let conversationID: String
  var title = "Keep Offline"
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Toggle(title, isOn: Binding(get: { model.state.pinnedTranscriptIDs?.contains(conversationID) == true },
        set: { value in Task { await model.setChatKeptOffline(conversationID, value) } }))
        .disabled(model.offlineOperationIDs.contains("chat:" + conversationID))
      Text(model.chatOfflineLabel(conversationID)).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
      if let problem = model.offlineProblems["chat:" + conversationID] {
        Text(problem).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
      }
    }
  }
}

struct ArtifactOfflineToggle: View {
  @Bindable var model: CompanionModel
  let artifact: CompanionArtifactManifest
  @State private var status: SavedArtifactOfflineStatus?
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Toggle(artifact.title, isOn: Binding(get: { status?.isPinned == true }, set: { value in
        Task { await model.setArtifactKeptOffline(artifact.id, value); await refresh() }
      })).disabled(model.offlineOperationIDs.contains("artifact:" + artifact.id))
      Text(status?.isAvailable == true ? "Available on this device" : "Download when connected")
        .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
      if let problem = model.offlineProblems["artifact:" + artifact.id] {
        Text(problem).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
      }
    }.task { await refresh() }.onChange(of: model.synchronizationStatus) { Task { await refresh() } }
  }
  private func refresh() async { status = await model.store?.artifacts.offlineStatus(id: artifact.id) }
}

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
        ArtifactOfflineToggle(model: model, artifact: artifact)
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
