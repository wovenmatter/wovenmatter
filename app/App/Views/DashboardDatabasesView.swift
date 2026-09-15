import AppKit
import SwiftUI
import WovenMatterCore

struct DashboardDatabasesView: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    @State private var filter = DashboardDatabaseFilter.all
    @State private var selectedSourceID: String?
    @State private var selectedDatabaseID: String?
    @State private var showsCreateDatabase = false
    @State private var remoteWorkspaceFilterID: String?
    @State private var creationSourceID: String?
    @State private var isCreatingDatabase = false

    private var selectedSource: DashboardDatabaseSource? {
        filteredSources.first { $0.id == selectedSourceID }
    }

    private var filteredSources: [DashboardDatabaseSource] {
        model.databasesSnapshot.sources.filter {
            filter.includes($0.kind) && ($0.kind != .remote || remoteWorkspaceFilterID == nil || $0.id == remoteWorkspaceFilterID)
        }
    }

    private var selectedDatabase: DashboardAgentDatabase? {
        guard let selectedDatabaseID else { return nil }
        return model.databasesSnapshot.databases.first { $0.id == selectedDatabaseID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.palette.border)
            HStack(spacing: 0) {
                sourceList
                    .frame(width: 220)
                Divider().overlay(theme.palette.border)
                databaseList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.palette.workspace)
        .task {
            await model.refreshDatabases()
            selectDefaultSource()
        }
        .onChange(of: remoteWorkspaceFilterID) { _, _ in selectDefaultSource() }
        .onChange(of: model.remoteWorkspaces.workspaces) { _, configurations in
            if let id = remoteWorkspaceFilterID,
               !configurations.contains(where: { ApplicationModel.remoteDatabaseSourceID($0.id) == id }) {
                remoteWorkspaceFilterID = nil
            }
            Task { await model.refreshDatabases() }
        }
        .onChange(of: model.remoteWorkspaces.isCredentialAccessEnabled) { _, _ in
            Task { await model.refreshDatabases() }
        }
        .onChange(of: filter) { _, _ in selectDefaultSource() }
        .onChange(of: model.databasesSnapshot) { _, _ in selectDefaultSource() }
        .sheet(isPresented: $showsCreateDatabase) {
            DashboardCreateDatabaseSheet(
                workspaceName: model.databasesSnapshot.sources.first { $0.id == creationSourceID }?.name ?? "Workspace",
                isCreating: isCreatingDatabase, error: model.databaseError
            ) { name, preference in
                guard let sourceID = creationSourceID, !isCreatingDatabase else { return }
                isCreatingDatabase = true
                Task {
                    defer { isCreatingDatabase = false }
                    if let id = await model.createDatabase(
                        sourceID: sourceID,
                        name: name,
                        preference: preference
                    ) {
                        selectedSourceID = sourceID
                        selectedDatabaseID = id
                        showsCreateDatabase = false
                    }
                }
            } onCancel: {
                model.clearDatabaseError()
                showsCreateDatabase = false
            }
            .interactiveDismissDisabled(isCreatingDatabase)
        }
        .alert(
            "Database Error",
            isPresented: Binding(
                get: { !showsCreateDatabase && model.databaseError != nil },
                set: { if !$0 { model.clearDatabaseError() } }
            )
        ) {
            Button("OK") { model.clearDatabaseError() }
        } message: {
            Text(model.databaseError ?? "The database operation failed.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            DashboardLucideIcon(glyph: .database, size: 18)
                .foregroundStyle(DashboardPalette.primary)
                .frame(width: 36, height: 36)
                .background(DashboardPalette.muted)
                .clipShape(RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                ))
            VStack(alignment: .leading, spacing: 3) {
                Text("Databases")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
                Text("Agent-accessible data folders across your workspaces.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            Spacer(minLength: 16)
            DashboardSegmentedSelector(
                options: DashboardDatabaseFilter.allCases, selection: $filter,
                label: { $0.displayName }
            )
            .frame(maxWidth: 360)
            Button {
                Task { await model.refreshDatabases() }
            } label: {
                if model.isRefreshingDatabases {
                    ProgressView().controlSize(.small).frame(width: 32, height: 32)
                } else {
                    DashboardLucideIcon(glyph: .rotate, size: 15)
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isRefreshingDatabases)
            .help("Refresh databases")
            Menu {
                Button("New Database") {
                    beginCreatingDatabase()
                }
                .disabled(selectedSource?.allowsCreation != true)
                if selectedSource?.allowsExternalLinks == true {
                    Button("Link Existing Folder…") { chooseExternalDatabase() }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(selectedSource?.allowsCreation != true)
        }
        .padding(.horizontal, 32)
        .padding(.top, 56)
        .padding(.bottom, 18)
    }

    private var sourceList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if filter == .remote || filter == .all {
                    remoteWorkspaceMenu
                }
                ForEach(filteredSources) { source in
                    Button {
                        selectedSourceID = source.id
                        selectedDatabaseID = nil
                    } label: {
                        HStack(spacing: 10) {
                            DashboardLucideIcon(glyph: sourceGlyph(source.kind), size: 15)
                                .foregroundStyle(DashboardPalette.mutedForeground)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                    .foregroundStyle(DashboardPalette.foreground)
                                    .lineLimit(1)
                                Text(source.error == nil
                                    ? "\(source.databases.count) \(source.databases.count == 1 ? "database" : "databases")"
                                    : "Unavailable")
                                    .font(.caption)
                                    .foregroundStyle(source.error == nil
                                        ? DashboardPalette.mutedForeground
                                        : DashboardPalette.warning)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 48)
                        .background(
                            selectedSourceID == source.id
                                ? theme.palette.themeStrong
                                : .clear,
                            in: RoundedRectangle(
                                cornerRadius: DashboardMetrics.controlRadius,
                                style: .continuous
                            )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedSourceID == source.id ? .isSelected : [])
                }
            }
            .padding(12)
        }
        .background(theme.palette.workspace)
    }

    @ViewBuilder
    private var databaseList: some View {
        if let source = filteredSources.first(where: { $0.id == selectedSourceID }) {
            VStack(spacing: 0) {
                sourceHeader(source)
                if let error = source.error {
                    unavailableSource(source, error: error)
                } else if source.databases.isEmpty {
                    emptySource(source)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(source.databases) { database in
                                databaseRow(database)
                            }
                        }
                        .padding(20)
                    }
                }
                if let selectedDatabase,
                   selectedDatabase.sourceID == source.id {
                    databaseDetail(selectedDatabase)
                }
            }
        } else {
            ContentUnavailableView(
                filter == .remote ? "No Remote Workspaces" : "No Database Location",
                systemImage: "externaldrive.badge.questionmark",
                description: Text(filter == .remote
                    ? "Add a remote workspace in Settings."
                    : "Choose an available workspace location.")
            )
        }
    }

    private func sourceHeader(_ source: DashboardDatabaseSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.system(size: 16, weight: .semibold))
                Text(source.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(1)
                    .textSelection(.enabled)
                if source.kind == .remote {
                    Text("Linked data: JSON or read-only SQLite")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .help("Only folders inside this workspace’s Databases folder are available. Linked folders are not supported.")
                }
            }
            Spacer()
            Text(source.kind.displayName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(DashboardPalette.muted, in: Capsule())
        }
        .padding(.horizontal, 24)
        .frame(minHeight: source.kind == .remote ? 82 : 66)
        .background(theme.palette.workspace)
        .overlay(alignment: .bottom) { Divider().overlay(theme.palette.border) }
    }

    private func databaseRow(
        _ database: DashboardAgentDatabase
    ) -> some View {
        Button {
            selectedDatabaseID = database.id
        } label: {
            HStack(spacing: 12) {
                DashboardLucideIcon(glyph: .database, size: 17)
                    .foregroundStyle(DashboardPalette.primary)
                    .frame(width: 34, height: 34)
                    .background(theme.palette.themeWhisper)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(database.name)
                        .font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(database.preference.displayName)
                        if database.isExternal { Text("External folder") }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer()
                if database.id == selectedDatabaseID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DashboardPalette.primary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .background(
                database.id == selectedDatabaseID
                    ? theme.palette.themeStrong
                    : theme.palette.input,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.palette.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(database.id == selectedDatabaseID ? .isSelected : [])
    }

    private func databaseDetail(_ database: DashboardAgentDatabase) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(database.name).font(.system(size: 13, weight: .semibold))
                Text(database.localURL?.path ?? "Databases/\(database.name) · Remote workspace")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            if database.localURL != nil || selectedSource?.kind == .remote {
                Picker("Data preference", selection: Binding(
                    get: { database.preference },
                    set: { preference in
                        Task {
                            await model.updateDatabasePreference(
                                preference,
                                database: database
                            )
                        }
                    }
                )) {
                    ForEach(AgentDatabasePreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .frame(width: 160)
                if let url = database.localURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 72)
        .background(theme.palette.themeWhisper)
        .overlay(alignment: .top) { Divider().overlay(theme.palette.border) }
    }

    private func emptySource(_ source: DashboardDatabaseSource) -> some View {
        ContentUnavailableView {
            Label("No databases yet", systemImage: "cylinder")
        } description: {
            Text(source.allowsCreation
                ? (source.kind == .remote ? "Create a database folder for this workspace’s agents." : "Create a database or link a folder on this Mac.")
                : "This workspace has not created any database folders yet.")
        } actions: {
            if source.allowsCreation {
                Button("New Database") {
                    beginCreatingDatabase()
                }
                    .buttonStyle(DashboardPrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableSource(
        _ source: DashboardDatabaseSource,
        error: String
    ) -> some View {
        ContentUnavailableView {
            Label("Databases unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error)
        } actions: {
            Button("Refresh") { Task { await model.refreshDatabases() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var remoteWorkspaceMenu: some View {
        Menu {
            Picker("Remote workspace", selection: $remoteWorkspaceFilterID) {
                Text("All remote workspaces").tag(String?.none)
                ForEach(model.remoteWorkspaces.workspaces) { workspace in
                    Text(workspace.name).tag(Optional(ApplicationModel.remoteDatabaseSourceID(workspace.id)))
                }
            }
        } label: {
            Text(model.remoteWorkspaces.workspaces.first {
                ApplicationModel.remoteDatabaseSourceID($0.id) == remoteWorkspaceFilterID
            }?.name ?? "All remote workspaces")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Filter remote workspaces")
        .accessibilityValue(model.remoteWorkspaces.workspaces.first {
            ApplicationModel.remoteDatabaseSourceID($0.id) == remoteWorkspaceFilterID
        }?.name ?? "All remote workspaces")
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func beginCreatingDatabase() {
        guard let source = selectedSource, source.allowsCreation else { return }
        creationSourceID = source.id
        model.clearDatabaseError()
        showsCreateDatabase = true
    }

    private func selectDefaultSource() {
        guard filteredSources.contains(where: { $0.id == selectedSourceID }) else {
            selectedSourceID = filteredSources.first?.id
            selectedDatabaseID = nil
            return
        }
        if let selectedDatabaseID,
           !model.databasesSnapshot.databases.contains(where: { $0.id == selectedDatabaseID }) {
            self.selectedDatabaseID = nil
        }
    }

    private func chooseExternalDatabase() {
        let panel = NSOpenPanel()
        panel.title = "Link an Existing Database Folder"
        panel.message = "The folder stays in place. Woven Matter adds an alias in the local Databases folder."
        panel.prompt = "Link Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            if let id = await model.registerExternalDatabase(url) {
                selectedSourceID = "local"
                selectedDatabaseID = id
            }
        }
    }

    private func sourceGlyph(_ kind: DashboardDatabaseSourceKind) -> DashboardLucideGlyph {
        switch kind {
        case .local: .monitor
        case .remote: .container
        case .buzz: .radioTower
        }
    }
}

private enum DashboardDatabaseFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case remote
    case buzz

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All"
        case .local: "Local"
        case .remote: "Remote"
        case .buzz: "Buzz"
        }
    }

    func includes(_ kind: DashboardDatabaseSourceKind) -> Bool {
        switch self {
        case .all: true
        case .local: kind == .local
        case .remote: kind == .remote
        case .buzz: kind == .buzz
        }
    }
}

private struct DashboardCreateDatabaseSheet: View {
    @State private var name = ""
    @State private var preference = AgentDatabasePreference.none
    @FocusState private var nameFocused: Bool
    let workspaceName: String
    let isCreating: Bool
    let error: String?
    let onCreate: (String, AgentDatabasePreference) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Database")
                .font(.system(size: 18, weight: .semibold))
            Text("Create in \(workspaceName).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Database name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            Picker("Data preference", selection: $preference) {
                ForEach(AgentDatabasePreference.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            Text("No preference lets the agent choose. JSON and SQLite are guidance, not enforced schemas.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .disabled(isCreating)
                    .keyboardShortcut(.cancelAction)
                Button(isCreating ? "Creating…" : "Create") { onCreate(name, preference) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }
}
