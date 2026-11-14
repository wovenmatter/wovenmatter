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
/// on them, and the buttons that update one, some or all of it. Updates run one at a
/// time in a fixed order (`DeviceUpdatePlan`, then harnesses). When this Mac is behind
/// the newest release it updates first and the run continues after it restarts.
@MainActor @Observable
final class FleetUpdatesModel {
    static let shared = FleetUpdatesModel()

    /// What a button asked for.
    enum Request: Equatable, Sendable {
        case scope(FleetUpdateScope)
        case thisMacApp
        /// Woven Matter on another device, with its bots.
        case device(machineID: String)
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
        let request: Request
        let force: Bool
        let items: [Item]
        /// Linux harnesses whose download couldn't be checked, already reported.
        let skipped: Set<String>
    }

    private(set) var release: MacRelease?
    private(set) var releaseError: String?
    private(set) var checking = false
    private(set) var checkedAt: Date?
    private(set) var running = false
    /// The step running now.
    private(set) var current: String?
    /// The harness or device updating now, for its row's progress.
    private(set) var currentItem: String?
    private(set) var failures: [String] = []
    /// What happens next when the run is waiting on something outside it.
    private(set) var notice: String?
    var busyConfirmation: BusyConfirmation?
    var review: DownloadReview?
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

    private static let resumeKey = "wovenmatter.updates.resume"
    private struct Resume: Codable { let scope: FleetUpdateScope; let force: Bool; let fromVersion: String }

    // MARK: Lifecycle

    /// Called once at launch: continues a run that updated this Mac first.
    func attach(_ model: ApplicationModel) {
        guard self.model == nil else { return }
        self.model = model
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.resumeKey),
              let resume = try? JSONDecoder().decode(Resume.self, from: data) else { return }
        defaults.removeObject(forKey: Self.resumeKey)
        guard resume.fromVersion != thisMacVersion else {
            notice = "This Mac's update didn't finish, so the rest wasn't updated. Choose Update everything to try again."
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
            if resume.force { await self.proceed(.scope(resume.scope), force: true) }
            else { self.start(.scope(resume.scope)) }
        }
    }

    // MARK: What is installed

    var thisMacVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The release every device is brought to: the newest published one, or this Mac's
    /// when the newest can't be checked.
    var targetVersion: String? { release?.version ?? thisMacVersion }

    var thisMacIsBehind: Bool {
        DeviceUpdatePlan.thisMacIsBehind(thisMacVersion: thisMacVersion, latestVersion: release?.version)
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

    /// Bots on a machine whose runtime is older than the newest one on any machine, or
    /// with bots still on an older container image.
    func botsAreOutdated(_ machine: BotMachine) -> Bool {
        guard let model else { return false }
        return model.bots.versionReport.outdated.contains { $0.id == "bots:" + machine.id } || staleBots(machine) > 0
    }

    /// Bots whose containers came from an older bot image.
    func staleBots(_ machine: BotMachine) -> Int {
        model?.bots.session(for: machine.id)?.runtimeStatus?.image?.staleBots ?? 0
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

    /// How many things have an update, for the summary rows.
    var availableCount: Int {
        (thisMacIsBehind ? 1 : 0)
            + devices.filter { deviceIsOutdated($0) || botsAreOutdated($0) }.count
            + allHarnesses.filter(\.updateAvailable).count
    }

    var summary: String {
        if running { return "Updating…" }
        if busyConfirmation != nil || review != nil { return "Waiting for you" }
        if checking && checkedAt == nil { return "Checking…" }
        switch availableCount {
        case 0: return checkedAt == nil ? "Not checked yet" : "Up to date"
        case 1: return "1 update available"
        case let count: return "\(count) updates available"
        }
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
    func refreshMembers(checkLatest: Bool, onlyMissing: Bool = false) async {
        guard let model else { return }
        let machines = devices.filter(isMember).map { $0.id.lowercased() }
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
        guard !running, review == nil, model != nil else { return }
        failures = []
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

    func confirmReview() {
        guard let review else { return }
        self.review = nil
        let previews = Dictionary(uniqueKeysWithValues: review.items.map { ($0.id, $0.preview) })
        Task { await run(review.request, force: review.force, previews: previews, skipped: review.skipped) }
    }

    func cancelReview() { review = nil }

    /// Stops busy work when forced, then either updates this Mac first or reviews the
    /// downloads and runs the rest.
    private func proceed(_ request: Request, force: Bool, stopping: [BusyItem] = []) async {
        guard !running else { return }
        running = true
        if force { await stop(stopping.isEmpty ? busyWork(for: request) : stopping) }
        if case .scope(let scope) = request, scope.includesApps, thisMacIsBehind, let version = thisMacVersion {
            // Linux hosts can only receive this Mac's release, so this Mac goes first.
            if let data = try? JSONEncoder().encode(Resume(scope: scope, force: force, fromVersion: version)) {
                UserDefaults.standard.set(data, forKey: Self.resumeKey)
            }
            DesktopUpdater.shared.checkForUpdates()
            notice = "Install the update in the window that opened. After Woven Matter restarts, it continues with your other devices and harnesses."
            running = false
            return
        }
        current = "Checking downloads…"
        var items: [DownloadReview.Item] = []
        var skipped: Set<String> = []
        for target in remoteHarnessTargets(for: request) {
            currentItem = target.harness.id
            switch await preview(target) {
            case .success(let preview):
                items.append(.init(id: target.harness.id, title: "\(target.harness.name) on \(target.configuration.name)", preview: preview))
            case .failure(let error):
                skipped.insert(target.harness.id)
                failures.append("\(target.harness.name) on \(target.configuration.name): \(error.localizedDescription)")
            }
        }
        // Other machines: a Linux host names its download; a Mac updates from its registries.
        for harness in harnessTargets(for: request) {
            guard case .member(let machineID) = harness.location, case .runtime(let kind) = harness.kind else { continue }
            currentItem = harness.id
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
        currentItem = nil
        current = nil
        running = false
        if items.isEmpty { await run(request, force: force, previews: [:], skipped: skipped) }
        else { review = .init(request: request, force: force, items: items, skipped: skipped) }
    }

    private func run(_ request: Request, force: Bool, previews: [String: RemoteInstallerPreview], skipped: Set<String>) async {
        guard let model, !running else { return }
        running = true
        defer { running = false; current = nil; currentItem = nil }
        await model.bots.refresh()
        var restartsThisMac = false
        for step in deviceSteps(for: request) {
            if step == .thisMacApp { restartsThisMac = true; continue }
            await perform(step)
        }
        var busyElsewhere: [FleetHarness] = []
        for harness in harnessTargets(for: request) {
            // A download that couldn't be checked was reported before the review.
            if skipped.contains(harness.id) { continue }
            currentItem = harness.id
            current = "Updating \(harness.name) on \(workspaceName(harness.location))…"
            switch await update(harness, preview: previews[harness.id], force: force) {
            case nil: break
            case FleetBusyError.message? where !force: busyElsewhere.append(harness)
            case let failure?: failures.append("\(harness.name) on \(workspaceName(harness.location)): \(failure)")
            }
        }
        // Chats on another machine can't be seen from here before it answers; offer to stop them now.
        if !busyElsewhere.isEmpty {
            busyConfirmation = .init(request: .harnesses(ids: busyElsewhere.map(\.id)), items: busyElsewhere.map {
                BusyItem(id: $0.id, text: "\($0.name) on \(workspaceName($0.location)) is in use by chats running there.")
            })
        }
        await refreshMembers(checkLatest: false)
        await refreshBotImages()
        currentItem = nil
        resumedAfterUpdate = false
        await model.bots.refresh()
        // This Mac's app restarts, so it always goes last.
        if restartsThisMac {
            current = "Checking for an update to this Mac…"
            DesktopUpdater.shared.checkForUpdates()
        }
    }

    // MARK: Which steps

    private func deviceSteps(for request: Request) -> [DeviceUpdatePlan.Step] {
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
                    updated.contains(id) || (id == thisMac && resumedAfterUpdate)
                        || model.bots.machines.first(where: { $0.id == id }).map(botsAreOutdated) == true
                default: true
                }
            }
        case .thisMacApp:
            return [.thisMacApp]
        case .device(let machineID):
            var steps = plan.filter { step in
                switch step {
                case .linuxHost(let id, _), .mac(let id, _), .engine(let id, _), .bots(let id, _): id == machineID
                case .thisMacApp: false
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
        // Moving bots to a new image replaces their containers; say so first.
        for step in steps {
            guard case .bots(let id, let name) = step,
                  let machine = model.bots.machines.first(where: { $0.id == id }), staleBots(machine) > 0 else { continue }
            let count = staleBots(machine)
            let tools = model.bots.session(for: id)?.runtimeStatus?.image?.tools ?? "the current tools"
            items.append(.init(id: "image:" + id, text: "\(count == 1 ? "1 bot" : "\(count) bots") on \(name) move to a new container image (\(tools)). Their files in /workspace stay; anything installed elsewhere in the container is replaced."))
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
    private func stop(_ items: [BusyItem]) async {
        guard let model, !items.isEmpty else { return }
        current = "Stopping running work…"
        for item in items {
            if let id = item.conversationID { model.cancelLocalACPPrompt(conversationID: id) }
            if let id = item.openCodeServer, let configuration = model.remoteWorkspaces.configuration(id: id) {
                model.remoteWorkspaces.refreshWorkspaceInstance(.opencode, configuration: configuration, action: "stop")
            }
        }
        let ids = Set(items.compactMap(\.conversationID))
        _ = await wait(timeout: .seconds(30)) { model.localRunningConversationIDs.isDisjoint(with: ids) }
        current = nil
    }

    // MARK: Devices

    private func perform(_ step: DeviceUpdatePlan.Step) async {
        guard let model else { return }
        let bots = model.bots
        switch step {
        case let .linuxHost(id, name):
            currentItem = id
            current = "Updating \(name)…"
            if let failure = await updateLinuxHost(machineID: id, name: name, bots: bots) { failures.append("\(name): \(failure)") }
        case let .mac(id, name):
            currentItem = id
            current = "Updating Woven Matter on \(name)…"
            if let failure = await updateMac(named: name) { failures.append("\(name): \(failure)") }
        case let .engine(machineID, name):
            currentItem = machineID
            current = "Updating the bots VM on \(name)…"
            if let failure = await updateEngine(machineID: machineID, bots: bots) { failures.append("Bots VM on \(name): \(failure)") }
        case let .bots(machineID, name):
            currentItem = machineID
            current = "Updating bots on \(name)…"
            if let session = bots.session(for: machineID) {
                await session.updateBots()
                await session.waitForUpdate()
                if let error = session.progress?.error { failures.append("Bots on \(name): \(error)") }
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
    private func updateLinuxHost(machineID: String, name: String, bots: BotsModel, timeout: Duration = .seconds(3_600)) async -> String? {
        do { try await bots.send(.updateLinuxHost(machineID: machineID)) }
        catch { return error.localizedDescription }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let job = bots.job(.updateLinuxHost, target: machineID) else { return "It stopped answering." }
            guard job.running else { return job.error }
            if let progress = job.progress { current = "Updating \(name): \(progress)" }
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
    private func update(_ harness: FleetHarness, preview: RemoteInstallerPreview?, force: Bool) async -> String? {
        guard let model else { return "Woven Matter isn't ready." }
        switch (harness.location, harness.kind) {
        case (.thisMac, .runtime(let kind)):
            model.updateRuntime(kind)
            _ = await wait(timeout: .seconds(10)) { model.updatingRuntimeKinds.contains(kind) }
            guard await wait(timeout: .seconds(900), until: {
                !model.updatingRuntimeKinds.contains(kind) && !model.runtimeMaintenanceBusy(kind)
            }) else { return "It did not finish in time." }
            if model.failedRuntimeUpdateKinds.contains(kind) { return model.runtimeFailureDetails[kind] ?? "The update failed." }
            if model.localRuntimeMaintenanceHasActiveConversation { return "A chat is still using it. Try again when it finishes." }
            return model.runtimeInventories[kind]?.updateAvailable == true ? "It is still out of date." : nil
        case (.member(let machineID), .runtime(let kind)):
            return await followMemberJob(machineID: machineID, item: kind.rawValue,
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
            return await followMemberJob(machineID: machineID, item: "pi-durable-sdk", .updateMemberSDKs(machineID: machineID))
        case (_, .piDurableSDK):
            let workspaceID: UUID? = if case .workspace(let id) = harness.location { id } else { nil }
            let command = DefaultAgentSDKCommand(workspaceID: workspaceID, request: .init(action: .update))
            let sdks = model.connections.sdks
            sdks.request(command, connections: model.connections, remoteWorkspaces: model.remoteWorkspaces)
            guard await wait(timeout: .seconds(900), until: { !sdks.state(for: command.key).busy }) else { return "It did not finish in time." }
            return sdks.state(for: command.key).error
        case (.workspace(let id), .runtime(let kind)):
            guard let configuration = model.remoteWorkspaces.configuration(id: id) else { return "This workspace is no longer set up here." }
            guard let reviewed = preview else { return "Its download wasn't reviewed." }
            return await updateRemote(RemoteTarget(harness: harness, kind: kind, configuration: configuration), reviewed: reviewed)
        }
    }

    /// Starts a harness update on another machine in the background server and follows
    /// its job; nil on success, `FleetBusyError.message` when chats there are using it.
    private func followMemberJob(machineID: String, item: String, _ command: BotsCommand) async -> String? {
        guard let bots = model?.bots else { return "Woven Matter isn't ready." }
        let target = machineID.lowercased() + "/" + item
        do { _ = try await bots.send(command) }
        catch { return error.localizedDescription }
        let deadline = ContinuousClock.now + .seconds(1_000)
        while ContinuousClock.now < deadline {
            guard let job = bots.job(.updateHarness, target: target) else { return "It stopped answering." }
            guard job.running else { return job.error }
            if let progress = job.progress { current = progress + " (\(workspaceName(.member(machineID))))" }
            try? await Task.sleep(for: .seconds(2))
            await bots.refresh()
        }
        return "It did not finish in time."
    }

    /// The download a Linux workspace would run for this update, without starting it.
    private func preview(_ target: RemoteTarget) async -> Result<RemoteInstallerPreview, any Error> {
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

/// Software that ships inside Woven Matter and updates only with it, read from the app's
/// own resources so the page shows what this copy actually carries.
enum BundledComponents {
    struct Component: Identifiable, Equatable {
        let name: String
        let version: String
        var id: String { name }
    }

    static func onThisMac(bundle: Bundle = .main) -> [Component] {
        let resources = bundle.resourceURL, frameworks = bundle.privateFrameworksURL
        var result: [Component] = []
        func add(_ name: String, _ version: String?) { if let version, !version.isEmpty { result.append(.init(name: name, version: version)) } }
        add("Chromium browser", frameworks.flatMap { plistVersion($0.appending(path: "Chromium Embedded Framework.framework/Resources/Info.plist")) }
            .map { "CEF " + trimmed($0) })
        add("Playwright", resources.flatMap { json($0.appending(path: "default-agent/node_modules/playwright-core/package.json"))?["version"] as? String })
        add("Node", resources.flatMap { text($0.appending(path: "default-agent/.node-version")) })
        add("Cua Driver (computer use)", resources.flatMap { json($0.appending(path: "Cua/cua-version.json"))?["version"] as? String })
        if let guest = resources.flatMap({ json($0.appending(path: "WovenVM/guest-version.json")) }) {
            let image = (guest["image"] as? [String: Any])?["serial"] as? String
            let docker = ((guest["docker"] as? [String: Any])?["dockerCE"] as? String).map(debianVersion)
            add("Bots VM", [image.map { "Ubuntu 26.04 (\($0))" }, docker.map { "Docker \($0)" }].compactMap { $0 }.joined(separator: " · "))
        }
        add("Sparkle updater", frameworks.flatMap { plistVersion($0.appending(path: "Sparkle.framework/Resources/Info.plist")) })
        return result
    }

    /// What a Linux server gets from this Mac's release.
    static func linuxServer(bundle: Bundle = .main) -> String? {
        guard let record = bundle.resourceURL.flatMap({ json($0.appending(path: "remote/host/runtime-versions.json")) }) else { return nil }
        let parts = [(record["nodeVersion"] as? String).map { "Node \($0)" },
                     (record["playwrightVersion"] as? String).map { "Playwright \($0) with Chromium" },
                     (record["dockerVersion"] as? String).map { "Docker Engine \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func debianVersion(_ value: String) -> String {
        let withoutEpoch = value.split(separator: ":", maxSplits: 1).last.map(String.init) ?? value
        return withoutEpoch.split(separator: "-").first.map(String.init) ?? withoutEpoch
    }

    /// Drops trailing ".0" parts past the third, as in CEF's bundle version.
    static func trimmed(_ version: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        while parts.count > 3, parts.last == "0" { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    private static func plistVersion(_ url: URL) -> String? {
        (NSDictionary(contentsOf: url)?["CFBundleShortVersionString"] as? String)
    }
    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    private static func text(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
