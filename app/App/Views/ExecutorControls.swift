import SwiftUI
import WebKit
import AppKit
import WovenMatterCore

struct ExecutorAppsList: View {
    let profiles: [ExecutorAppProfile]
    let selection: Set<String>
    let change: (Set<String>) -> Void
    private var apps: [ExecutorAppProfile] {
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.app).inserted }
    }
    private func set(_ app: ExecutorAppProfile, profileID: String?) {
        var next = selection.subtracting(profiles.filter { $0.app == app.app }.map(\.id))
        if let profileID { next.insert(profileID) }
        change(next)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button("Select all") { change(Set(apps.map(\.id))) }
                Button("Deselect all") { change([]) }
            }.buttonStyle(SettingsQuietButtonStyle())
            ForEach(apps) { app in
                let choices = profiles.filter { $0.app == app.app }
                let selected = choices.first { selection.contains($0.id) }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(app.name, isOn: Binding(get: { selected != nil }, set: { set(app, profileID: $0 ? app.id : nil) }))
                    if choices.count > 1, let selected {
                        Picker("Profile", selection: Binding(get: { selected.id }, set: { set(app, profileID: $0) })) {
                            ForEach(choices) { Text($0.profileName).tag($0.id) }
                        }.padding(.leading, 28)
                    } else if let selected {
                        Text(selected.profileName).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 28)
                    }
                }
            }
            if apps.isEmpty { Text("Add apps and configure their profiles in the Executor dashboard, then refresh.").font(.callout).foregroundStyle(.secondary) }
        }
    }
}

struct ExecutorConnectionsCard: View {
    @Bindable var model: ApplicationModel
    @Bindable var tools: WorkspaceAgentToolsModel
    @State private var draft = ExecutorConfiguration()
    @State private var error: String?
    @State private var dashboard = false
    @State private var editing = false
    @State private var preparation: ExecutorConfiguration?

    private var preparing: Bool { tools.executorBusy || tools.settings.executorSetup?.running == true }
    private func perform(_ control: ExecutorControl) {
        Task {
            do {
                try await tools.controlExecutor(control)
                error = nil
                if case .dashboard = control { dashboard = true }
                if case .setup = control { editing = false }
            } catch { self.error = error.localizedDescription }
        }
    }
    var body: some View {
        SettingsCard(title: "Executor", detail: "One connection shared by every agent through the Woven Matter CLI. Each conversation chooses its apps.") {
            if tools.settings.executor == nil || editing {
                Picker("Run Executor", selection: $draft.location) {
                    Text("On this Mac").tag(ExecutorConfiguration.Location.local)
                    Text("On a Linux host").tag(ExecutorConfiguration.Location.remote)
                }
                if draft.location == .remote {
                    HStack {
                        Menu("Choose a machine") {
                            ForEach(model.remoteWorkspaces.machineCandidates) { machine in
                                Button(machine.displayName) {
                                    draft.host = machine.hostName
                                    draft.origin = "https://\(machine.hostName):8443"
                                }
                            }
                            ForEach(model.remoteWorkspaces.workspaces) { workspace in
                                Button(workspace.name) {
                                    draft.host = workspace.hostName; draft.user = workspace.userName ?? ""
                                    draft.origin = "https://\(workspace.hostName):8443"
                                }
                            }
                        }
                        Button("Refresh machines") { model.remoteWorkspaces.discoverMachines() }
                    }.buttonStyle(SettingsQuietButtonStyle())
                    SettingsField("SSH host") { TextField("machine.tailnet.ts.net", text: $draft.host).settingsInput() }
                    SettingsField("SSH username") { TextField("From SSH config", text: $draft.user).settingsInput() }
                    SettingsField("Private HTTPS origin") { TextField("https://machine.tailnet.ts.net:8443", text: $draft.origin).settingsInput() }
                    HStack {
                        Button("Inspect host") { model.remoteWorkspaces.checkHost(hostName: draft.host, userName: draft.user) }
                        if model.remoteWorkspaces.isCheckingHost { ProgressView().controlSize(.small) }
                    }.buttonStyle(SettingsQuietButtonStyle())
                    Text("Uses Woven’s SSH inspection and Docker deployment. Prepare an unready host in Remote workspaces. Deployment adds one standalone container and a private Tailscale HTTPS route on port 8443.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button(draft.location == .local ? "Install and start Executor" : "Deploy Executor") { var value = draft
                        if let previous = tools.settings.executor, previous.location != draft.location || previous.origin != draft.origin {
                            value.id = UUID().uuidString.lowercased(); value.apps = []; value.defaultProfiles = []
                        }
                        if value.location == .remote, model.remoteWorkspaces.preflight(hostName: value.host, userName: value.user)?.preparationRequired == true {
                            preparation = value
                        } else { perform(.setup(value)) } }
                        .disabled(preparing)
                    if editing { Button("Cancel") { editing = false } }
                }.buttonStyle(SettingsQuietButtonStyle())
            } else if let config = tools.settings.executor {
                HStack {
                    Text(config.location == .local ? "Local runtime · This Mac" : "Linux · \(config.host)")
                    Spacer()
                    Button("Open dashboard") { perform(.dashboard) }
                    Button("Refresh apps") { perform(.refresh) }
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(preparing)
                Text("Accounts are connected in Executor’s dashboard. Full access accepts action approvals; requested input still appears in the conversation. App selection remains enforced in every permission mode.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("Default apps for new conversations") {
                    ExecutorAppsList(profiles: config.apps, selection: config.defaultProfiles) { selected in
                        var settings = tools.settings; settings.executor?.defaultProfiles = selected
                        tools.saveSettingsFromUI(settings)
                    }.padding(.top, 8)
                }
                Button("Reinstall or reconnect") { draft = config; editing = true }.buttonStyle(SettingsQuietButtonStyle())
            }
            if preparing { HStack { ProgressView().controlSize(.small); Text("Preparing Executor…") }.font(.callout) }
            if let error = error ?? tools.settings.executorSetup?.error { SettingsError(error) }
        }
        .task { if let config = tools.settings.executorSetup?.configuration ?? tools.settings.executor { draft = config }; model.remoteWorkspaces.discoverMachines() }
        .confirmationDialog("Prepare this Linux host for Executor?", isPresented: Binding(get: { preparation != nil }, set: { if !$0 { preparation = nil } }), titleVisibility: .visible) {
            Button("Authorize preparation and deploy") {
                if let configuration = preparation { perform(.setup(configuration, prepareHost: true)) }
                preparation = nil
            }
            Button("Cancel", role: .cancel) { preparation = nil }
        } message: {
            Text("Uses Woven’s existing host preparation to install Docker when needed, then deploys one Executor container. No agent workspace is created. Existing services and storage are kept.")
        }
        .sheet(isPresented: $dashboard, onDismiss: { perform(.refresh) }) {
            if let url = tools.executorDashboardURL { ExecutorDashboard(url: url) {
                Task { do { try await tools.controlExecutor(.dashboard); if let fresh = tools.executorDashboardURL { NSWorkspace.shared.open(fresh) } }
                    catch { self.error = error.localizedDescription } }
            } }
        }
    }
}

struct ExecutorConversationApps: View {
    @Bindable var tools: WorkspaceAgentToolsModel
    let sessionID: String
    let back: () -> Void
    @State private var error: String?
    @State private var dashboard = false
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                Text("Executor apps").fontWeight(.semibold)
            }
            if let config = tools.settings.executor {
                ExecutorAppsList(profiles: config.apps, selection: tools.policy(for: sessionID).executorProfiles ?? []) { selection in
                    Task { do { try await tools.controlExecutor(.selection(session: sessionID, profiles: selection)); error = nil }
                        catch { self.error = error.localizedDescription } }
                }
                HStack {
                    Button("Open dashboard") {
                        Task { do { try await tools.controlExecutor(.dashboard); dashboard = true } catch { self.error = error.localizedDescription } }
                    }
                    Button("Refresh apps") {
                        Task { do { try await tools.controlExecutor(.refresh) } catch { self.error = error.localizedDescription } }
                    }
                }.buttonStyle(SettingsQuietButtonStyle())
            } else { Text("Set up Executor in Settings → Connections.").foregroundStyle(.secondary) }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
        }
        .disabled(tools.executorBusy || tools.settings.executorSetup?.running == true)
        .sheet(isPresented: $dashboard) {
            if let url = tools.executorDashboardURL { ExecutorDashboard(url: url) {
                Task { do { try await tools.controlExecutor(.dashboard); if let fresh = tools.executorDashboardURL { NSWorkspace.shared.open(fresh) } }
                    catch { self.error = error.localizedDescription } }
            } }
        }
    }
}

/// The local and remote dashboards use the same paired browser flow. Provider
/// OAuth may open a normal browser; Woven never handles account credentials.
private struct ExecutorDashboard: View {
    let url: URL
    let openInBrowser: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Executor").fontWeight(.semibold)
                Spacer()
                Button("Open in browser", action: openInBrowser)
                Button("Done") { dismiss() }
            }.padding(14)
            Divider()
            ExecutorWebView(url: url)
        }.frame(width: 1000, height: 720)
    }
}
private struct ExecutorWebView: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.uiDelegate = nil }
    final class Coordinator: NSObject, WKUIDelegate {
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}
