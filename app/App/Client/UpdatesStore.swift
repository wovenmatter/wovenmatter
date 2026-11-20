import Foundation
import Observation

/// The app release each machine runs and the harness versions on each, as Settings → Updates
/// shows them. The server runs updates; this holds their state and sends the commands.
/// This Mac's harness rows come from `MachinesStore`; app releases and bots are not connected yet.
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
    /// The app and bots part of each machine, by machine id.
    private var appStates: [String: MachineState] = [:]
    @ObservationIgnored private weak var machineStore: MachinesStore?

    func attach(_ machines: MachinesStore) { machineStore = machines }

    /// Per machine, by machine id: the app and bots part, with this Mac's harnesses.
    var machines: [String: MachineState] {
        var result = appStates
        guard let store = machineStore, let thisID = store.thisMachine?.id else { return result }
        var state = result[thisID] ?? MachineState()
        if store.harnessInventoryUnavailable.contains(thisID) && store.harnesses(on: thisID).isEmpty {
            state.harnessError = ClientError.notConnected.localizedDescription
        } else if store.hasReadRuntimes {
            state.harnesses = store.harnesses(on: thisID).filter(\.isInstalled).map { harness in
                let kind = harness.runtimeKind
                let installed = harness.installedVersion
                let latest = harness.components.first?.updateVersion
                return Harness(id: kind.rawValue, name: kind.displayName,
                               versions: latest.map { "\(installed ?? "?") → \($0)" } ?? installed,
                               updateAvailable: harness.updateAvailable,
                               checking: store.isCheckingHarness(kind, on: thisID),
                               updating: store.operation(kind, on: thisID) != nil,
                               error: store.harnessError(kind, on: thisID))
            }
        }
        result[thisID] = state
        return result
    }
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

    func loadIfNeeded() {
        guard let store = machineStore, let thisID = store.thisMachine?.id, !store.hasReadRuntimes else { return }
        store.refreshHarnesses(on: thisID)
    }

    /// Checks this Mac's harnesses for newer releases. The app release is not checked yet.
    func checkAll() async {
        guard let store = machineStore, let thisID = store.thisMachine?.id else {
            failures = [ClientError.notConnected.localizedDescription]
            return
        }
        checking = true
        failures = []
        await store.checkAllHarnesses(on: thisID)
        releaseError = ClientError.notOffered("The release check").localizedDescription
        checkedAt = Date()
        checking = false
    }

    /// Runs the harness updates a request covers on this Mac; app and bots updates are not connected yet.
    func start(_ request: Request) {
        guard let store = machineStore, let thisID = store.thisMachine?.id else {
            failures = [ClientError.notConnected.localizedDescription]
            return
        }
        failures = []
        let outdated = store.harnesses(on: thisID).filter(\.updateAvailable).map(\.runtimeKind)
        let kinds: [AgentRuntimeKind]
        switch request {
        case .everything, .harnesses: kinds = outdated
        case .machine(let id): kinds = id == thisID ? outdated : []
        case .harness(let machineID, let harnessID):
            kinds = machineID == thisID ? AgentRuntimeKind.allCases.filter { $0.rawValue == harnessID } : []
        case .apps, .app, .bots: kinds = []
        }
        if kinds.isEmpty { failures = [ClientError.notConnected.localizedDescription] }
        for kind in kinds { store.update(kind, on: thisID) }
    }
    func confirmBusy() { busyConfirmation = nil }
    func cancelBusy(_ id: UUID) { if busyConfirmation?.id == id { busyConfirmation = nil } }
}
