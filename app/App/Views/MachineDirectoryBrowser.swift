import SwiftUI

/// Chooses a directory on another machine. `load` lists the directories inside
/// a path, or inside the machine's home when the path is nil.
struct MachineDirectoryBrowser: View {
    let workspaceTitle: String
    let load: @MainActor (String?) async throws -> MachineDirectoryListing
    let initialPath: String?
    let onChoose: (String) -> Void
    let onBack: () -> Void
    @State private var listing: MachineDirectoryListing?
    @State private var typedPath = ""
    @State private var filter = ""
    @State private var loading = false
    @State private var error: String?
    @State private var request = UUID()
    @FocusState private var focusedField: Field?
    @Environment(\.wovenTheme) private var theme

    private enum Field { case path, filter }

    private var shownDirectories: [MachineDirectoryListing.Directory] {
        guard let listing else { return [] }
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? listing.directories
            : listing.directories.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Return in a field with text acts on that field, not on Choose.
    private var choosesOnReturn: Bool {
        switch focusedField {
        case .path: typedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .filter: filter.trimmingCharacters(in: .whitespaces).isEmpty
        case nil: true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Directory").font(.system(size: 14, weight: .semibold))
            Text(workspaceTitle)
                .font(.system(size: 11.5))
                .foregroundStyle(WovenPalette.mutedForeground)
            HStack(spacing: 6) {
                Button { Task { await open(listing?.parent) } } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 0, minimumHeight: 26, idleFill: false))
                .accessibilityLabel("Up")
                .disabled(listing?.parent == nil || loading)
                Text(listing?.path ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            TextField("Go to a directory, such as /srv/projects", text: $typedPath)
                .focused($focusedField, equals: .path)
                .quietTextInput()
                .onSubmit { Task { await goToTypedPath() } }
            TextField("Filter", text: $filter)
                .focused($focusedField, equals: .filter)
                .quietTextInput()
                .onSubmit {
                    if shownDirectories.count == 1 { Task { await open(shownDirectories[0].path) } }
                }
                .disabled(listing == nil)
            directoryList
            if listing != nil, let error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(WovenPalette.danger)
            }
            if listing?.truncated == true {
                Text("Showing the first 500. Type a directory above to go further.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            HStack {
                Spacer()
                Button("Back", action: onBack).keyboardShortcut(.cancelAction)
                Button("Choose") { if let listing { onChoose(listing.path) } }
                    .keyboardShortcut(choosesOnReturn ? .defaultAction : nil)
                    .disabled(listing == nil || loading)
            }
        }
        .formFocusDismissal { focusedField = nil }
        .task {
            await open(initialPath)
            // A directory that is gone starts the browser at home instead.
            if listing == nil, initialPath != nil { await open(nil) }
        }
    }

    /// The directories of the current listing, or why there are none, in a fixed-height box.
    private var directoryList: some View {
        let directories = shownDirectories
        return Group {
            if !directories.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(directories) { directory in
                            Button { Task { await open(directory.path) } } label: {
                                HStack(spacing: 8) {
                                    LucideIcon(glyph: .folder, size: 14)
                                        .foregroundStyle(WovenPalette.mutedForeground)
                                    Text(directory.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 26, idleFill: false))
                        }
                    }
                    .padding(4)
                    .disabled(loading)
                }
                .scrollIndicators(.never)
            } else {
                Text(emptyMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(listing == nil && error != nil ? WovenPalette.danger : WovenPalette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .overlay {
            RoundedRectangle(cornerRadius: WovenMetrics.controlRadius)
                .stroke(theme.palette.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var emptyMessage: String {
        guard let listing else { return error ?? "Loading…" }
        return listing.directories.isEmpty ? "No directories here" : "No matches"
    }

    private func goToTypedPath() async {
        let path = typedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        guard path.hasPrefix("/") else {
            error = "Type the full path, starting with /."
            return
        }
        if await open(path) { typedPath = "" }
    }

    /// Lists `path`; a reply to an earlier request is dropped.
    @discardableResult
    private func open(_ path: String?) async -> Bool {
        let id = UUID()
        request = id
        loading = true
        error = nil
        defer { if request == id { loading = false } }
        do {
            let next = try await load(path)
            guard request == id, !Task.isCancelled else { return false }
            listing = next
            filter = ""
            return true
        } catch {
            guard request == id, !Task.isCancelled else { return false }
            self.error = error.localizedDescription
            return false
        }
    }
}
