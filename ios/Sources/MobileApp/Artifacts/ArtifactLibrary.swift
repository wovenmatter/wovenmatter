import SwiftUI
import WovenProtocol

/// Every artifact in the library, pinned first and then the most recently
/// changed, with the Mac's type filter and a search. Opening one shows it in
/// the tab.
struct ArtifactLibrary: View {
  @Bindable var model: MobileModel
  @Environment(\.wovenTheme) private var theme
  @State private var search = ""
  @State private var kind: NoteArtifactKind?

  private var workspace: WorkspaceStore { model.app.workspace }

  var body: some View {
    VStack(spacing: 0) {
      TabRootHeader(title: "Artifacts") {
        Menu {
          Section("New Artifact") { NewArtifactMenuItems { model.createArtifact($0) } }
        } label: {
          LucideIcon(glyph: .plus, size: 20).frame(width: 44, height: 44)
        }
        .accessibilityLabel("New Artifact")
        .accessibilityIdentifier("artifacts-new")
      }
      List {
        Section {
          WovenSearchField(text: $search, prompt: "Search artifacts")
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
          filters
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        ForEach(artifacts) { artifact in
          ArtifactRow(artifact: artifact) { model.open(artifactID: artifact.id) }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowSeparator(.hidden)
            .swipeActions(edge: .leading) {
              Button(artifact.isPinned ? "Unpin" : "Pin") { mutate(artifact, .setPinned(!artifact.isPinned)) }
                .tint(theme.palette.themeAccent)
            }
            .swipeActions(edge: .trailing) {
              Button("Move to Trash", role: .destructive) { mutate(artifact, .moveToTrash) }
            }
            .contextMenu {
              Button { mutate(artifact, .setPinned(!artifact.isPinned)) } label: {
                Label(artifact.isPinned ? "Unpin" : "Pin", glyph: .pin)
              }
              Button(role: .destructive) { mutate(artifact, .moveToTrash) } label: { Label("Move to Trash", glyph: .trash) }
            }
        }
        if workspace.workspaceOverview != nil && artifacts.isEmpty {
          Text(search.isEmpty ? "No artifacts." : "No matching artifacts.")
            .font(.callout).foregroundStyle(WovenPalette.mutedForeground)
            .frame(maxWidth: .infinity, minHeight: 88)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("artifacts-empty")
        }
        if let error = workspace.noteMutationError {
          Text(error).font(.caption).foregroundStyle(WovenPalette.danger)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
      .scrollDismissesKeyboard(.immediately)
      .contentMargins(.bottom, 24, for: .scrollContent)
    }
  }

  /// Pinned first, then the most recently changed.
  private var artifacts: [WorkspaceNoteRecord] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return (workspace.workspaceOverview?.notes ?? [])
      .filter { kind == nil || $0.kind == kind }
      .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query) }
      .sorted { ($0.isPinned ? 1 : 0, $0.updatedAt ?? .distantPast, $0.id) > ($1.isPinned ? 1 : 0, $1.updatedAt ?? .distantPast, $1.id) }
  }

  private var filters: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        chip("All", selected: kind == nil) { kind = nil }
        ForEach(NoteArtifactKind.allCases, id: \.self) { value in
          chip(value.pluralName, selected: kind == value) { kind = kind == value ? nil : value }
        }
      }
      .padding(.horizontal, 16)
    }
    .scrollIndicators(.never)
  }

  private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
        .background(selected ? theme.palette.themeSoft : theme.palette.themeWhisper, in: Capsule(style: .continuous))
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(selected ? WovenPalette.foreground : WovenPalette.mutedForeground)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("artifacts-filter-\(title.lowercased())")
  }

  private func mutate(_ artifact: WorkspaceNoteRecord, _ mutation: WorkspaceNoteMutation) {
    Task { try? await workspace.mutateNote(id: artifact.id, mutation: mutation) }
  }
}

/// One artifact: its kind, title, the server's one-line preview and when it last changed.
struct ArtifactRow: View {
  let artifact: WorkspaceNoteRecord
  var selected = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        ArtifactKindIcon(kind: artifact.kind, size: 20)
          .frame(width: 24, height: 24)
          .padding(.top, 2)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(artifact.title.isEmpty ? artifact.kind.untitledName : artifact.title)
              .font(.body.weight(selected ? .semibold : .medium)).lineLimit(1)
            if artifact.isPinned {
              LucideIcon(glyph: .pin, size: 12).foregroundStyle(WovenPalette.mutedForeground)
                .accessibilityLabel("Pinned")
            }
            Spacer(minLength: 4)
            if let updated = artifact.updatedAt {
              Text(updated, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption).foregroundStyle(WovenPalette.mutedForeground).lineLimit(1)
            }
          }
          Text(artifact.preview.isEmpty ? artifact.kind.displayName : artifact.preview)
            .font(.subheadline).foregroundStyle(WovenPalette.mutedForeground).lineLimit(1)
        }
      }
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(WovenPalette.foreground)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("artifact-\(artifact.id)")
  }
}
