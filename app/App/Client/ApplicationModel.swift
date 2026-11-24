import Foundation
import Observation
import WovenProtocol

/// What a command reports while the UI has no connection to a server.
enum ClientError: LocalizedError, Equatable {
    case notConnected
    /// The command concerns another machine, whose server the UI is not connected to.
    case machineNotConnected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the Woven server."
        case .machineNotConnected(let name): "\(name) is not connected."
        }
    }
}

/// The root of the client layer. It owns the connection to this Mac's server,
/// the direct connections to other machines' servers for live views, and the
/// per-area stores the views read. It does no server work itself.
@MainActor
@Observable
final class ApplicationModel {
    enum State: Equatable {
        case ready
        case failed(String)
    }

    private(set) var state: State = .ready
    /// This Mac's permanent machine identifier, once its server has answered.
    var thisMachineID: String? { server?.remote?.machine.id }
    /// The connection to this Mac's server, once it has been started.
    private(set) var server: ServerConnection?
    /// This Mac's connection and one to each other machine's server.
    private(set) var machineConnections: MachineConnections?
    @ObservationIgnored private var following: Task<Void, Never>?

    let navigation = NavigationStore()
    let machines = MachinesStore()
    let workspace = WorkspaceStore()
    let sessions = SessionsStore()
    let documents = DocumentsStore()
    let databases = DatabasesStore()
    let library = LibraryItemsStore()
    let calendar = CalendarStore()
    let bots = BotsStore()
    let usage = UsageStore()
    let settings = SettingsStore()
    let agentTools = AgentToolsStore()
    let connections = AgentSettingsStore()
    let updates = UpdatesStore()

    /// The browser and document tabs of the asset pane. UI only.
    let workspaceAssets = WorkspaceAssetSession()
    /// Carries out this Mac's server's browser and computer calls.
    @ObservationIgnored private var uiTools: UIToolsStore?

    init() {}

    func retry() {
        state = .ready
        Task { await connect() }
    }

    /// Starts this Mac's server if it is not running, connects to it, and
    /// keeps the stores level with its library for as long as the app runs.
    func connect() async {
        guard server == nil else { return }
        do {
            try await ThisMachineServer.start()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let server = ServerConnection(endpoint: .unix(path: ThisMachineServer.socketPath))
        self.server = server
        let machineConnections = MachineConnections(local: server)
        self.machineConnections = machineConnections
        machines.attach(machineConnections)
        usage.attach(server, machines: machines)
        workspace.attach(server, machines: machines)
        settings.attach(server); connections.attach(machines, settings: settings); updates.attach(machines)
        sessions.attach(server, workspace: workspace)
        agentTools.attach(server, workspace: workspace, settings: settings)
        databases.attach(server, machines: machines)
        library.attach(server, machines: machines)
        documents.attach(server, machines: machines, databases: databases)
        bots.attach(machineConnections, machines: machines, settings: settings)
        calendar.attach(server, workspace: workspace, machines: machines)
        server.start()
        uiTools = UIToolsStore(server: server, assets: workspaceAssets)
        DesktopUpdater.shared.report = { [weak server] event, version in
            _ = try? await server?.call(RecordAppEvent(event, targetVersion: version))
        }
        following = Task { [weak self] in
            await server.follow(SubscribeLibrary(), reply: { [weak self] event in
                self?.restartIfAnotherRelease(server.remote)
                self?.reportOpened(server)
                self?.requestReload(event.tables)
            }, event: { [weak self] event in
                self?.requestReload(event.tables)
            })
        }
    }

    /// Library tables written since the running reload began.
    @ObservationIgnored private var changedTables: Set<String> = []
    @ObservationIgnored private var reloading = false

    /// One reload runs at a time; changes during it bring one more, for the
    /// tables they wrote.
    private func requestReload(_ tables: [String]) {
        changedTables.formUnion(tables)
        guard !reloading else { return }
        reloading = true
        Task {
            while !changedTables.isEmpty {
                let tables = changedTables
                changedTables = []
                await reload(tables)
            }
            reloading = false
        }
    }

    /// Reads again only the areas whose tables changed.
    private func reload(_ tables: Set<String>) async {
        func any(_ names: String...) -> Bool { !tables.isDisjoint(with: names) }
        if any("machines") { await machines.reload() }
        if any("machines", "sessions", "folders", "session_items", "artifacts") { await workspace.refresh() }
        if any("artifacts", "artifact_versions") { await documents.reload() }
        if any("databases") { await databases.refresh() }
        if any("settings", "sealed_secrets") { await settings.reload() }
        if any("schedules", "sessions") { await calendar.reload() }
        if any("schedules", "sessions", "settings") { await agentTools.reload() }
    }

    /// A server left running by another release of the app is restarted once,
    /// so this Mac's server is always the app's own program.
    private func restartIfAnotherRelease(_ remote: Hello?) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        guard let remote, remote.appVersion != version, !restarted else { return }
        restarted = true
        Task { try? await ThisMachineServer.restart() }
    }

    @ObservationIgnored private var restarted = false

    /// Tells this Mac's server once per launch that the app opened, for its
    /// anonymous usage statistics: the app's own release, not one about to be restarted.
    private func reportOpened(_ server: ServerConnection) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        guard !reportedOpening, server.remote?.appVersion == version else { return }
        reportedOpening = true
        Task { _ = try? await server.call(RecordAppEvent(.opened)) }
    }

    @ObservationIgnored private var reportedOpening = false
}
