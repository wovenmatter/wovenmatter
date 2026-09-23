import SwiftUI
import WovenMatterCore

struct DashboardLibrarySurface: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var library: LibraryModel
    let configuredWorkspaces: [(id: String, name: String)]
    let onOpenMessage: (WorkspaceLibraryItem) -> Void
    @State private var selection = LibraryQuery()
    @State private var dateRange: LibraryDateRange = .all
    private var query: LibraryQuery {
        var value = selection
        value.since = dateRange.start(now: library.today)
        return value
    }
    private var workspaces: [(String, String)] {
        var values = ["local": "Local workspace"]
        for workspace in configuredWorkspaces { values[workspace.id] = workspace.name }
        for facet in library.facets where values[facet.workspaceID] == nil {
            values[facet.workspaceID] = facet.workspaceName
        }
        return values.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }
    private var harnesses: [(String, String)] {
        let names = Set(library.facets.map(\.harness)).filter { !$0.isEmpty }
        return names.sorted().map { ($0, AgentRuntimeKind(rawValue: $0)?.displayName ?? $0) }
    }
    private var agents: [(String, String)] {
        let available = library.facets.filter { selection.workspaces?.contains($0.workspaceID) ?? true }
        return Dictionary(
            available.map { ($0.agentID, "\($0.agentName) · \($0.workspaceName)") },
            uniquingKeysWith: { first, _ in first }
        )
        .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = library.error ?? library.loadError {
                HStack {
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { library.dismissError() }.buttonStyle(DashboardQuietButtonStyle())
                }.padding(.horizontal, 32).padding(.vertical, 8)
            }
            if library.loading && library.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.items.isEmpty {
                DashboardConversationEmptyState(
                    icon: .libraryBigControl,
                    title: library.facets.isEmpty ? "No Library items yet" : "No matching items",
                    detail: library.facets.isEmpty
                        ? "Files, links, and photos you exchange in new messages will appear here."
                        : "Adjust your filters or search to find an item."
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(library.items) { item in
                            DashboardLibraryRow(
                                item: item, onOpen: { library.open(item) },
                                onSource: { onOpenMessage(item) }, onRetry: { library.retry(item) })
                        }
                        if library.hasMore {
                            Button("Load more") { Task { await library.load(query: query, more: true) } }
                                .buttonStyle(DashboardQuietButtonStyle()).disabled(library.loading).padding(
                                    .vertical, 12)
                        }
                    }
                    .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 32)
                }.scrollIndicators(.never)
            }
        }
        .background(theme.palette.workspace)
        .task(id: LoadRequest(query: query, revision: library.revision)) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await library.load(query: query, preserveCount: true)
        }
    }
    private struct LoadRequest: Equatable {
        let query: LibraryQuery
        let revision: Int64
    }

    private var itemCount: String {
        let noun = library.items.count == 1 && !library.hasMore ? "item" : "items"
        return "\(library.items.count)\(library.hasMore ? "+" : "") \(noun)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                DashboardLucideIcon(glyph: .libraryBigControl, size: 18)
                    .foregroundStyle(DashboardPalette.primary).frame(width: 36, height: 36)
                    .background(DashboardPalette.muted).clipShape(DashboardShapes.card)
                Text("Library").font(.system(size: 22, weight: .semibold)).tracking(-0.3)
                Spacer()
                Menu {
                    Button("Newest first") { selection.oldestFirst = false }
                    Button("Oldest first") { selection.oldestFirst = true }
                } label: {
                    Label(selection.oldestFirst ? "Oldest first" : "Newest first", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            DashboardSearchField(text: $selection.search, prompt: "Search Library")
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    multipleFilter("Workspaces", options: workspaces, selected: $selection.workspaces)
                    multipleFilter("Agent types", options: harnesses, selected: $selection.harnesses)
                    multipleFilter("Agents", options: agents, selected: $selection.agents)
                    Menu {
                        Button("All senders") { selection.sender = nil }
                        ForEach(LibrarySender.allCases, id: \.self) { value in
                            Button(value.title) { selection.sender = value }
                        }
                    } label: {
                        filterLabel(selection.sender?.title ?? "All senders")
                    }
                    Menu {
                        Button("All types") { selection.kind = nil }
                        ForEach(LibraryItemKind.allCases, id: \.self) { value in
                            Button(value.title) { selection.kind = value }
                        }
                    } label: {
                        filterLabel(selection.kind?.title ?? "All types")
                    }
                    Menu {
                        ForEach(LibraryDateRange.allCases) { value in Button(value.title) { dateRange = value } }
                    } label: {
                        filterLabel(dateRange.title)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .menuStyle(.borderlessButton)
            }
            .scrollIndicators(.never)
            HStack {
                Text(itemCount).font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                Spacer()
                if selection != LibraryQuery() || dateRange != .all {
                    Button("Clear filters") {
                        selection = .init()
                        dateRange = .all
                    }.buttonStyle(DashboardQuietButtonStyle())
                }
            }
        }
        .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 12)
    }
    private func multipleFilter(_ title: String, options: [(String, String)], selected: Binding<Set<String>?>)
        -> some View
    {
        Menu {
            Button("All") { selected.wrappedValue = nil }
            Button("None") { selected.wrappedValue = [] }
            Divider()
            ForEach(options, id: \.0) { option in
                Toggle(
                    option.1,
                    isOn: Binding(
                        get: { selected.wrappedValue?.contains(option.0) ?? true },
                        set: { enabled in
                            var current = selected.wrappedValue ?? Set(options.map(\.0))
                            if enabled { current.insert(option.0) } else { current.remove(option.0) }
                            selected.wrappedValue = current
                        }))
            }
        } label: {
            filterLabel(
                selected.wrappedValue.map { "\(title): \($0.isEmpty ? "None" : String($0.count))" }
                    ?? "All \(title.lowercased())")
        }
        .accessibilityLabel(title)
    }
    private func filterLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            .fixedSize()
    }
}

private struct DashboardLibraryRow: View {
    @Environment(\.dashboardTheme) private var theme
    let item: WorkspaceLibraryItem
    let onOpen: () -> Void
    let onSource: () -> Void
    let onRetry: () -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                details
                Spacer(minLength: 10)
                actions
            }
            VStack(alignment: .leading, spacing: 12) {
                details
                actions
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.themeWhisper).clipShape(DashboardShapes.card)
        .contextMenu {
            Button("Open", action: onOpen).disabled(!item.canOpen)
            Button("Show in conversation", action: onSource)
        }
    }
    private var details: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .photo ? "photo" : item.kind == .file ? "doc" : "link")
                .font(.system(size: 20)).foregroundStyle(DashboardPalette.primary).frame(width: 36, height: 40)
            VStack(alignment: .leading, spacing: 5) {
                Button(action: onOpen) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(
                        .leading)
                }
                .buttonStyle(.plain).disabled(!item.canOpen).help(item.source)
                Text("\(item.sender.title) · \(item.agentName) · \(item.workspaceName)")
                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground).lineLimit(2)
                if let date = item.sentDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(
                        DashboardPalette.mutedForeground)
                }
                if let error = item.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground).lineLimit(2)
                        .help(error)
                } else if item.storage == .pending {
                    Text("Saving file…").font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
        }
    }
    private var actions: some View {
        HStack(spacing: 8) {
            if item.storage == .unavailable {
                Button("Retry", action: onRetry).buttonStyle(DashboardQuietButtonStyle())
            }
            Button("Open", action: onOpen).buttonStyle(DashboardQuietButtonStyle()).disabled(!item.canOpen)
            Button("Show in conversation", action: onSource).buttonStyle(DashboardQuietButtonStyle())
        }.fixedSize()
    }
}

struct DashboardLibrarySourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: WorkspaceLibraryItem
    let model: ApplicationModel
    @State private var content = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(item.conversationTitle).font(.title2)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(item.sentDate?.formatted(date: .abbreviated, time: .shortened) ?? item.sentAt).font(.caption)
            ScrollView { Text(content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .scrollIndicators(.never)
        }.padding(24).frame(width: 640, height: 460)
            .task {
                do {
                    content =
                        try model.dashboardStore?.database.librarySourceMessage(id: item.id)
                        ?? "The workspace is unavailable."
                } catch { content = error.localizedDescription }
            }
    }
}
