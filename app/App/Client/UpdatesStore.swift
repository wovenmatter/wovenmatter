import Foundation
import Observation

/// The app release each machine runs and the harness versions on each, as Settings → Updates
/// shows them. The server runs updates; this holds their state and sends the commands.
@MainActor
@Observable
final class UpdatesStore {
    /// What one Update button covers.
    enum Request: Hashable, Sendable {
        /// Everything on every machine.
        case everything
        /// Woven Matter on every machine, the bots with it.
        case apps
        /// Every harness on every machine.
        case harnesses
        /// Everything on one machine.
        case machine(String)
        /// Woven Matter alone on one machine.
        case app(machineID: String)
        /// The bots, on their home machine.
        case bots(machineID: String)
        case harness(machineID: String, harnessID: String)
    }

    /// One harness on one machine.
    struct Harness: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// "1.2.0 → 1.3.0", or the installed version.
        let versions: String?
        let updateAvailable: Bool
        let checking: Bool
        let updating: Bool
        let error: String?
    }

    /// What one machine has to update.
    struct MachineState: Equatable, Sendable {
        /// A newer Woven Matter release than the one it runs is published.
        var appUpdateAvailable = false
        /// A Linux machine takes the server release this Mac carries, so this Mac updates first.
        var appWaitsForThisMac = false
        var updatingApp = false
        /// Its bots are behind its Woven Matter.
        var botsOutdated = false
        /// Bots whose next update changes their container.
        var botsToUpdate = 0
        var updatingBots = false
        /// Its harnesses; nil until the machine has reported them.
        var harnesses: [Harness]?
        var harnessError: String?

        var hasUpdate: Bool { appUpdateAvailable || botsOutdated || (harnesses ?? []).contains(where: \.updateAvailable) }
        var isUpdating: Bool { updatingApp || updatingBots || (harnesses ?? []).contains(where: \.updating) }
    }

    /// Running work that an update would stop, waiting for the user to agree.
    struct BusyConfirmation: Identifiable, Equatable, Sendable {
        let id: UUID
        let items: [String]
    }

    struct ProgressLine: Identifiable, Equatable, Sendable {
        let id: String
        let text: String
    }

    /// The newest published release, once checked.
    private(set) var latestVersion: String?
    private(set) var checking = false
    private(set) var checkedAt: Date?
    private(set) var releaseError: String?
    /// Per machine, by machine id.
    private(set) var machines: [String: MachineState] = [:]
    private(set) var progress: [ProgressLine] = []
    private(set) var failures: [String] = []
    private(set) var notice: String?
    private(set) var busyConfirmation: BusyConfirmation?
    /// Machines run different Woven Matter releases, so they do not sync.
    private(set) var versionsDiffer = false

    init() {}

    func state(of machineID: String) -> MachineState { machines[machineID] ?? MachineState() }

    var running: Bool { machines.values.contains(where: \.isUpdating) }
    /// Machines with something to update.
    var availableCount: Int { machines.values.filter(\.hasUpdate).count }
    var summary: String {
        if running { return "Updating…" }
        return availableCount == 1 ? "1 device" : "\(availableCount) devices"
    }

    func isUpdating(_ request: Request) -> Bool {
        switch request {
        case .everything: running
        case .apps: machines.values.contains(where: \.updatingApp)
        case .harnesses: machines.values.contains { ($0.harnesses ?? []).contains(where: \.updating) }
        case .machine(let id): state(of: id).isUpdating
        case .app(let id): state(of: id).updatingApp
        case .bots(let id): state(of: id).updatingBots
        case .harness(let machineID, let harnessID):
            (state(of: machineID).harnesses ?? []).contains { $0.id == harnessID && $0.updating }
        }
    }

    /// Whether a request may start: it waits while everything it covers is already updating.
    func canStart(_ request: Request) -> Bool { !isUpdating(request) }

    func loadIfNeeded() {}
    func checkAll() async { failures = [ClientError.notConnected.localizedDescription] }
    func start(_ request: Request) { failures = [ClientError.notConnected.localizedDescription] }
    func confirmBusy() { busyConfirmation = nil }
    func cancelBusy(_ id: UUID) { if busyConfirmation?.id == id { busyConfirmation = nil } }
}
