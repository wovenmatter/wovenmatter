import Foundation
import Observation

/// What a command reports while the UI has no connection to a server.
enum ClientError: LocalizedError, Equatable {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the Woven server."
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
    private(set) var thisMachineID: String?

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
    }
}
