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

    private var filteredSources: [DashboardDatabaseSource] {
        model.databasesSnapshot.sources.filter { filter.includes($0.kind) }
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
        .onChange(of: filter) { _, _ in selectDefaultSource() }
        .onChange(of: model.databasesSnapshot) { _, _ in selectDefaultSource() }
        .sheet(isPresented: $showsCreateDatabase) {
            DashboardCreateDatabaseSheet(error: model.databaseError) { name, preference in
                Task {
                    if let id = await model.createLocalDatabase(
                        name: name,
                        preference: preference
                    ) {
                        selectedSourceID = "local"
                        selectedDatabaseID = id
                        showsCreateDatabase = false
                    }
                }
            } onCancel: {
                model.clearDatabaseError()
                showsCreateDatabase = false
            }
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
            Picker("Location", selection: $filter) {
                ForEach(DashboardDatabaseFilter.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                    model.clearDatabaseError()
                    showsCreateDatabase = true
                }
                Button("Link Existing Folder…") { chooseExternalDatabase() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(model.localACPWorkspaceAvailability.isReady == false)
        }
        .padding(.horizontal, 32)
        .padding(.top, 56)
        .padding(.bottom, 18)
    }

    private var sourceList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
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
                "No Database Location",
                systemImage: "externaldrive.badge.questionmark",
                description: Text("Choose an available workspace location.")
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
        .frame(minHeight: 66)
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
    }

    private func databaseDetail(_ database: DashboardAgentDatabase) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(database.name).font(.system(size: 13, weight: .semibold))
                Text(database.localURL?.path ?? "Managed by its workspace agent")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            if database.localURL != nil {
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
                Button("Show in Finder") {
                    if let url = database.localURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
                ? "Create a folder-backed database or link an existing folder on this Mac."
                : "This workspace has not created any database folders yet.")
        } actions: {
            if source.allowsCreation {
                Button("New Database") {
                    model.clearDatabaseError()
                    showsCreateDatabase = true
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
        case .buzz: .radioTower
        }
    }
}

private enum DashboardDatabaseFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case buzz

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All"
        case .local: "Local"
        case .buzz: "Buzz"
        }
    }

    func includes(_ kind: DashboardDatabaseSourceKind) -> Bool {
        switch self {
        case .all: true
        case .local: kind == .local
        case .buzz: kind == .buzz
        }
    }
}

private struct DashboardCreateDatabaseSheet: View {
    @State private var name = ""
    @State private var preference = AgentDatabasePreference.none
    @FocusState private var nameFocused: Bool
    let error: String?
    let onCreate: (String, AgentDatabasePreference) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Database")
                .font(.system(size: 18, weight: .semibold))
            Text("Creates an ordinary folder your agents can use for durable data.")
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
                    .keyboardShortcut(.cancelAction)
                Button("Create") { onCreate(name, preference) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }
}
