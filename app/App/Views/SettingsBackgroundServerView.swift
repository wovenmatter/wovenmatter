import SwiftUI
import WovenMatterCore

struct SettingsBackgroundServerView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    @State private var workspaceID: UUID?
    @State private var confirmationAction: String?
    @State private var error: String?
    @State private var actionInProgress: String?
    @State private var availability = ServerAvailability.checking

    private enum ServerAvailability {
        case checking, running, stopped, unavailable
        var label: String {
            switch self {
            case .checking: "Checking server…"
            case .running: "Running"
            case .stopped: "Stopped"
            case .unavailable: "Server unavailable"
            }
        }
    }

    private var leaseURL: URL {
        get throws { try ApplicationModel.dashboardSupportDirectory().appending(path: LocalExecutionRole.backend.leaseFileName) }
    }

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
                    HStack(spacing: 12) {
                        if let actionInProgress {
                            ProgressView().controlSize(.small)
                            Text(actionInProgress == "start" ? "Starting server…" : actionInProgress == "restart" ? "Restarting server…" : "Stopping server…")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(availability.label).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if availability == .stopped {
                                Button("Start") { perform("start") }
                            } else if availability == .running {
                                Button("Stop", role: .destructive) { perform("stop") }
                                Button("Restart") { perform("restart") }
                            }
                        }
                    }
                    .frame(minHeight: 32)
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(!model.isBackendFrontend)
                    if DevelopmentLaunch.mode != nil {
                        Text("This development profile uses its own server and data.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            RuntimeInspectionView(model: model, workspaceID: workspaceID, onConnectionChange: observeConnection)
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

    private func observeConnection(_ connected: Bool) {
        guard workspaceID == nil, actionInProgress == nil else { return }
        if connected { availability = .running; return }
        // A failed RPC alone cannot prove that an execution owner stopped.
        do { availability = try WovenMatterBackendProcess.executionOwnerIsPresent(leaseURL: leaseURL) ? .unavailable : .stopped }
        catch { availability = .unavailable }
    }

    private func perform(_ action: String, confirmed: Bool = false) {
        guard actionInProgress == nil else { return }
        actionInProgress = action; error = nil
        Task {
            defer { actionInProgress = nil }
            do {
                if action == "start" {
                    try await model.startBackgroundServer()
                    availability = .running
                    return
                }
                let result = try await model.stopBackgroundServer(confirmed: confirmed)
                if result.confirmationRequired { confirmationAction = action; return }
                try await WovenMatterBackendProcess.waitForExecutionOwnerToExit(leaseURL: leaseURL)
                availability = .stopped
                if action == "restart" {
                    try await model.startBackgroundServer()
                    availability = .running
                }
            } catch {
                self.error = error.localizedDescription
                availability = .unavailable
            }
        }
    }
}

struct RuntimeInspectionView: View {
    @Bindable var model: ApplicationModel
    var workspaceID: UUID?
    var conversationID: String?
    var onConnectionChange: ((Bool) -> Void)?
    @State private var snapshot: RuntimeInspection?
    @State private var connected = false
    @State private var error: String?

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
                RuntimeInspectionInventoryView(items: snapshot.items, connected: connected)
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
                    onConnectionChange?(true)
                } catch {
                    guard !Task.isCancelled else { return }
                    connected = false; self.error = error.localizedDescription
                    onConnectionChange?(false)
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
}
