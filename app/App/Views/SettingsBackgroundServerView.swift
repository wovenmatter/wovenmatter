import SwiftUI
import WovenMatterCore

struct SettingsBackgroundServerView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    @State private var workspaceID: UUID?
    @State private var confirmationAction: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        SettingsPage(title: "Background Server", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            SettingsCard(title: "Execution owner", detail: "The server keeps agents and scheduled work running when the app window closes.") {
                Picker("Server", selection: $workspaceID) {
                    Text("This Mac").tag(UUID?.none)
                    ForEach(model.remoteWorkspaces.workspaces) { workspace in
                        Text(workspace.name).tag(Optional(workspace.id))
                    }
                }
                if workspaceID == nil {
                    HStack {
                        Button("Start") { perform("start") }
                        Button("Stop", role: .destructive) { perform("stop") }
                        Button("Restart") { perform("restart") }
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(busy || !model.isBackendFrontend)
                    if DevelopmentLaunch.mode != nil {
                        Text("This development profile uses its own server and data.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            RuntimeInspectionView(model: model, workspaceID: workspaceID)
                .id(workspaceID)
        }
        .alert("Stop current work?", isPresented: Binding(get: { confirmationAction != nil }, set: { if !$0 { confirmationAction = nil } })) {
            Button("Cancel", role: .cancel) { confirmationAction = nil }
            Button(confirmationAction == "restart" ? "Stop work and restart" : "Stop work and server", role: .destructive) {
                let action = confirmationAction ?? "stop"
                confirmationAction = nil
                perform(action, confirmed: true)
            }
        } message: {
            Text("This server has active work. Continuing will cancel its current work before stopping the server.")
        }
    }

    private func perform(_ action: String, confirmed: Bool = false) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                if action == "start" { try await model.startBackgroundServer(); return }
                let result = try await model.stopBackgroundServer(confirmed: confirmed)
                if result.confirmationRequired { confirmationAction = action; return }
                if action == "restart" {
                    try await WovenMatterBackendProcess.waitForExecutionOwnerToExit(
                        leaseURL: ApplicationModel.dashboardSupportDirectory().appending(path: LocalExecutionRole.backend.leaseFileName))
                    try await model.startBackgroundServer()
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct RuntimeInspectionView: View {
    @Bindable var model: ApplicationModel
    var workspaceID: UUID?
    var conversationID: String?
    @State private var snapshot: RuntimeInspection?
    @State private var connected = false
    @State private var error: String?

    private func depth(_ item: RuntimeInspection.Item, in items: [RuntimeInspection.Item]) -> Int {
        var parent = item.parentID, visited: Set<String> = [item.id], depth = 0
        while let id = parent, let next = items.first(where: { $0.id == id }), visited.insert(id).inserted, depth < 6 {
            depth += 1; parent = next.parentID
        }
        return depth
    }
    private func ordered(_ items: [RuntimeInspection.Item]) -> [RuntimeInspection.Item] {
        var result: [RuntimeInspection.Item] = [], seen: Set<String> = []
        func append(_ item: RuntimeInspection.Item) {
            guard seen.insert(item.id).inserted else { return }
            result.append(item)
            for child in items.filter({ $0.parentID == item.id }).sorted(by: { $0.title < $1.title }) { append(child) }
        }
        for item in items where item.parentID == nil || !items.contains(where: { $0.id == item.parentID }) { append(item) }
        for item in items { append(item) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(conversationID == nil ? "Managed activity" : "Chat activity").font(.headline)
                Spacer()
                Text(connected ? "Connected" : "Disconnected").font(.caption).foregroundStyle(.secondary)
            }
            if let snapshot {
                Text("\(connected ? "Observed" : "Last observed") \(snapshot.observedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(ordered(snapshot.items)) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Spacer()
                            Text(connected ? item.state.capitalized : "Last: \(item.state)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Text(item.kind.capitalized)
                            if let pid = item.processID { Text("PID \(pid)").monospacedDigit() }
                            if let memory = item.residentBytes { Text(ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory)) }
                            if let cpu = item.cpuPercent { Text(String(format: "%.1f%% CPU", cpu)).monospacedDigit() }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        }
                    }
                    .padding(.leading, CGFloat(depth(item, in: snapshot.items)) * 12)
                    .padding(.vertical, 6)
                    Divider()
                }
                if snapshot.items.isEmpty { Text("No managed activity in this scope.").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(error ?? "Waiting for the execution owner…").font(.caption).foregroundStyle(.secondary)
            }
            if snapshot != nil, let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: "\(workspaceID?.uuidString ?? "local"):\(conversationID ?? "all")") {
            while !Task.isCancelled {
                do {
                    let value = try await model.runtimeInspection(.init(workspaceID: workspaceID, conversationID: conversationID))
                    guard !Task.isCancelled else { return }
                    snapshot = value; connected = true; error = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    connected = false; self.error = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}
