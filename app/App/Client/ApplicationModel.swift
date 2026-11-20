import Foundation
import Observation
import WovenProtocol

/// What a command reports while the UI has no connection to a server.
enum ClientError: LocalizedError, Equatable {
    case notConnected
    /// The command concerns another machine, whose server the UI is not connected to.
    case machineNotConnected(String)
    /// The server does not offer this yet.
    case notOffered(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the Woven server."
        case .machineNotConnected(let name): "\(name) is not connected."
        case .notOffered(let what): "\(what) is not available yet."
        }
    }
}

/// Long work this Mac's server reports while the window waits for it.
struct StartupProgress: Equatable, Sendable {
    var title: String
    var detail: String
    var fraction: Double?
}

/// The root of the client layer. It owns the connection to this Mac's server
/// (and, later, direct connections to other machines' servers for live views)
/// and the per-area stores the views read. It does no server work itself.
@MainActor
@Observable
final class ApplicationModel {
    enum State: Equatable {
        case starting
        case ready
        case failed(String)
    }

    private(set) var state: State = .ready
    private(set) var startupProgress: StartupProgress?
    /// This Mac's permanent machine identifier, once its server has answered.
    var thisMachineID: String? { server?.remote?.machine.id }
    /// The connection to this Mac's server, once it has been started.
    private(set) var server: ServerConnection?
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

    var activeSessionLimitPresented = false
    var sessionAccessError: String?

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
        machines.attach(server)
        workspace.attach(server, machines: machines)
        settings.attach(server); connections.attach(server, settings: settings); updates.attach(machines)
        sessions.attach(server, workspace: workspace)
        databases.attach(server, machines: machines)
        library.attach(server, machines: machines)
        documents.attach(server, machines: machines, databases: databases)
        server.start()
        following = Task { [weak self] in
            await server.follow(SubscribeLibrary(), reply: { [weak self] _ in
                self?.restartIfAnotherRelease(server.remote)
                self?.requestReload()
            }, event: { [weak self] _ in
                self?.requestReload()
            })
        }
    }

    @ObservationIgnored private var reloadRequested = false
    @ObservationIgnored private var reloading = false

    /// One reload runs at a time; changes during it bring one more.
    private func requestReload() {
        reloadRequested = true
        guard !reloading else { return }
        reloading = true
        Task {
            while reloadRequested {
                reloadRequested = false
                await reloadAll()
            }
            reloading = false
        }
    }

    private func reloadAll() async {
        // The library's own lists first: reading machines' runtimes can take long.
        await workspace.refresh()
        await documents.reload()
        await databases.refresh()
        await machines.reload()
        await settings.reload()
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
}
