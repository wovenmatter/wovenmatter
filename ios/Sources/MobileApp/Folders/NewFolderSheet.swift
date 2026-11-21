import SwiftUI
import WovenProtocol

/// A new folder, made by the workspace that will own it. On this device a
/// name is enough: the core gives it a directory of its own. On a machine
/// the folder is a new blank directory there, or links one of its existing
/// directories, browsed through its own server as the Mac's New Folder does.
struct NewFolderSheet: View {
    let model: MobileModel
    let owner: FolderOwner
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var linksExisting = false
    @State private var listing: MachineDirectoryListing?
    @State private var chosen: String?
    @State private var filter = ""
    @State private var path = ""
    @State private var browsing = false
    @State private var error: String?
    @State private var creating = false
    @FocusState private var nameFocused: Bool

    private var workspace: WorkspaceStore { model.app.workspace }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canCreate: Bool {
        guard !creating, !trimmedName.isEmpty else { return false }
        return linksExisting ? chosen != nil : !trimmedName.contains("/") && trimmedName != "." && trimmedName != ".."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !owner.isDevice {
                        WovenSegmentedSelector(options: [false, true], selection: $linksExisting) {
                            $0 ? "Link Existing" : "Create New"
                        }
                        .accessibilityIdentifier("folders-new-folder-mode")
                    }
                    TextField("Folder name", text: $name)
                        .wovenInput()
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { if canCreate { create() } }
                        .accessibilityIdentifier("folders-new-folder-name")
                    if linksExisting { browser }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(WovenPalette.danger)
                            .accessibilityIdentifier("folders-new-folder-error")
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.never)
            .mobilePageSurface()
            .navigationTitle("New Folder")
            .navigationSubtitle(owner.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(linksExisting ? "Link" : "Create", action: create)
                        .disabled(!canCreate)
                        .accessibilityIdentifier("folders-new-folder-create")
                }
            }
        }
        .presentationDetents(linksExisting ? [.large] : [.medium, .large])
        .interactiveDismissDisabled(creating)
        .task { nameFocused = true }
        .task(id: linksExisting) {
            if linksExisting, listing == nil { await browse(nil) }
        }
    }

    /// The machine's directories, one level at a time, from its home directory.
    private var browser: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let listing {
                HStack(spacing: 8) {
                    Button { Task { await browse(listing.parent) } } label: {
                        LucideIcon(glyph: .arrowLeft, size: 16).frame(width: 44, height: 44)
                    }
                    .buttonStyle(WovenIconButtonStyle())
                    .disabled(listing.parent == nil || browsing)
                    .accessibilityLabel("Up one directory")
                    // The directory shown; typing a full path goes there, as on the Mac.
                    TextField("Directory", text: $path)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { Task { await browse(path) } }
                        .wovenInput()
                        .accessibilityIdentifier("folders-new-folder-path")
                    if browsing { ProgressView().controlSize(.small) }
                }
                Button {
                    chosen = listing.path
                    if trimmedName.isEmpty { name = (listing.path as NSString).lastPathComponent }
                } label: {
                    FolderRowLabel(title: chosen == listing.path ? "Using this directory" : "Use this directory") {
                        FolderGlyph(glyph: chosen == listing.path ? .check : .folderOpen)
                    }
                }
                .buttonStyle(FolderRowButtonStyle())
                .disabled(browsing)
                .accessibilityIdentifier("folders-new-folder-use")
                if listing.directories.count > 8 {
                    WovenSearchField(text: $filter, prompt: "Find a directory here")
                        .textInputAutocapitalization(.never)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(listing.directories.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { directory in
                        Button { Task { await browse(directory.path) } } label: {
                            FolderRowLabel(title: directory.name) { FolderGlyph(glyph: .folder) }
                        }
                        .buttonStyle(FolderRowButtonStyle())
                        .disabled(browsing)
                    }
                }
            } else if browsing {
                ProgressView().frame(maxWidth: .infinity, minHeight: 88)
            }
            if let chosen {
                Text("Selected: \(chosen)").font(.caption).foregroundStyle(WovenPalette.mutedForeground)
                    .textSelection(.enabled)
            }
        }
    }

    private func browse(_ path: String?) async {
        browsing = true
        defer { browsing = false }
        do {
            let listing = try await workspace.directories(on: owner.id, path: path)
            self.listing = listing
            self.path = listing.path
            filter = ""
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() {
        guard canCreate else { return }
        creating = true
        let root = linksExisting ? chosen.map { URL(fileURLWithPath: $0, isDirectory: true) } : nil
        Task {
            defer { creating = false }
            if await workspace.createFolder(name: trimmedName, machineID: owner.id, externalRoot: root) != nil {
                dismiss()
            } else {
                error = workspace.folderMutationError ?? "The folder could not be made."
                workspace.clearFolderMutationError()
            }
        }
    }
}
