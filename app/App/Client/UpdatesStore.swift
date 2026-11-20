import Foundation
import Observation

/// The app release each machine runs and the harness versions on each, as Settings → Updates
/// shows them. The server runs updates; this holds their state and sends the commands.
/// This Mac's harness rows come from `MachinesStore`. The newest release is read from the
/// app's update feed, and this Mac updates itself through Sparkle. Updating another machine's
/// Woven Matter and the bots are not connected yet.
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
        for machine in store.machines {
            var state = result[machine.id] ?? MachineState()
            state.appUpdateAvailable = Self.isBehind(machine.appVersion, latest: latestVersion)
            if machine.isThisMachine { state.updatingApp = DesktopUpdater.shared.isInstalling || DesktopUpdater.shared.hasStagedUpdate }
            result[machine.id] = state
        }
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
    var versionsDiffer: Bool {
        guard let store = machineStore, let this = store.thisMachine?.appVersion else { return false }
        return store.machines.contains { !$0.isThisMachine && $0.appVersion != nil && $0.appVersion != this }
    }

    /// True when `version` is older than `latest`, comparing dotted numbers.
    static func isBehind(_ version: String?, latest: String?) -> Bool {
        guard let version, let latest else { return false }
        return version.compare(latest, options: .numeric) == .orderedAscending
    }

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

    /// Reads the newest release once, and this Mac's harnesses when they have not been read.
    func loadIfNeeded() {
        if latestVersion == nil, !checking, !readingRelease {
            readingRelease = true
            Task {
                latestVersion = try? await Self.newestRelease()
                readingRelease = false
            }
        }
        guard let store = machineStore, let thisID = store.thisMachine?.id, !store.hasReadRuntimes else { return }
        store.refreshHarnesses(on: thisID)
    }
    @ObservationIgnored private var readingRelease = false

    /// Checks the update feed for the newest release and this Mac's harnesses for newer ones.
    func checkAll() async {
        guard let store = machineStore, let thisID = store.thisMachine?.id else {
            failures = [ClientError.notConnected.localizedDescription]
            return
        }
        checking = true
        failures = []
        async let release = Self.newestRelease()
        await store.checkAllHarnesses(on: thisID)
        do {
            latestVersion = try await release
            releaseError = nil
        } catch {
            releaseError = error.localizedDescription
        }
        checkedAt = Date()
        checking = false
    }

    /// The newest `sparkle:shortVersionString` in the feed this app updates from.
    static func newestRelease() async throws -> String {
        guard let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:)) else {
            throw ClientError.notOffered("The release check")
        }
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let reader = AppcastVersions()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), let newest = reader.versions.max(by: { isBehind($0, latest: $1) }) else {
            throw URLError(.cannotParseResponse)
        }
        return newest
    }

    /// Runs the updates a request covers on this Mac: its Woven Matter through Sparkle, which
    /// restarts the app and with it the server, and its harnesses. Other machines' Woven Matter
    /// and the bots are not connected yet.
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
        let updatesThisApp: Bool = switch request {
        case .everything, .apps: Self.isBehind(store.thisMachine?.appVersion, latest: latestVersion)
        case .machine(let id), .app(let id): id == thisID && Self.isBehind(store.thisMachine?.appVersion, latest: latestVersion)
        case .harnesses, .harness, .bots: false
        }
        if updatesThisApp {
            if let failure = DesktopUpdater.shared.installUpdate() { failures.append(failure) }
        } else if kinds.isEmpty {
            failures = [ClientError.notOffered("Updating this").localizedDescription]
        }
        for kind in kinds { store.update(kind, on: thisID) }
    }
    func confirmBusy() { busyConfirmation = nil }
    func cancelBusy(_ id: UUID) { if busyConfirmation?.id == id { busyConfirmation = nil } }
}

/// Reads every release version an appcast lists.
private final class AppcastVersions: NSObject, XMLParserDelegate {
    private(set) var versions: [String] = []
    private var text: String?

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if element == "sparkle:shortVersionString" { text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text? += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard element == "sparkle:shortVersionString", let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if !value.isEmpty { versions.append(value) }
        text = nil
    }
}
