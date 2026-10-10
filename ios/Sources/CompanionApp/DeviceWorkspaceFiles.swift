import SwiftUI
import UniformTypeIdentifiers

struct DeviceWorkspaceFiles: View {
  @Bindable var model: CompanionModel
  let conversationID: String
  @Environment(\.dismiss) private var dismiss
  @State private var files: [URL] = []
  @State private var importing = false
  @State private var status: String?
  @State private var busy = false
  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("These working files stay on this device. Save an output to the library to synchronize it with your central Mac.")
            .font(.subheadline).foregroundStyle(DashboardPalette.mutedForeground)
          Button("Import files", systemImage: "square.and.arrow.down") { importing = true }
        }
        Section("Workspace files") {
          ForEach(files, id: \.path) { file in
            VStack(alignment: .leading, spacing: 8) {
              Text(file.lastPathComponent).font(.headline)
              HStack {
                ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                Spacer()
                Button("Save to library") { saveArtifact(file) }.disabled(busy)
              }.font(.subheadline)
            }.padding(.vertical, 6)
          }
          if files.isEmpty { Text("No files in this workspace yet.").foregroundStyle(DashboardPalette.mutedForeground) }
        }
        if let status { Section { Text(status).font(.caption) } }
      }.scrollIndicators(.never).navigationTitle("Workspace files").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
          do {
            for source in try result.get() {
              let granted = source.startAccessingSecurityScopedResource(); defer { if granted { source.stopAccessingSecurityScopedResource() } }
              let name = source.lastPathComponent
              var destination = try model.deviceWorkspaceURL(conversationID: conversationID, path: name)
              if FileManager.default.fileExists(atPath: destination.path) {
                destination = try model.deviceWorkspaceURL(conversationID: conversationID, path: UUID().uuidString.prefix(8) + "-" + name)
              }
              try FileManager.default.copyItem(at: source, to: destination)
            }
            refresh()
          } catch { status = error.localizedDescription }
        }.task { refresh() }
    }
  }
  private func refresh() {
    do {
      let root = try model.deviceWorkspaceURL(conversationID: conversationID, path: "", directory: true)
      let values = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
      files = (values?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch { status = error.localizedDescription }
  }
  private func saveArtifact(_ file: URL) {
    busy = true
    Task {
      do {
        guard let store = model.store else { throw CancellationError() }
        let data = try Data(contentsOf: file)
        _ = try await store.artifacts.save(data: data, workspaceID: model.deviceWorkspaceID, title: file.lastPathComponent,
          mediaType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
        status = "Saved to the library on this device. Central synchronization is queued."
      } catch { status = error.localizedDescription }
      busy = false
    }
  }
}
