import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

/// What one Update button in Settings → Updates covers.
enum FleetUpdateScope: String, Codable, Sendable {
    /// Woven Matter on every device and every harness on them.
    case everything
    /// Woven Matter on every device: the apps, Linux servers, bots VMs and bots.
    case apps
    /// Every harness and Pi Durable SDK this Mac can reach.
    case harnesses

    var includesApps: Bool { self != .harnesses }
    var includesHarnesses: Bool { self != .apps }
}

/// One harness, or a workspace's Pi Durable SDKs, on one device.
struct FleetHarness: Identifiable, Equatable {
    enum Location: Hashable {
        case thisMac
        /// A Linux workspace this Mac added.
        case workspace(UUID)
        /// Another Mac, or a Linux host another Mac added, reached with this Mac's member
        /// signature (its device ID).
        case member(String)
    }
    enum Kind: Hashable {
        case runtime(AgentRuntimeKind)
        case piDurableSDK
        /// The Executor runtime behind Woven MCP's app tools, wherever it runs.
        case executor
    }
    let location: Location
    let kind: Kind
    let name: String
    let versions: String
    let updateAvailable: Bool
    let checking: Bool
    let updating: Bool
    let error: String?

    var id: String {
        let place = switch location {
        case .thisMac: "this-mac"
        case .workspace(let id): id.uuidString.lowercased()
        case .member(let id): "member-" + id.lowercased()
        }
        let item = switch kind { case .runtime(let kind): kind.rawValue; case .piDurableSDK: "pi-durable-sdk"; case .executor: "executor" }
        return place + "/" + item
    }
}

/// Settings → Updates: Woven Matter on this Mac and every other device, every harness
/// on them, and the buttons that update one, some or all of it. Each button's update runs
/// alongside the others: it claims the parts it updates (another button skips those), works
/// through them in a fixed order (`DeviceUpdatePlan`, then harnesses), and waits only where
/// two parts can't change at once, such as a server restarting under a harness update.
/// When this Mac is behind the newest release it updates first and the rest continues after
/// it restarts.
@MainActor @Observable
final class FleetUpdatesModel {
    static let shared = FleetUpdatesModel()

    /// What a button asked for.
    enum Request: Equatable, Sendable {
        case scope(FleetUpdateScope)
        case thisMacApp
        /// Just another device's Woven Matter (or Woven server).
        case device(machineID: String)
        /// Everything on one device: its Woven Matter (or Woven server), its bots, and its
        /// harnesses. This Mac's app goes last, since it restarts.
        case machine(machineID: String)
        /// One machine's bots: a Mac's VM, then the bots and everything in their containers.
        case bots(machineID: String)
        case harness(id: String)
        /// Harnesses that were busy on another machine, tried again after "Update now".
        case harnesses(ids: [String])
    }

    /// Work that an update would stop, shown before anything starts.
    struct BusyItem: Identifiable, Equatable {
        let id: String
        let text: String
        var conversationID: String?
        /// A workspace's OpenCode server, stopped before its OpenCode updates.
        var openCodeServer: UUID?
    }
    struct BusyConfirmation: Identifiable {
        let id = UUID()
        let request: Request
        let items: [BusyItem]
    }

    /// Every download a Linux host would run, reviewed once before any of them start.
    struct DownloadReview: Identifiable {
        struct Item: Identifiable {
            let id: String
            let title: String
            let preview: RemoteInstallerPreview
        }
        let id = UUID()
        /// The update waiting on this review; it holds its parts meanwhile.
        let run: UUID
        let request: Request
        let force: Bool
        /// The work the user agreed to stop, stopped only once the review is confirmed.
        let stopping: [BusyItem]
        let items: [Item]
        /// Linux harnesses whose download couldn't be checked, already reported.
        let skipped: Set<String>
    }

    private(set) var release: MacRelease?
    private(set) var releaseError: String?
    private(set) var checking = false
    private(set) var checkedAt: Date?
    /// One thing an update changes: a device's Woven Matter or Woven server, a Mac's bots VM,
    /// a device's bots, or one harness.
    struct Part: Hashable, Sendable {
        enum Kind: Hashable, Sendable { case app, engine, bots, harness }
        let kind: Kind
        let key: String
        /// The device it's on, when another part there can't change at the same time.
        let device: String?

        /// A device's app or server restarts it, so nothing else on that device changes
        /// alongside it; a bots VM restarts the engine its bots run on.
        func conflicts(with other: Part) -> Bool {
            guard let device, device == other.device, key != other.key else { return false }
            if kind == .app || other.kind == .app { return true }
            return Set([kind, other.kind]) == [.engine, .bots]
        }
    }

    /// One running update's progress line.
    struct ProgressLine: Identifiable, Equatable {
        let id: UUID
        let text: String
    }

    /// One button's update, running alongside any others.
    struct Run: Sendable {
        /// What it still has to update; another button skips these. Each goes as it finishes.
        var claimed: Set<String>
        /// What it already updated. Other buttons skip these too until it ends and the
        /// versions it reports are read again.
        var done: Set<String> = []
        /// The part it's changing now.
        var active: Part?
        var progress: String?
        /// Done except for this Mac's restart, which waits for every other update.
        var waitingToRestart = false
        /// It continues an update that restarted this Mac into its new release.
        var resumed = false
    }

    private(set) var runs: [UUID: Run] = [:]
    var running: Bool { !runs.isEmpty }
    /// What each running update is doing now.
    var progress: [ProgressLine] {
        runs.compactMap { id, run in run.progress.map { ProgressLine(id: id, text: $0) } }
            .sorted { ($0.text, $0.id.uuidString) < ($1.text, $1.id.uuidString) }
    }
    private(set) var failures: [String] = []
    /// What happens next when the run is waiting on something outside it.
    private(set) var notice: String?
    var busyConfirmation: BusyConfirmation? { didSet { if busyConfirmation == nil { showNextPrompt() } } }
    var review: DownloadReview? { didSet { if review == nil { showNextPrompt() } } }
    /// Harnesses on other machines, by device ID.
    private(set) var memberInventories: [String: FleetMemberInventory] = [:]
    private(set) var memberErrors: [String: String] = [:]
    private(set) var loadingMembers: Set<String> = []
    private(set) var executor: ExecutorVersions?
    private(set) var executorError: String?

    @ObservationIgnored private weak var model: ApplicationModel?
    /// This run continues one that updated this Mac first.
    @ObservationIgnored private var resumedAfterUpdate = false
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    /// Dialogs asked for while another was showing, shown in turn.
    @ObservationIgnored private var queuedPrompts: [Prompt] = []
    /// A Linux workspace prepares one harness download at a time.
    @ObservationIgnored private var remoteHarnessOwner: UUID?

    private enum Prompt { case busy(BusyConfirmation), review(DownloadReview) }

    private static let resumeKey = "wovenmatter.updates.resume"
    /// A run waiting for this Mac's update. It resumes only into the release it was
    /// waiting for, within a day, and always asks again before stopping anything.
    private struct Resume: Codable { let scope: FleetUpdateScope; let fromVersion: String; let targetVersion: String; let savedAt: Date }

    // MARK: Lifecycle

    /// Called once at launch: continues a run that updated this Mac first.
    func attach(_ model: ApplicationModel) {
        guard self.model == nil else { return }
        self.model = model
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.resumeKey),
              let resume = try? JSONDecoder().decode(Resume.self, from: data) else { return }
        defaults.removeObject(forKey: Self.resumeKey)
        guard Date().timeIntervalSince(resume.savedAt) < 24 * 3_600 else { return }
        guard let current = thisMacVersion, current == resume.targetVersion
                || DeviceUpdatePlan.isNewer(current, than: resume.targetVersion) else {
            if resume.fromVersion == thisMacVersion {
                notice = "This Mac's update didn't finish, so the rest wasn't updated. Update everything in Settings → Updates to try again."
            }
            return
        }
        notice = "This Mac is updated. Continuing with your other devices and harnesses…"
        resumeTask = Task { [weak self] in
            // Give the background server and the device list a moment to come up.
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            await self.checkAll()
            self.notice = nil
            self.resumedAfterUpdate = true
            self.start(.scope(resume.scope))
        }
    }

    // MARK: What is installed

    var thisMacVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The release every device is brought to: the newest published one, or this Mac's
    /// when the newest can't be checked.
    var targetVersion: String? { release?.version ?? thisMacVersion }

    /// A build from source (`scripts/build_and_run.sh`): its version is a placeholder, and it
    /// never replaces itself with a release.
    var isDevelopmentBuild: Bool { DevelopmentLaunch.mode != nil }

    var thisMacIsBehind: Bool {
        !isDevelopmentBuild && DeviceUpdatePlan.thisMacIsBehind(thisMacVersion: thisMacVersion, latestVersion: release?.version)
    }

    /// Other Macs and Linux machines, by name.
    var devices: [BotMachine] {
        (model?.bots.machines ?? []).filter { $0.kind != .thisMac }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func deviceIsOutdated(_ machine: BotMachine) -> Bool {
        guard machine.state != .unreachable else { return false }
        if machine.kind == .linux {
            if !DeviceUpdatePlan.linuxHostIsCurrent(machine, thisMacVersion: thisMacVersion) { return true }
        } else if !DeviceUpdatePlan.macIsCurrent(machine, thisMacVersion: thisMacVersion) { return true }
        guard let app = machine.versions.app, let target = targetVersion else { return false }
        return DeviceUpdatePlan.isNewer(target, than: app)
    }

    /// A device's own Update button: a Mac installs the newest release; a Linux host can
    /// only receive this Mac's, so it waits for this Mac when this Mac is behind.
    func canUpdate(_ machine: BotMachine) -> Bool {
        guard machine.state != .unreachable else { return false }
        if machine.kind == .linux { return !DeviceUpdatePlan.linuxHostIsCurrent(machine, thisMacVersion: thisMacVersion) }
        return deviceIsOutdated(machine)
    }

    /// Bots run on one machine at a time: the one whose bots are on (not off or unreachable).
    func hasBots(_ machine: BotMachine) -> Bool {
        machine.versions.runtime != nil && ![.off, .unreachable].contains(machine.state)
    }

    /// Where a machine's harnesses are listed: this Mac, a Linux workspace this Mac added, or
    /// another member device.
    func harnessLocation(for machine: BotMachine) -> FleetHarness.Location {
        if machine.kind == .thisMac { return .thisMac }
        if let workspace = workspace(for: machine) { return .workspace(workspace.id) }
        return .member(machine.id)
    }

    /// Anything on this machine has an update: its app or server, its bots, or a harness.
    func machineHasUpdate(_ machine: BotMachine) -> Bool {
        let app = machine.kind == .thisMac ? thisMacIsBehind : canUpdate(machine)
        return app || (hasBots(machine) && botsAreOutdated(machine))
            || harnesses(on: harnessLocation(for: machine)).contains(where: \.updateAvailable)
    }

    /// This Mac's name as its other devices know it (its computer name).
    var thisMacName: String {
        model?.bots.thisMachine?.name ?? DevelopmentLaunch.deviceName()
    }

    /// Bots on a machine with an update waiting: older tools, helper or base image. (Their
    /// version is the machine's Woven Matter version; a machine behind is updated as a device.)
    func botsAreOutdated(_ machine: BotMachine) -> Bool {
        botsToUpdate(machine) > 0
    }

    /// Bots whose containers came from an older base image (they move on their next update).
    func staleBots(_ machine: BotMachine) -> Int {
        model?.bots.session(for: machine.id)?.runtimeStatus?.image?.staleBots ?? 0
    }

    /// Bots whose next update changes their tools, helper or base image.
    func botsToUpdate(_ machine: BotMachine) -> Int {
        model?.bots.session(for: machine.id)?.runtimeStatus?.image?.botsToUpdate ?? 0
    }

    private func refreshExecutor() async {
        guard let model, model.agentTools?.settings.executor != nil else { executor = nil; return }
        do { executor = try await model.executorVersions(); executorError = nil }
        catch { executorError = error.localizedDescription }
    }

    /// Asks each machine's bots runtime what its containers carry.
    private func refreshBotImages() async {
        guard let model else { return }
        for machine in model.bots.botMachines { await model.bots.session(for: machine.id)?.refreshRuntimeStatus() }
    }

    /// Another machine whose harnesses this Mac reaches by signed request: every reachable
    /// Mac, and Linux hosts this Mac didn't add.
    func isMember(_ machine: BotMachine) -> Bool {
        machine.state != .unreachable && workspace(for: machine) == nil
    }

    /// The configured Linux workspace a machine serves, whose harnesses this Mac manages.
    func workspace(for machine: BotMachine) -> RemoteWorkspaceConfiguration? {
        guard let id = machine.workspaceID, let model else { return nil }
        return model.remoteWorkspaces.workspaces.first { $0.id.uuidString.lowercased() == id }
    }

    func harnesses(on location: FleetHarness.Location) -> [FleetHarness] {
        guard let model else { return [] }
        switch location {
        case .thisMac:
            var rows: [FleetHarness] = Self.localKinds.compactMap { kind in
                guard let inventory = model.runtimeInventories[kind], inventory.isInstalled else { return nil }
                let failed = model.failedRuntimeUpdateKinds.contains(kind)
                return FleetHarness(location: .thisMac, kind: .runtime(kind), name: kind.displayName, versions: inventory.summary,
                                    updateAvailable: inventory.updateAvailable || failed,
                                    checking: model.checkingRuntimeKinds.contains(kind),
                                    updating: model.updatingRuntimeKinds.contains(kind),
                                    error: failed ? model.runtimeFailureDetails[kind] ?? "The last update failed." : nil)
            }
            if let sdk = sdkRow(location: .thisMac, key: "local") { rows.insert(sdk, at: 0) }
            if let executor, let config = model.agentTools?.settings.executor {
                let setup = model.agentTools?.settings.executorSetup
                let place = config.location == .remote ? " on \(config.host)" : ""
                rows.append(FleetHarness(location: .thisMac, kind: .executor, name: "Executor" + place,
                                         versions: "executor " + (executor.installed ?? "version unavailable")
                                            + (executor.updateAvailable ? executor.latest.map { " → \($0)" } ?? "" : ""),
                                         updateAvailable: executor.updateAvailable, checking: false,
                                         updating: setup?.running == true, error: setup?.error ?? executorError))
            }
            return rows
        case .workspace(let id):
            let remote = model.remoteWorkspaces
            var rows: [FleetHarness] = (remote.runtimeMaintenance[id] ?? [])
                .filter { $0.installed && $0.source != "system" && $0.id != .defaultAgent }
                .sorted { $0.id.presentationRank < $1.id.presentationRank }
                .map { runtime in
                    let failed = runtime.operation?.status == "failed" ? runtime.operation?.error : nil
                    return FleetHarness(location: location, kind: .runtime(runtime.id), name: runtime.displayName,
                                        versions: runtime.components.map(Self.componentVersion).joined(separator: " · "),
                                        updateAvailable: runtime.updateAvailable,
                                        checking: remote.checkingRuntimeIDs[id]?.contains(runtime.id) == true,
                                        updating: runtime.operation?.status == "running",
                                        error: failed ?? remote.actionErrors[id]?[runtime.id])
                }
            if let sdk = sdkRow(location: location, key: id.uuidString.lowercased()) { rows.insert(sdk, at: 0) }
            return rows
        case .member(let machineID):
            guard let inventory = memberInventories[machineID.lowercased()] else { return [] }
            let bots = model.bots
            func job(_ item: String) -> BotsJob? { bots.job(.updateHarness, target: machineID.lowercased() + "/" + item) }
            var rows: [FleetHarness] = inventory.runtimes
                .sorted { $0.id.presentationRank < $1.id.presentationRank }
                .map { runtime in
                    let job = job(runtime.id.rawValue)
                    let failed = runtime.operation?.status == "failed" ? runtime.operation?.error : nil
                    return FleetHarness(location: location, kind: .runtime(runtime.id), name: runtime.displayName,
                                        versions: runtime.components.map(Self.componentVersion).joined(separator: " · "),
                                        updateAvailable: runtime.updateAvailable, checking: loadingMembers.contains(machineID.lowercased()),
                                        updating: job?.running == true || runtime.operation?.status == "running",
                                        error: job?.running == false ? job?.error : failed)
                }
            if let status = inventory.sdks, !status.sdks.isEmpty {
                let job = job("pi-durable-sdk")
                rows.insert(FleetHarness(location: location, kind: .piDurableSDK, name: "Pi Durable SDK",
                                         versions: Self.sdkVersions(status),
                                         updateAvailable: status.sdks.contains { $0.updateAvailable || $0.consistent == false },
                                         checking: loadingMembers.contains(machineID.lowercased()), updating: job?.running == true,
                                         error: job?.running == false ? job?.error : nil), at: 0)
            }
            return rows
        }
    }

    /// Every harness this Mac can update: its own, each Linux workspace it added, then
    /// every other machine's.
    var allHarnesses: [FleetHarness] {
        guard let model else { return [] }
        return harnesses(on: .thisMac) + model.remoteWorkspaces.workspaces.flatMap { harnesses(on: .workspace($0.id)) }
            + devices.filter(isMember).flatMap { harnesses(on: .member($0.id)) }
    }

    /// How many things have an update (rows say which; only whether any do is shown).
    var availableCount: Int {
        (thisMacIsBehind ? 1 : 0)
            + devices.filter { deviceIsOutdated($0) || botsAreOutdated($0) }.count
            + allHarnesses.filter(\.updateAvailable).count
    }

    var summary: String {
        if running { return "Updating…" }
        if busyConfirmation != nil || review != nil { return "Waiting for you" }
        if checking && checkedAt == nil { return "Checking…" }
        if availableCount > 0 { return "Updates available" }
        return checkedAt == nil ? "Not checked yet" : "Up to date"
    }

    private static let localKinds: [AgentRuntimeKind] = [.codex, .claudeCode, .grokBuild, .opencode]

    private static func componentVersion(_ component: RemoteRuntimeComponent) -> String {
        let installed = component.installed ? (component.installedVersion ?? "version unavailable") : "missing"
        return "\(component.displayName) \(installed)" + (component.availableUpdateVersion.map { " → \($0)" } ?? "")
    }

    private func sdkRow(location: FleetHarness.Location, key: String) -> FleetHarness? {
        guard let model else { return nil }
        let state = model.connections.sdks.state(for: key)
        guard let status = state.status, !status.sdks.isEmpty else { return nil }
        return FleetHarness(location: location, kind: .piDurableSDK, name: "Pi Durable SDK", versions: Self.sdkVersions(status),
                            updateAvailable: status.sdks.contains { $0.updateAvailable || $0.consistent == false },
                            checking: state.busy && state.operation?.action != .update,
                            updating: state.operation?.action == .update, error: state.error)
    }

    private static func sdkVersions(_ status: DefaultAgentSDKStatus) -> String {
        status.sdks.map { sdk in
            "\(sdk.displayName) \(sdk.installedVersion ?? "not installed")"
                + (sdk.updateAvailable ? sdk.latestVersion.map { " → \($0)" } ?? "" : "")
        }.joined(separator: " · ")
    }

    func workspaceName(_ location: FleetHarness.Location) -> String {
        switch location {
        case .thisMac: return "this Mac"
        case .workspace(let id): return model?.remoteWorkspaces.configuration(id: id)?.name ?? "a workspace"
        case .member(let id): return devices.first { $0.id.lowercased() == id.lowercased() }?.name ?? "another device"
        }
    }

    // MARK: Checking

    /// Loads what is installed without asking the internet, once per window.
    func loadIfNeeded() {
        guard let model else { return }
        if model.runtimeInventories.isEmpty { model.refreshRuntimeInventory() }
        requestSDKs(.status, onlyMissing: true)
        if release == nil, releaseError == nil, !checking { Task { await checkRelease() } }
        Task {
            await model.bots.refresh()
            await refreshBotImages()
            if executor == nil { await refreshExecutor() }
            await refreshMembers(checkLatest: false, onlyMissing: true)
        }
    }

    /// Asks every other machine for its harnesses, all at once.
    func refreshMembers(checkLatest: Bool, onlyMissing: Bool = false, only: Set<String>? = nil) async {
        guard let model else { return }
        let machines = devices.filter(isMember).map { $0.id.lowercased() }
            .filter { only?.contains($0) ?? true }
            .filter { !onlyMissing || memberInventories[$0] == nil }
            .filter { !loadingMembers.contains($0) }
        loadingMembers.formUnion(machines)
        // Each machine is asked at once; their answers land as they come.
        let asks = machines.map { machineID in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.loadingMembers.remove(machineID) }
                do {
                    let reply = try await model.bots.query(.memberInventory(machineID: machineID, checkLatest: checkLatest))
                    guard let inventory = reply.memberInventory else { throw FleetUpdateError("It didn't report its harnesses.") }
                    self.memberInventories[machineID] = inventory
                    self.memberErrors[machineID] = nil
                } catch {
                    self.memberErrors[machineID] = error.localizedDescription
                }
            }
        }
        for ask in asks { await ask.value }
    }

    /// Check now: the newest release, every device and every harness's newest version.
    func checkAll() async {
        guard let model, !checking else { return }
        checking = true
        defer { checking = false; checkedAt = Date() }
        async let releaseCheck: Void = checkRelease()
        model.refreshRuntimeInventory()
        requestSDKs(.check, onlyMissing: false)
        for configuration in model.remoteWorkspaces.workspaces where model.remoteWorkspaces.statuses[configuration.id]?.running == true {
            for runtime in model.remoteWorkspaces.runtimeMaintenance[configuration.id] ?? [] where runtime.installed && runtime.source != "system" {
                model.remoteWorkspaces.checkRuntimeUpdates(runtime.id, configuration: configuration)
            }
        }
        await model.bots.refresh()
        await refreshBotImages()
        await refreshExecutor()
        await refreshMembers(checkLatest: true)
        await releaseCheck
        // Harness checks report through their own models; give them a moment to land.
        _ = await wait(timeout: .seconds(30)) { [weak self] in self?.anyHarnessChecking == false }
    }

    private var anyHarnessChecking: Bool {
        guard let model else { return false }
        return !model.checkingRuntimeKinds.isEmpty || model.checkingRuntimeInventory
            || model.remoteWorkspaces.checkingRuntimeIDs.values.contains { !$0.isEmpty }
            || model.connections.sdks.isBusy
    }

    private func checkRelease() async {
        releaseError = nil
        do { release = try await MacManagement().latestRelease() }
        catch { releaseError = error.localizedDescription }
    }

    private func requestSDKs(_ action: DefaultAgentSDKRequest.Action, onlyMissing: Bool) {
        guard let model else { return }
        let sdks = model.connections.sdks
        let targets: [UUID?] = [nil] + model.remoteWorkspaces.workspaces
            .filter { model.remoteWorkspaces.statuses[$0.id]?.running == true }.map(\.id)
        for workspaceID in targets {
            let command = DefaultAgentSDKCommand(workspaceID: workspaceID, request: .init(action: action))
            let state = sdks.state(for: command.key)
            guard !state.busy, !onlyMissing || state.status == nil else { continue }
            sdks.request(command, connections: model.connections, remoteWorkspaces: model.remoteWorkspaces)
        }
    }

    // MARK: Updating

    /// A button was pressed. Busy work is listed first and stops only when the user says so.
    func start(_ request: Request) {
        guard review == nil, busyConfirmation == nil, model != nil, canStart(request) else { return }
        if !running { failures = [] }
        notice = nil
        let busy = busyWork(for: request)
        if !busy.isEmpty {
            busyConfirmation = .init(request: request, items: busy)
            return
        }
        Task { await proceed(request, force: false) }
    }

    /// "Update now" on the busy notice: stops that work, then updates.
    func confirmBusy() {
        guard let confirmation = busyConfirmation else { return }
        busyConfirmation = nil
        Task { await proceed(confirmation.request, force: true, stopping: confirmation.items) }
    }

    func cancelBusy(_ id: UUID? = nil) {
        guard let confirmation = busyConfirmation, id == nil || confirmation.id == id else { return }
        // A resumed update the user cancelled doesn't carry over to a later one.
        if case .scope(let scope) = confirmation.request, scope.includesApps { resumedAfterUpdate = false }
        busyConfirmation = nil
    }

    func confirmReview() {
        guard let review else { return }
        self.review = nil
        let previews = Dictionary(uniqueKeysWithValues: review.items.map { ($0.id, $0.preview) })
        Task { await run(review.run, review.request, force: review.force, stopping: review.stopping, previews: previews, skipped: review.skipped) }
    }

    func cancelReview(_ id: UUID? = nil) {
        guard let review, id == nil || review.id == id else { return }
        runs[review.run] = nil
        self.review = nil
    }

    // MARK: Updates running side by side

    /// Whether any running update is changing, or is about to change, this part.
    func isUpdating(_ part: Part) -> Bool { runs.values.contains { $0.claimed.contains(part.key) } }
    func isUpdatingApp(_ machine: BotMachine) -> Bool {
        isUpdating(machine.kind == .thisMac ? thisMacAppPart : appPart(machine.id))
    }
    var isUpdatingThisMacApp: Bool { isUpdating(thisMacAppPart) }
    func isUpdatingBots(_ machine: BotMachine) -> Bool { isUpdating(enginePart(machine.id)) || isUpdating(botsPart(machine.id)) }
    func isUpdatingHarness(_ harness: FleetHarness) -> Bool { isUpdating(part(harness)) }
    /// Anything on that device, for its row's progress.
    func isUpdatingAnything(on machine: BotMachine) -> Bool {
        isUpdatingApp(machine) || isUpdatingBots(machine)
            || harnesses(on: harnessLocation(for: machine)).contains(where: isUpdatingHarness)
    }

    /// Whether a button has anything left to do that no running update already covers.
    func canStart(_ request: Request) -> Bool {
        if case .scope(let scope) = request, scope.includesApps, thisMacIsBehind {
            return !isUpdating(thisMacAppPart)
        }
        return !pendingParts(for: request).isEmpty
    }

    /// Whether everything a button covers is already updating, or was updated by an update
    /// still running.
    func isUpdating(_ request: Request) -> Bool {
        if case .scope(let scope) = request, scope.includesApps, thisMacIsBehind { return isUpdating(thisMacAppPart) }
        let all = parts(for: request), covered = coveredKeys
        return !all.isEmpty && all.allSatisfy { covered.contains($0.key) }
    }

    private var coveredKeys: Set<String> { Set(runs.values.flatMap { $0.claimed.union($0.done) }) }

    /// What a button would update that no running update already covers.
    func pendingParts(for request: Request, resumed: Bool? = nil) -> [Part] {
        let covered = coveredKeys
        return parts(for: request, resumed: resumed).filter { !covered.contains($0.key) }
    }

    private func parts(for request: Request, resumed: Bool? = nil) -> [Part] {
        let parts = deviceSteps(for: request, resumed: resumed).map(part) + harnessTargets(for: request).map(part)
        var seen = Set<String>()
        return parts.filter { seen.insert($0.key).inserted }
    }

    private var thisMacAppPart: Part { .init(kind: .app, key: "app:this-mac", device: nil) }
    private func appPart(_ machineID: String) -> Part { .init(kind: .app, key: "app:" + machineID.lowercased(), device: machineID.lowercased()) }
    private func botsPart(_ machineID: String) -> Part { .init(kind: .bots, key: "bots:" + machineID.lowercased(), device: machineID.lowercased()) }
    private func enginePart(_ machineID: String) -> Part { .init(kind: .engine, key: "engine:" + machineID.lowercased(), device: machineID.lowercased()) }

    private func part(_ step: DeviceUpdatePlan.Step) -> Part {
        switch step {
        case .linuxHost(let id, _), .mac(let id, _): appPart(id)
        case .engine(let id, _): enginePart(id)
        case .bots(let id, _): botsPart(id)
        case .thisMacApp: thisMacAppPart
        }
    }

    private func part(_ harness: FleetHarness) -> Part {
        // This Mac's own restart waits for every other update instead.
        let device: String? = switch harness.location {
        case .thisMac: nil
        case .member(let id): id.lowercased()
        case .workspace(let id): devices.first { workspace(for: $0)?.id == id }?.id.lowercased()
        }
        return .init(kind: .harness, key: harness.id, device: device)
    }

    private func say(_ run: UUID, _ text: String?) { runs[run]?.progress = text }

    /// Waits until nothing else is changing something that can't change alongside `part`,
    /// then marks it as this run's. Returns false when the run doesn't hold it, or when the
    /// other update never finished.
    private func begin(_ part: Part, in run: UUID) async -> Bool {
        guard runs[run]?.claimed.contains(part.key) == true, await waitForConflicts(part, in: run) else { return false }
        // No suspension between the check and the claim, so two runs can't both pass.
        runs[run]?.active = part
        return true
    }

    /// Waits while another update changes something that can't change alongside `part`.
    private func waitForConflicts(_ part: Part, in run: UUID) async -> Bool {
        let name = part.device.flatMap { device in devices.first { $0.id.lowercased() == device }?.name } ?? "that device"
        let blocked: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.runs.contains { $0.key != run && $0.value.active.map(part.conflicts) == true }
        }
        guard blocked() else { return true }
        let previous = runs[run]?.progress
        say(run, "Waiting for another update on that device to finish…")
        guard await wait(timeout: .seconds(3_600), until: { !blocked() }) else {
            failures.append("\(name): another update there didn't finish, so this one was skipped. Try again.")
            return false
        }
        say(run, previous)
        return true
    }

    /// `updated`: it succeeded, and what it reports may lag until the run reads it again.
    private func finish(_ part: Part, in run: UUID, updated: Bool = false) {
        runs[run]?.active = nil
        if runs[run]?.claimed.remove(part.key) != nil, updated { runs[run]?.done.insert(part.key) }
    }

    /// Holds `part` while a preview asks its device, so a restart there waits for it.
    private func holdForPreview(_ part: Part, in run: UUID) async -> Bool {
        guard await waitForConflicts(part, in: run) else { return false }
        runs[run]?.active = part
        return true
    }

    /// Before this Mac restarts into its update, every other update finishes. False when
    /// they never did, and this Mac isn't restarted.
    private func waitForOtherRuns(_ run: UUID) async -> Bool {
        runs[run]?.waitingToRestart = true
        let othersDone: @MainActor () -> Bool = { [weak self] in
            self?.runs.allSatisfy { $0.key == run || $0.value.waitingToRestart } ?? true
        }
        guard !othersDone() else { return true }
        say(run, "Waiting for your other updates to finish before this Mac restarts…")
        guard await wait(timeout: .seconds(7_200), until: othersDone) else {
            notice = "Your other updates are still running, so this Mac wasn't updated. Update this Mac when they finish."
            return false
        }
        return true
    }

    private func present(_ prompt: Prompt) {
        if busyConfirmation == nil, review == nil { show(prompt) } else { queuedPrompts.append(prompt) }
    }

    private func show(_ prompt: Prompt) {
        switch prompt {
        case .busy(let confirmation): busyConfirmation = confirmation
        case .review(let review): self.review = review
        }
    }

    /// The next dialog waits a moment so the last one has finished closing.
    private func showNextPrompt() {
        guard !queuedPrompts.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.busyConfirmation == nil, self.review == nil, !self.queuedPrompts.isEmpty else { return }
            self.show(self.queuedPrompts.removeFirst())
        }
    }

    /// Either updates this Mac first, or reviews the downloads and runs the rest. Nothing
    /// is stopped until the run starts.
    private func proceed(_ request: Request, force: Bool, stopping: [BusyItem] = []) async {
        // Only one update continues a restart into a new release.
        var resumed = false
        if case .scope(let scope) = request, scope.includesApps {
            resumed = resumedAfterUpdate
            resumedAfterUpdate = false
        }
        let parts = pendingParts(for: request, resumed: resumed)
        let id = UUID()
        if case .scope(let scope) = request, scope.includesApps, thisMacIsBehind, let version = thisMacVersion,
           let target = release?.version {
            // Linux hosts can only receive this Mac's release, so this Mac goes first. Its
            // own restart ends its chats; the rest resumes after it, asking again.
            guard !isUpdating(thisMacAppPart) else { return }
            runs[id] = Run(claimed: Set(parts.map(\.key) + [thisMacAppPart.key]))
            let ready = await waitForOtherRuns(id)
            runs[id] = nil
            guard ready else { return }
            if let data = try? JSONEncoder().encode(Resume(scope: scope, fromVersion: version, targetVersion: target, savedAt: Date())) {
                UserDefaults.standard.set(data, forKey: Self.resumeKey)
            }
            DesktopUpdater.shared.checkForUpdates()
            notice = "Install the update in the window that opened. After Woven Matter restarts, it continues with your other devices and harnesses."
            return
        }
        guard !parts.isEmpty else { return }
        let keys = Set(parts.map(\.key))
        runs[id] = Run(claimed: keys, progress: "Checking downloads…", resumed: resumed)
        var items: [DownloadReview.Item] = []
        var skipped: Set<String> = []
        // A preview asks the device, so it waits for a server restarting there.
        for target in remoteHarnessTargets(for: request) where keys.contains(target.harness.id) {
            guard await holdForPreview(part(target.harness), in: id) else { skipped.insert(target.harness.id); continue }
            let previewed = await preview(target)
            runs[id]?.active = nil
            switch previewed {
            case .success(let preview):
                items.append(.init(id: target.harness.id, title: "\(target.harness.name) on \(target.configuration.name)", preview: preview))
            case .failure(let error):
                skipped.insert(target.harness.id)
                failures.append("\(target.harness.name) on \(target.configuration.name): \(error.localizedDescription)")
            }
        }
        // Other machines: a Linux host names its download; a Mac updates from its registries.
        for harness in harnessTargets(for: request) where keys.contains(harness.id) {
            guard case .member(let machineID) = harness.location, case .runtime(let kind) = harness.kind else { continue }
            guard await holdForPreview(part(harness), in: id) else { skipped.insert(harness.id); continue }
            defer { runs[id]?.active = nil }
            do {
                let reply = try await model!.bots.query(.memberInstallerPreview(machineID: machineID, kind: kind))
                if let preview = reply.installerPreview {
                    items.append(.init(id: harness.id, title: "\(harness.name) on \(workspaceName(harness.location))", preview: preview))
                }
            } catch {
                skipped.insert(harness.id)
                failures.append("\(harness.name) on \(workspaceName(harness.location)): \(error.localizedDescription)")
            }
        }
        say(id, nil)
        if items.isEmpty { await run(id, request, force: force, stopping: stopping, previews: [:], skipped: skipped) }
        else { present(.review(.init(run: id, request: request, force: force, stopping: stopping, items: items, skipped: skipped))) }
    }

    /// `force` stops only the work the user was shown. Another machine is forced only on
    /// the retry its own busy answer asked for, never by a choice about this Mac's chats.
    private func run(_ id: UUID, _ request: Request, force: Bool, stopping: [BusyItem], previews: [String: RemoteInstallerPreview],
                     skipped: Set<String>) async {
        guard let model, runs[id] != nil else { return }
        defer { runs[id] = nil }
        if force { await stop(stopping, run: id) }
        let forceOtherMacs: Bool = if case .harnesses = request { force } else { false }
        await model.bots.refresh()
        var restartsThisMac = false
        for step in deviceSteps(for: request, resumed: runs[id]?.resumed ?? false) {
            let part = part(step)
            if step == .thisMacApp { restartsThisMac = runs[id]?.claimed.contains(part.key) == true; continue }
            guard await begin(part, in: id) else { continue }
            await perform(step, run: id)
            finish(part, in: id)
        }
        var busyElsewhere: [FleetHarness] = []
        for harness in harnessTargets(for: request) {
            let part = part(harness)
            // A download that couldn't be checked was reported before the review.
            if skipped.contains(harness.id) { finish(part, in: id); continue }
            guard await begin(part, in: id) else { continue }
            say(id, "Updating \(harness.name) on \(workspaceName(harness.location))…")
            let failure = await update(harness, preview: previews[harness.id], force: forceOtherMacs, run: id)
            if failure == nil, case .member(let machineID) = harness.location {
                await refreshMembers(checkLatest: false, only: [machineID.lowercased()])
            }
            finish(part, in: id, updated: failure == nil)
            switch failure {
            case nil: break
            case FleetBusyError.message? where !forceOtherMacs && isOtherMac(harness.location):
                busyElsewhere.append(harness)
            case FleetBusyError.message?:
                failures.append("\(harness.name) on \(workspaceName(harness.location)): Chats there are using it. Try again when they finish.")
            case let failure?: failures.append("\(harness.name) on \(workspaceName(harness.location)): \(failure)")
            }
        }
        // Chats on another machine can't be seen from here before it answers; offer to stop them now.
        if !busyElsewhere.isEmpty {
            present(.busy(.init(request: .harnesses(ids: busyElsewhere.map(\.id)), items: busyElsewhere.map {
                BusyItem(id: $0.id, text: "\($0.name) on \(workspaceName($0.location)) is in use by chats running there.")
            })))
        }
        say(id, nil)
        await refreshMembers(checkLatest: false)
        await refreshBotImages()
        await model.bots.refresh()
        // This Mac's app restarts, so it goes after everything else, this update's and others'.
        if restartsThisMac, await waitForOtherRuns(id) {
            say(id, "Checking for an update to this Mac…")
            DesktopUpdater.shared.checkForUpdates()
        }
    }

    /// Another Mac stops its own chats when asked; a Linux host can't be forced.
    private func isOtherMac(_ location: FleetHarness.Location) -> Bool {
        guard case .member(let id) = location else { return false }
        return devices.first { $0.id.lowercased() == id.lowercased() }?.kind == .mac
    }

    // MARK: Which steps

    /// `resumed` is whether the update continues this Mac's restart into a new release
    /// (by default, whether one is waiting to).
    private func deviceSteps(for request: Request, resumed: Bool? = nil) -> [DeviceUpdatePlan.Step] {
        let steps = plannedSteps(for: request, resumed: resumed ?? resumedAfterUpdate)
        return isDevelopmentBuild ? steps.filter { $0 != .thisMacApp } : steps
    }

    private func plannedSteps(for request: Request, resumed: Bool = false) -> [DeviceUpdatePlan.Step] {
        guard let model else { return [] }
        let plan = DeviceUpdatePlan.steps(machines: model.bots.machines, thisMacVersion: thisMacVersion)
        switch request {
        case .scope(let scope):
            guard scope.includesApps else { return [] }
            // A machine's VM and bots update with its app or server, when its bots are
            // behind, or on this Mac after it restarted into a new release.
            let updated = Set(plan.compactMap { step -> String? in
                switch step {
                case .linuxHost(let id, _), .mac(let id, _): id
                default: nil
                }
            })
            let thisMac = model.bots.thisMachine?.id
            return plan.filter { step in
                switch step {
                case .engine(let id, _), .bots(let id, _):
                    updated.contains(id) || (id == thisMac && resumed)
                        || model.bots.machines.first(where: { $0.id == id }).map(botsAreOutdated) == true
                default: true
                }
            }
        case .thisMacApp:
            return [.thisMacApp]
        case .machine(let machineID):
            // Its app or server, then its bots (after an app update their runtime is new too).
            guard let machine = model.bots.machines.first(where: { $0.id == machineID }) else { return [] }
            let isThisMac = machine.kind == .thisMac
            let app = isThisMac ? [] : plannedSteps(for: .device(machineID: machineID))
            let bots = hasBots(machine) && (!app.isEmpty || botsAreOutdated(machine))
                ? plannedSteps(for: .bots(machineID: machineID)) : []
            return app + bots + (isThisMac && thisMacIsBehind ? [.thisMacApp] : [])
        case .device(let machineID):
            // Just that device's Woven Matter or Woven server; its bots have their own row.
            var steps = plan.filter { step in
                switch step {
                case .linuxHost(let id, _), .mac(let id, _): id == machineID
                case .engine, .bots, .thisMacApp: false
                }
            }
            // Another Mac installs the newest release itself, even when this Mac is behind it.
            if let machine = devices.first(where: { $0.id == machineID }), machine.kind == .mac, deviceIsOutdated(machine),
               !steps.contains(.mac(id: machine.id, name: machine.name)) {
                steps.insert(.mac(id: machine.id, name: machine.name), at: 0)
            }
            return steps
        case .bots(let machineID):
            guard let machine = model.bots.machines.first(where: { $0.id == machineID }) else { return [] }
            return (machine.kind == .linux ? [] : [.engine(machineID: machine.id, name: machine.displayName)])
                + [.bots(machineID: machine.id, name: machine.displayName)]
        case .harness, .harnesses: return []
        }
    }

    private func harnessTargets(for request: Request) -> [FleetHarness] {
        switch request {
        case .scope(let scope): scope.includesHarnesses ? allHarnesses.filter(\.updateAvailable) : []
        case .harness(let id): allHarnesses.filter { $0.id == id }
        case .harnesses(let ids): allHarnesses.filter { ids.contains($0.id) }
        case .machine(let machineID):
            model?.bots.machines.first(where: { $0.id == machineID })
                .map { harnesses(on: harnessLocation(for: $0)).filter(\.updateAvailable) } ?? []
        case .thisMacApp, .device, .bots: []
        }
    }

    private struct RemoteTarget {
        let harness: FleetHarness
        let kind: AgentRuntimeKind
        let configuration: RemoteWorkspaceConfiguration
    }

    /// Harness updates on Linux workspaces, which download and run an installer there.
    private func remoteHarnessTargets(for request: Request) -> [RemoteTarget] {
        guard let model else { return [] }
        return harnessTargets(for: request).compactMap { harness in
            guard case .workspace(let id) = harness.location, case .runtime(let kind) = harness.kind,
                  let configuration = model.remoteWorkspaces.configuration(id: id) else { return nil }
            return RemoteTarget(harness: harness, kind: kind, configuration: configuration)
        }
    }

    // MARK: Busy work

    /// Chats that an update would interrupt, named so the user can decide.
    func busyWork(for request: Request) -> [BusyItem] {
        guard let model else { return [] }
        let conversations = model.workspaceOverview?.conversations ?? []
        let running = model.localRunningConversationIDs.compactMap { id in conversations.first { $0.id == id } }
        var items: [BusyItem] = []
        func add(_ conversation: WorkspaceConversationRecord, _ text: String) {
            guard !items.contains(where: { $0.conversationID == conversation.id }) else { return }
            items.append(.init(id: conversation.id, text: text, conversationID: conversation.id))
        }
        func title(_ conversation: WorkspaceConversationRecord) -> String { "“\(conversation.title)”" }
        let steps = deviceSteps(for: request)
        if steps.contains(.thisMacApp) || (request == .scope(.everything) || request == .scope(.apps)) && thisMacIsBehind {
            for conversation in running where conversation.remoteWorkspaceID == nil {
                add(conversation, "\(title(conversation)) is running on this Mac, which restarts to update.")
            }
        }
        // Moving bots to a new base image recreates their containers; say what comes along.
        for step in steps {
            guard case .bots(let id, let name) = step,
                  let machine = model.bots.machines.first(where: { $0.id == id }), staleBots(machine) > 0 else { continue }
            let count = staleBots(machine)
            let tools = model.bots.session(for: id)?.runtimeStatus?.image?.tools ?? "the current tools"
            items.append(.init(id: "image:" + id, text: "\(count == 1 ? "1 bot" : "\(count) bots") on \(name) move to a new container image (\(tools)). Their files, home folders, browser sign-ins, and the packages they installed come along; each bot gets a report of anything that didn't."))
        }
        for step in steps {
            guard case .linuxHost(let id, let name) = step,
                  let workspace = devices.first(where: { $0.id == id }).flatMap(workspace(for:)) else { continue }
            for conversation in running where conversation.remoteWorkspaceID == workspace.id {
                add(conversation, "\(title(conversation)) is running on \(name), whose server restarts to update.")
            }
        }
        for harness in harnessTargets(for: request) {
            guard case .runtime(let kind) = harness.kind else { continue }
            switch harness.location {
            case .thisMac:
                for conversation in running where conversation.remoteWorkspaceID == nil && conversation.localRuntimeKind != nil {
                    add(conversation, "\(title(conversation)) is using \(conversation.localRuntimeKind?.displayName ?? "a harness") on this Mac.")
                }
            case .workspace(let id):
                for conversation in running where conversation.remoteWorkspaceID == id && conversation.localRuntimeKind == kind {
                    add(conversation, "\(title(conversation)) is using \(kind.displayName) on \(workspaceName(harness.location)).")
                }
                if kind == .opencode, model.remoteWorkspaces.workspaceInstances[id]?[.opencode]?.state == "running" {
                    items.append(.init(id: "opencode:" + id.uuidString, text: "The OpenCode server on \(workspaceName(harness.location)) is running.",
                                       openCodeServer: id))
                }
            case .member:
                // That machine knows its own chats; it answers busy, and is asked again then.
                break
            }
        }
        return items
    }

    /// Stops the listed chats and servers and waits briefly for them to finish stopping.
    private func stop(_ items: [BusyItem], run: UUID) async {
        guard let model, !items.isEmpty else { return }
        say(run, "Stopping running work…")
        for item in items {
            if let id = item.conversationID { model.cancelLocalACPPrompt(conversationID: id) }
            if let id = item.openCodeServer, let configuration = model.remoteWorkspaces.configuration(id: id) {
                model.remoteWorkspaces.refreshWorkspaceInstance(.opencode, configuration: configuration, action: "stop")
            }
        }
        let ids = Set(items.compactMap(\.conversationID))
        _ = await wait(timeout: .seconds(30)) { model.localRunningConversationIDs.isDisjoint(with: ids) }
        say(run, nil)
    }

    // MARK: Devices

    private func perform(_ step: DeviceUpdatePlan.Step, run: UUID) async {
        guard let model else { return }
        let bots = model.bots
        switch step {
        case let .linuxHost(id, name):
            say(run, "Updating \(name)…")
            if let failure = await updateLinuxHost(machineID: id, name: name, bots: bots, run: run) { failures.append("\(name): \(failure)") }
        case let .mac(_, name):
            say(run, "Updating Woven Matter on \(name)…")
            if let failure = await updateMac(named: name) { failures.append("\(name): \(failure)") }
        case let .engine(machineID, name):
            say(run, "Updating the bots VM on \(name)…")
            if let failure = await updateEngine(machineID: machineID, bots: bots) { failures.append("Bots VM on \(name): \(failure)") }
        case let .bots(machineID, name):
            say(run, "Updating bots on \(name)…")
            if let session = bots.session(for: machineID) {
                await session.updateBots()
                await session.waitForUpdate()
                for failure in session.updateFailures { failures.append("Bots on \(name): \(failure)") }
            }
        case .thisMacApp:
            break
        }
    }

    /// Starts a Mac's VM update and follows that machine until it finishes; nil on success.
    private func updateEngine(machineID: String, bots: BotsModel, timeout: Duration = .seconds(3_600)) async -> String? {
        do { try await bots.send(.updateEngine(machineID: machineID)) }
        catch { return error.localizedDescription }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .seconds(2))
            await bots.refresh()
            guard let machine = bots.machines.first(where: { $0.id == machineID }) else { return "It stopped answering." }
            if !machine.updating { return machine.engineUpdateFailure }
        }
        return "It did not finish in time."
    }

    /// Starts a Linux host's update in the background server and follows its job until it
    /// finishes; nil on success.
    private func updateLinuxHost(machineID: String, name: String, bots: BotsModel, run: UUID,
                                 timeout: Duration = .seconds(3_600)) async -> String? {
        do { try await bots.send(.updateLinuxHost(machineID: machineID)) }
        catch { return error.localizedDescription }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let job = bots.job(.updateLinuxHost, target: machineID) else { return "It stopped answering." }
            guard job.running else { return job.error }
            if let progress = job.progress { say(run, "Updating \(name): \(progress)") }
            try? await Task.sleep(for: .seconds(2))
            await bots.refresh()
        }
        return "It did not finish in time."
    }

    /// Other Macs update over the same Tailscale SSH path as pairing in Apple Devices.
    private func updateMac(named name: String) async -> String? {
        let setup = MacDeviceSetupModel()
        await setup.discover()
        guard let row = setup.rows.first(where: { $0.mac.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return "It wasn't found on your tailnet."
        }
        await setup.perform(.update, row: row, endpoint: nil)
        return row.error
    }

    // MARK: Harnesses

    /// Updates one harness and waits for it; nil on success.
    private func update(_ harness: FleetHarness, preview: RemoteInstallerPreview?, force: Bool, run: UUID) async -> String? {
        guard let model else { return "Woven Matter isn't ready." }
        switch (harness.location, harness.kind) {
        case (.thisMac, .runtime(let kind)):
            // An update can't start while a version check for it runs.
            _ = await wait(timeout: .seconds(60)) { !model.checkingRuntimeKinds.contains(kind) }
            model.updateRuntime(kind)
            guard await wait(timeout: .seconds(10), until: { model.updatingRuntimeKinds.contains(kind) || model.runtimeMaintenanceBusy(kind) })
            else { return "It didn't start. Try again." }
            guard await wait(timeout: .seconds(900), until: {
                !model.updatingRuntimeKinds.contains(kind) && !model.runtimeMaintenanceBusy(kind)
            }) else { return "It did not finish in time." }
            if model.failedRuntimeUpdateKinds.contains(kind) { return model.runtimeFailureDetails[kind] ?? "The update failed." }
            if model.localRuntimeMaintenanceHasActiveConversation { return "A chat is still using it. Try again when it finishes." }
            return model.runtimeInventories[kind]?.updateAvailable == true ? "It is still out of date." : nil
        case (.member(let machineID), .runtime(let kind)):
            return await followMemberJob(machineID: machineID, item: kind.rawValue, run: run,
                                         .updateMemberHarness(machineID: machineID, kind: kind, sourceSHA256: preview?.sha256,
                                                              packageSpec: preview?.packageSpec, force: force))
        case (_, .executor):
            guard let tools = model.agentTools, let config = tools.settings.executor else { return "Executor isn't set up." }
            do { try await tools.controlExecutor(.setup(config)) }
            catch { return error.localizedDescription }
            _ = await wait(timeout: .seconds(10)) { tools.settings.executorSetup?.running == true }
            guard await wait(timeout: .seconds(900), until: { tools.settings.executorSetup?.running != true }) else {
                return "It did not finish in time."
            }
            if let error = tools.settings.executorSetup?.error { return error }
            await refreshExecutor()
            return executor?.updateAvailable == true ? "It is still out of date." : nil
        case (.member(let machineID), .piDurableSDK):
            return await followMemberJob(machineID: machineID, item: "pi-durable-sdk", run: run, .updateMemberSDKs(machineID: machineID))
        case (_, .piDurableSDK):
            let workspaceID: UUID? = if case .workspace(let id) = harness.location { id } else { nil }
            let command = DefaultAgentSDKCommand(workspaceID: workspaceID, request: .init(action: .update))
            let sdks = model.connections.sdks
            // A check still running would swallow the request; let it finish first.
            guard await wait(timeout: .seconds(120), until: { !sdks.state(for: command.key).busy }) else { return "It is still being checked." }
            sdks.request(command, connections: model.connections, remoteWorkspaces: model.remoteWorkspaces)
            guard await wait(timeout: .seconds(900), until: { !sdks.state(for: command.key).busy }) else { return "It did not finish in time." }
            let state = sdks.state(for: command.key)
            if let error = state.error { return error }
            guard state.completedAction == .update else { return "It didn't start. Try again." }
            return state.status?.sdks.contains { $0.updateAvailable } == true ? "It is still out of date." : nil
        case (.workspace(let id), .runtime(let kind)):
            guard let configuration = model.remoteWorkspaces.configuration(id: id) else { return "This workspace is no longer set up here." }
            guard let reviewed = preview else { return "Its download wasn't reviewed." }
            return await updateRemote(RemoteTarget(harness: harness, kind: kind, configuration: configuration), reviewed: reviewed)
        }
    }

    /// Starts a harness update on another machine in the background server and follows
    /// its job; nil on success, `FleetBusyError.message` when chats there are using it.
    private func followMemberJob(machineID: String, item: String, run: UUID, _ command: BotsCommand) async -> String? {
        guard let bots = model?.bots else { return "Woven Matter isn't ready." }
        let target = machineID.lowercased() + "/" + item
        do { _ = try await bots.send(command) }
        catch { return error.localizedDescription }
        let deadline = ContinuousClock.now + .seconds(1_000)
        while ContinuousClock.now < deadline {
            guard let job = bots.job(.updateHarness, target: target) else { return "It stopped answering." }
            guard job.running else { return job.error }
            if let progress = job.progress { say(run, progress + " (\(workspaceName(.member(machineID))))") }
            try? await Task.sleep(for: .seconds(2))
            await bots.refresh()
        }
        return "It did not finish in time."
    }

    /// The download a Linux workspace would run for this update, without starting it.
    private func preview(_ target: RemoteTarget) async -> Result<RemoteInstallerPreview, any Error> {
        await oneRemoteHarnessAtATime { await self.preparePreview(target) }
            ?? .failure(FleetUpdateError("Another workspace's download didn't finish preparing. Try again."))
    }

    private func preparePreview(_ target: RemoteTarget) async -> Result<RemoteInstallerPreview, any Error> {
        let remote = model!.remoteWorkspaces
        guard let harness = remote.currentHarnesses(for: target.configuration).first(where: { $0.id == target.kind }) else {
            return .failure(FleetUpdateError("It isn't connected right now."))
        }
        remote.prepareHarnessAction("update", harness: harness, configuration: target.configuration)
        let matches: @MainActor @Sendable () -> Bool = {
            remote.preparedHarnessAction.map {
                $0.configuration.id == target.configuration.id && $0.harness.id == target.kind && $0.action == "update"
            } == true
        }
        guard await wait(timeout: .seconds(60), until: matches), let prepared = remote.preparedHarnessAction else {
            return .failure(FleetUpdateError(remote.actionErrors[target.configuration.id]?[target.kind] ?? "Its download couldn't be checked."))
        }
        remote.cancelPreparedHarnessAction(workspaceID: target.configuration.id, harnessID: target.kind, action: "update")
        return .success(prepared.preview)
    }

    /// Runs a reviewed update on a Linux workspace. The download is prepared again and
    /// must match what was reviewed.
    private func updateRemote(_ target: RemoteTarget, reviewed: RemoteInstallerPreview) async -> String? {
        await oneRemoteHarnessAtATime { await self.runRemote(target, reviewed: reviewed) }
            ?? "Another workspace's download didn't finish preparing. Try again."
    }

    /// Linux workspaces prepare one harness download at a time, so their harness updates
    /// take turns; everything else keeps going.
    private func oneRemoteHarnessAtATime<T>(_ body: @MainActor () async -> T) async -> T? {
        guard await wait(timeout: .seconds(3_600), until: { [weak self] in self?.remoteHarnessOwner == nil }) else { return nil }
        let owner = UUID()
        remoteHarnessOwner = owner
        defer { if remoteHarnessOwner == owner { remoteHarnessOwner = nil } }
        return await body()
    }

    private func runRemote(_ target: RemoteTarget, reviewed: RemoteInstallerPreview) async -> String? {
        let remote = model!.remoteWorkspaces
        let id = target.configuration.id
        guard let harness = remote.currentHarnesses(for: target.configuration).first(where: { $0.id == target.kind }) else {
            return "It isn't connected right now."
        }
        remote.prepareHarnessAction("update", harness: harness, configuration: target.configuration)
        guard await wait(timeout: .seconds(60), until: {
            remote.preparedHarnessAction.map { $0.configuration.id == id && $0.harness.id == target.kind && $0.action == "update" } == true
        }), let prepared = remote.preparedHarnessAction else {
            return remote.actionErrors[id]?[target.kind] ?? "Its download couldn't be checked."
        }
        guard prepared.preview.source == reviewed.source, prepared.preview.sha256 == reviewed.sha256,
              prepared.preview.packageSpec == reviewed.packageSpec else {
            remote.cancelPreparedHarnessAction(workspaceID: id, harnessID: target.kind, action: "update")
            return "Its download changed after you reviewed it. Update it again to review the new one."
        }
        remote.confirmPreparedHarnessAction(workspaceID: id, harnessID: target.kind, action: "update")
        _ = await wait(timeout: .seconds(15)) { remote.busyWorkspaceIDs.contains(id) }
        guard await wait(timeout: .seconds(1_000), until: {
            !remote.busyWorkspaceIDs.contains(id)
                && remote.runtimeMaintenance[id]?.first(where: { $0.id == target.kind })?.operation?.status != "running"
        }) else { return "It did not finish in time." }
        let runtime = remote.runtimeMaintenance[id]?.first { $0.id == target.kind }
        if runtime?.operation?.status == "failed" { return runtime?.operation?.error ?? "The update failed." }
        if let error = remote.actionErrors[id]?[target.kind] { return error }
        return runtime?.updateAvailable == true ? "It is still out of date." : nil
    }

    // MARK: Helpers

    /// Polls observed state until `done`; false when it ran out of time.
    private func wait(timeout: Duration, until done: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return true
    }
}

struct FleetUpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
