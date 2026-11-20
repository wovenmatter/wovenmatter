import SwiftUI

/// OpenCode's own background server on one machine.
struct OpenCodeSettingsSection: View {
    @Environment(\.openURL) private var openURL
    @Bindable var model: MachinesStore
    let machine: Machine
    let server: OpenCodeServer
    @State private var showingModels = false
    @State private var modelSearch = ""
    @State private var loadingModels = false
    @State private var modelsError: String?
    @State private var confirmsReplacement = false
    @State private var browserError: String?

    private var isRemote: Bool { !machine.isThisMachine }
    private var canConnect: Bool { server.isInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRow(title: machine.name, detail: isRemote ? model.serverStatus(on: machine.id)?.hostName : nil) {
                SettingsStatus(server.state == .connecting ? "Connecting…" : server.isReady ? "Ready" : "Not connected", tone: server.isReady ? .good : .warning)
                Button(isRemote || server.isInstalled ? "Connect" : server.isInstalling ? "Installing…" : "Install") {
                    if isRemote || server.isInstalled { model.connectOpenCode(on: machine.id); return }
                    // OpenCode 2 replaces OpenCode 1's command, so that asks first.
                    if server.replacesVersionOne != nil { confirmsReplacement = true } else { model.installOpenCode(on: machine.id) }
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(server.state == .connecting || server.isReady || server.isInstalling || server.isControllingServer || (isRemote && !canConnect))
                .confirmationDialog("Replace OpenCode 1?", isPresented: $confirmsReplacement, titleVisibility: .visible) {
                    Button("Install OpenCode 2") { model.installOpenCode(on: machine.id) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(PendingHarnessInstall(machineID: machine.id, runtimeKind: .opencode,
                        replacingVersion: server.replacesVersionOne ?? "1").notice(on: "this Mac"))
                }
            }
            HStack(spacing: 8) {
                Button("Manage models") { showingModels.toggle() }
                    .disabled(!server.isReady)
                    .popover(isPresented: $showingModels, arrowEdge: .bottom) {
                        modelPicker
                            .task {
                                loadingModels = true
                                modelsError = nil
                                defer { loadingModels = false }
                                do { try await model.refreshOpenCodeModels(on: machine.id) }
                                catch { modelsError = error.localizedDescription }
                            }
                    }
                if server.isReady && !isRemote {
                    Button("Open in browser") {
                        Task {
                            do { openURL(try await model.openCodeBrowserURL(on: machine.id)) }
                            catch { browserError = error.localizedDescription }
                        }
                    }
                }
                Button("Restart server") { model.restartOpenCode(on: machine.id) }
                    .disabled(server.isControllingServer || server.state == .connecting || !server.isInstalled || (isRemote && !canConnect))
                Button("Stop server") { model.stopOpenCode(on: machine.id) }
                    .disabled(server.isControllingServer || server.state == .connecting || !server.hasServer)
                if server.isControllingServer { ProgressView().controlSize(.small) }
            }
            .buttonStyle(SettingsQuietButtonStyle())
            SettingsSummaryRow("Server lifecycle", value: server.startsWithApp ? "Starts with Woven Matter" : "Manual") {
                Toggle("Start when Woven Matter launches", isOn: Binding(
                    get: { server.startsWithApp },
                    set: { model.setOpenCodeStartsWithApp($0, on: machine.id) }))
                SettingsNote("This is OpenCode's own background server, shared with the opencode command and OpenCode's desktop app. It keeps running when Woven Matter quits. Stopping it disconnects all its clients.")
            }
            if !isRemote {
                SettingsSummaryRow("Shared sessions") { OpenCodeSessionLibrary(model: model, machineID: machine.id, isReady: server.isReady) }
            }
            if let error = model.openCodeErrors[machine.id] ?? browserError { SettingsError(error) }
            if !canConnect {
                SettingsNote(isRemote ? "Install OpenCode in this remote workspace to connect." : "Install OpenCode v2 to connect.")
            }
        }
    }

    private var sortedPickerModels: [OpenCodeModelOption] {
        let matching = server.models.filter {
            modelSearch.isEmpty || ($0.name + " " + $0.id).localizedCaseInsensitiveContains(modelSearch)
        }
        // Partition without disturbing the catalog order within either group.
        return matching.filter { !server.hiddenModels.contains($0.id) }
            + matching.filter { server.hiddenModels.contains($0.id) }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models shown in Woven Matter").font(.settingsSection)
            TextField("Search models", text: $modelSearch)
                .quietTextInput()
            if loadingModels { ProgressView() }
            if let modelsError { Text(modelsError).font(.settingsSecondary).foregroundStyle(WovenPalette.danger) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(sortedPickerModels) { option in
                        Toggle(isOn: Binding(
                            get: { !server.hiddenModels.contains(option.id) },
                            set: { model.setOpenCodeModelVisible(option.id, visible: $0, on: machine.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.name)
                                Text(option.providerID).font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityLabel(option.name + ", " + option.providerID)
                    }
                }
                // Native switch tracks extend slightly beyond their layout frame.
                // Keep that drawing inside the scroll viewport at every edge.
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .frame(height: 300)
            Text("Existing chats keep their selected model.")
                .font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
        }
        .padding(16)
        .frame(width: 360)
    }
}

/// Each installed OpenCode service in the selected scope, on the agent page itself.
struct SettingsOpenCodeInstances: View {
    @Bindable var model: ApplicationModel
    let scope: String

    private var machines: MachinesStore { model.machines }
    private var installed: [Machine] {
        machines.machines(inScope: scope).filter { machines.openCodeServer(on: $0.id)?.isInstalled == true }
    }

    var body: some View {
        SettingsSection(title: "OpenCode service") {
            if installed.isEmpty {
                SettingsEmpty("Install OpenCode to manage its service.")
            }
            ForEach(installed) { machine in
                SettingsSummaryRow(machine.isThisMachine ? "Local workspace" : machine.name,
                                   value: machines.openCodeServer(on: machine.id)?.isReady == true ? "Ready" : "Not connected") {
                    OpenCodeInstanceSettings(model: machines, machine: machine)
                }
            }
        }
    }
}

private struct OpenCodeInstanceSettings: View {
    @Bindable var model: MachinesStore
    let machine: Machine
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    private var server: OpenCodeServer? { model.openCodeServer(on: machine.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let server {
                SettingsRow(title: "Name in Woven Matter") {
                    TextField("Agent name", text: $name)
                        .wovenInput()
                        .frame(width: 220)
                    Button("Save") {
                        Task {
                            saving = true; error = nil
                            defer { saving = false }
                            do { try await model.renameOpenCode(on: machine.id, to: name) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                OpenCodeSettingsSection(model: model, machine: machine, server: server)
            } else { SettingsEmpty("This agent is no longer available.") }
            if let error { SettingsError(error) }
        }
        .task(id: machine.id) { name = server?.agentName ?? "" }
    }
}

private struct OpenCodeSessionLibrary: View {
    @Bindable var model: MachinesStore
    let machineID: String
    let isReady: Bool
    @State private var sessions: [OpenCodeSessionPage.Session] = []
    @State private var cursors: [String?] = [nil]
    @State private var page = 0
    @State private var next: String?
    @State private var busy = false
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Refresh sessions") { load(page: 0) }
                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 26))
                if busy { ProgressView().controlSize(.small) }
            }
            ForEach(sessions) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title).font(.settingsRow)
                        Text(session.directory)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(WovenPalette.mutedForeground).lineLimit(2)
                    }
                    Spacer()
                    Button("Import") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                try await model.importOpenCodeSession(session.id, on: machineID)
                                sessions.removeAll { $0.id == session.id }
                                feedback = "Added to chats."
                            } catch { feedback = error.localizedDescription }
                        }
                    }
                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
                }
            }
            HStack {
                Button("Previous") { load(page: page - 1) }.disabled(page == 0)
                Text("Page \(page + 1) of up to 10").font(.settingsSecondary)
                Button("Next") {
                    if let next {
                        cursors = Array(cursors.prefix(page + 1)) + [next]
                        load(page: page + 1)
                    }
                }.disabled(next == nil || page >= 9)
            }
            .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
            if let feedback { Text(feedback).font(.settingsBody).textSelection(.enabled) }
        }
        .disabled(busy || !isReady)
    }

    private func load(page index: Int) {
        guard cursors.indices.contains(index) else { return }
        busy = true; feedback = nil
        Task {
            defer { busy = false }
            do {
                let result = try await model.openCodeImportableSessions(on: machineID, cursor: cursors[index])
                if index == 0 { cursors = [nil] }
                sessions = result.sessions
                page = index
                next = result.next
                if sessions.isEmpty { feedback = "No sessions available to import." }
            } catch { feedback = error.localizedDescription }
        }
    }
}
