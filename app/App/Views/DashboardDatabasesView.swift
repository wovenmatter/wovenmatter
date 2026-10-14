import SwiftUI
import WovenMatterCore

private struct DashboardDatabaseSourceButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @State private var isHovering = false
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? theme.palette.themeStrong
                    : isSelected
                        ? (isHovering ? theme.palette.themeStrong : theme.palette.themeSoft)
                        : isHovering ? theme.palette.themeWhisper : .clear,
                in: RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
            )
            .onHover { isHovering = $0 }
    }
}

private struct DashboardDatabaseRowButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @State private var isHovering = false
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? theme.palette.themeStrong
                    : isSelected
                        ? (isHovering ? theme.palette.themeStrong : theme.palette.themeSoft)
                        : isHovering ? theme.palette.themeWhisper : theme.palette.input,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.palette.border, lineWidth: 1)
            }
            .onHover { isHovering = $0 }
    }
}

struct DashboardDatabasesView: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    @State private var filter = DashboardDatabaseFilter.all
    @State private var selectedSourceID: String?
    @State private var selectedDatabaseID: String?
    @State private var showsCreateDatabase = false
    @State private var creationSourceID: String?
    @State private var isCreatingDatabase = false
    @State private var databaseToCopy: DashboardAgentDatabase?
    @State private var isCopyingDatabase = false

    private var writableSources: [DashboardDatabaseSource] {
        model.databasesSnapshot.sources.filter(\.allowsCreation)
    }

    private var selectedSource: DashboardDatabaseSource? {
        filteredSources.first { $0.id == selectedSourceID }
    }

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
        .onChange(of: model.remoteWorkspaces.workspaces) { _, _ in
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
            ) { name in
                guard let sourceID = creationSourceID, !isCreatingDatabase else { return }
                isCreatingDatabase = true
                Task {
                    defer { isCreatingDatabase = false }
                    if let id = await model.createDatabase(
                        sourceID: sourceID,
                        name: name,
                        preference: .sqlite
                    ) {
                        await model.analytics.record(.contentChanged, properties: ["action": "create", "item_category": "database"])
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
        .sheet(item: $databaseToCopy) { database in
            DashboardCopyDatabaseSheet(
                database: database,
                destinations: writableSources,
                isCopying: isCopyingDatabase,
                error: model.databaseError
            ) { destinationSourceID, name in
                guard !isCopyingDatabase else { return }
                isCopyingDatabase = true
                Task {
                    defer { isCopyingDatabase = false }
                    if let id = await model.copyDatabase(
                        database: database,
                        destinationSourceID: destinationSourceID,
                        name: name
                    ) {
                        selectedSourceID = destinationSourceID
                        selectedDatabaseID = id
                        databaseToCopy = nil
                    }
                }
            } onCancel: {
                model.clearDatabaseError()
                databaseToCopy = nil
            }
            .interactiveDismissDisabled(isCopyingDatabase)
        }
        .alert(
            "Database Error",
            isPresented: Binding(
                get: { !showsCreateDatabase && databaseToCopy == nil && model.databaseError != nil },
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
            Text("Databases")
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)
            Spacer(minLength: 16)
            DashboardSegmentedSelector(
                options: DashboardDatabaseFilter.allCases,
                selection: $filter
            ) { value in
                value.displayName
            }
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
            .buttonStyle(DashboardIconButtonStyle())
            .disabled(model.isRefreshingDatabases)
            .help("Refresh databases")
            Button(action: beginCreatingDatabase) {
                Label("New database", systemImage: "plus")
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(selectedSource?.allowsCreation != true)
            .help(selectedSource?.allowsCreation == true
                ? "Create a database owned by this workspace."
                : "Connect the owning workspace to create a database.")
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
                                    : source.databases.isEmpty ? "Unavailable"
                                        : "Offline · \(source.databases.count) \(source.databases.count == 1 ? "database" : "databases")")
                                    .font(.caption)
                                    .foregroundStyle(source.error == nil
                                        ? DashboardPalette.mutedForeground
                                        : DashboardPalette.warning)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DashboardDatabaseSourceButtonStyle(
                        isSelected: selectedSourceID == source.id
                    ))
                    .accessibilityAddTraits(
                        selectedSourceID == source.id ? .isSelected : []
                    )
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .background(theme.palette.workspace)
    }

    @ViewBuilder
    private var databaseList: some View {
        if let source = filteredSources.first(where: { $0.id == selectedSourceID }) {
            VStack(spacing: 0) {
                sourceHeader(source)
                if let error = source.error, source.databases.isEmpty {
                    unavailableSource(source, error: error)
                } else if source.databases.isEmpty {
                    emptySource(source)
                } else {
                    if let error = source.error {
                        HStack(spacing: 8) {
                            DashboardLucideIcon(glyph: .alertTriangle, size: 13)
                            Text("Owner offline. Showing the last complete synced data.")
                                .font(.system(size: 11))
                            Spacer()
                        }
                        .foregroundStyle(DashboardPalette.warning)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .help(error)
                    }
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(source.databases) { database in
                                databaseRow(database)
                            }
                        }
                        .padding(20)
                    }
                    .scrollIndicators(.never)
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
                    Text(DashboardDatabaseFreshness.description(database))
                        .font(.system(size: 11))
                        .foregroundStyle(database.offline
                            ? DashboardPalette.warning : DashboardPalette.mutedForeground)
                }
                Spacer()
                if database.id == selectedDatabaseID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DashboardPalette.primary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(DashboardDatabaseRowButtonStyle(
            isSelected: database.id == selectedDatabaseID
        ))
        .accessibilityAddTraits(
            database.id == selectedDatabaseID ? .isSelected : []
        )
    }

    private func databaseDetail(_ database: DashboardAgentDatabase) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(database.name).font(.system(size: 13, weight: .semibold))
                Text(DashboardDatabaseFreshness.description(database))
                    .font(.system(size: 10.5))
                    .foregroundStyle(database.offline
                        ? DashboardPalette.warning : DashboardPalette.mutedForeground)
                    .lineLimit(1)
            }
            Spacer()
            Button("Copy to workspace…") {
                model.clearDatabaseError()
                databaseToCopy = database
            }
            .disabled(writableSources.isEmpty || (database.offline && database.localURL == nil))
            .help(writableSources.isEmpty
                ? "Connect a destination workspace to create a copy."
                : "Create an independent database. Existing artifact links keep using the original.")
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
                ? "Create a managed database owned by this workspace."
                : "Connect the workspace to create a database.")
        } actions: {
            if source.allowsCreation {
                Button("New database") {
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

    private func sourceGlyph(_ kind: DashboardDatabaseSourceKind) -> DashboardLucideGlyph {
        switch kind {
        case .local: .monitor
        case .remote: .container
        }
    }
}

private enum DashboardDatabaseFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case remote

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All"
        case .local: "Local"
        case .remote: "Remote"
        }
    }

    func includes(_ kind: DashboardDatabaseSourceKind) -> Bool {
        switch self {
        case .all: true
        case .local: kind == .local
        case .remote: kind == .remote
        }
    }
}

private struct DashboardCreateDatabaseSheet: View {
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    let workspaceName: String
    let isCreating: Bool
    let error: String?
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New database")
                .font(.system(size: 18, weight: .semibold))
            Text("Create in \(workspaceName).")
                .font(.system(size: 12))
                .foregroundStyle(DashboardPalette.mutedForeground)
            TextField("Database name", text: $name)
                .focused($nameFocused)
                .dashboardQuietTextInput()
            Text("Agents create and update tables through Woven Matter’s database tools.")
                .font(.system(size: 11))
                .foregroundStyle(DashboardPalette.mutedForeground)
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
                Button(isCreating ? "Creating…" : "Create") { onCreate(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(DashboardPalette.foreground)
        .padding(22)
        .frame(width: 420)
        .dashboardFormFocusDismissal { nameFocused = false }
        .onAppear { nameFocused = true }
    }
}

private struct DashboardCopyDatabaseSheet: View {
    let database: DashboardAgentDatabase
    let destinations: [DashboardDatabaseSource]
    let isCopying: Bool
    let error: String?
    let onCopy: (String, String) -> Void
    let onCancel: () -> Void
    @State private var destinationSourceID = ""
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var canCopy: Bool {
        destinations.contains { $0.id == destinationSourceID && $0.allowsCreation }
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Copy to Workspace")
                .font(.system(size: 18, weight: .semibold))
            Text("Create an independent copy of \(database.name). Existing artifact links keep using the original database.")
                .font(.system(size: 12))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            if database.offline {
                Text("The owner is offline. This copy uses the last complete synced snapshot.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.warning)
            }
            Text(DashboardDatabaseFreshness.description(database))
                .font(.system(size: 11))
                .foregroundStyle(DashboardPalette.mutedForeground)
            Picker("Destination workspace", selection: $destinationSourceID) {
                ForEach(destinations) { Text($0.name).tag($0.id) }
            }
            TextField("Database name", text: $name)
                .focused($nameFocused)
                .dashboardQuietTextInput()
            if let error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .disabled(isCopying)
                    .keyboardShortcut(.cancelAction)
                Button(isCopying ? "Copying…" : "Copy") {
                    onCopy(destinationSourceID, name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCopying || !canCopy)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(DashboardPalette.foreground)
        .padding(22)
        .frame(width: 440)
        .dashboardFormFocusDismissal { nameFocused = false }
        .onAppear {
            name = "\(database.name) copy"
            destinationSourceID = destinations.first { $0.id != database.sourceID }?.id
                ?? destinations.first?.id ?? ""
            nameFocused = true
        }
        .onChange(of: destinations) { _, sources in
            if !sources.contains(where: { $0.id == destinationSourceID }) {
                destinationSourceID = sources.first?.id ?? ""
            }
        }
    }
}

/// Dataset timestamps describe the committed source data, including offline replicas.
enum DashboardDatabaseFreshness {
    static func description(_ database: DashboardAgentDatabase) -> String {
        let prefix = database.offline ? "Offline · " : ""
        guard let updatedAt = database.updatedAt else {
            return database.offline ? "Offline · Last synced snapshot" : "Managed SQLite database"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: updatedAt)
            ?? ISO8601DateFormatter().date(from: updatedAt)
        let label = date?.formatted(date: .abbreviated, time: .shortened) ?? updatedAt
        return "\(prefix)Data updated \(label)"
    }
}
