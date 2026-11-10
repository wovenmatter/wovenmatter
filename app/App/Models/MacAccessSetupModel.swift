import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import WovenMatterCore

/// One-time permission setup (Settings → Permissions & Access). Sessions are
/// often started from another device while nobody is at this Mac, so every
/// permission a session may need is granted here once, ahead of time.
///
/// macOS attributes privacy permissions to the responsible app. The frontend,
/// the launchd background server (`WovenMatter --backend`) and the harness
/// processes they spawn all share this app's bundle identity, so one grant
/// covers them; see docs/MAC_ACCESS.md.
@MainActor @Observable
final class MacAccessSetupModel {
    typealias Item = CompanionMacAccessStatus.Item
    typealias State = CompanionMacAccessStatus.State

    /// What the page shows for one permission. Local presentation only: the
    /// published `CompanionMacAccessStatus` keeps its three wire states.
    enum Access: Equatable, Sendable {
        case allowed
        case notAllowed
        /// Known to be switched off in System Settings (Microphone, Automation).
        case turnedOff
        /// Requested this launch and still not visible to the running app.
        case needsReopen
    }

    /// Prompt-free observations: wire states plus what macOS says is denied.
    struct Probe: Equatable {
        var states: [Item: State]
        var turnedOff: Set<Item> = []
    }

    enum AutomationResult: Equatable, Sendable { case allowed, notAsked, denied }

    /// "Set up all": the permissions still to allow, worked through in order.
    struct SetupRun: Equatable {
        var steps: [Item]
        var index = 0
        var current: Item { steps[index] }
    }

    static let shared = MacAccessSetupModel(observesActivation: true)
    static let storageKey = "wovenmatter.mac-access.v1"
    /// Posted to open Settings → Permissions & Access from anywhere in the app.
    nonisolated static let openSettingsNotification = Notification.Name("wovenmatter.open-permissions-settings")
    nonisolated static func openSettings() { NotificationCenter.default.post(name: openSettingsNotification, object: nil) }
    /// In-app prompts first; the ones macOS may make you reopen the app for last.
    static let setupOrder: [Item] = [.keychain, .fullDiskAccess, .automation, .microphone, .accessibility, .screenRecording]
    /// macOS often applies these to a running app only after it is reopened.
    static let reopenSensitive: Set<Item> = [.accessibility, .screenRecording]
    /// Apps agents most often control. Others prompt the first time an agent uses them.
    static let automationTargets: [(bundleID: String, path: String?)] = [
        ("com.apple.systemevents", "/System/Library/CoreServices/System Events.app"),
        ("com.apple.finder", nil),
    ]

    private(set) var states: [Item: State] = [:]
    private(set) var turnedOff: Set<Item> = []
    private(set) var settingUp: Item?
    private(set) var run: SetupRun?
    /// The permission last asked for from its own row, so only that row shows its hint.
    private(set) var requested: Item?
    /// Starts the Keychain flow, which belongs to the application model and its consent sheet.
    @ObservationIgnored var keychainRequest: (@MainActor () -> Void)?

    private var requestedThisLaunch: Set<Item> = []
    private var returnedAfterRequest: Set<Item> = []
    private var skipsCurrentStep = false
    private var runTask: Task<Void, Never>?
    private var automationTask: Task<Void, Never>?
    private var automationCheckedAt = Date.distantPast
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    private let defaults: UserDefaults
    private let probe: @MainActor (UserDefaults) -> Probe
    private let automationProbe: @MainActor (_ ask: Bool) async -> AutomationResult?
    private let requestOverride: (@MainActor (Item) async -> Void)?
    private let pollInterval: Duration

    init(defaults: UserDefaults = .standard,
         probe: @escaping @MainActor (UserDefaults) -> Probe = MacAccessSetupModel.liveProbe,
         automationProbe: @escaping @MainActor (_ ask: Bool) async -> AutomationResult? = { await MacAccessSetupModel.automation(ask: $0) },
         request: (@MainActor (Item) async -> Void)? = nil,
         pollInterval: Duration = .seconds(1),
         observesActivation: Bool = false) {
        self.defaults = defaults
        self.probe = probe
        self.automationProbe = automationProbe
        self.requestOverride = request
        self.pollInterval = pollInterval
        let initial = probe(defaults)
        states = initial.states
        turnedOff = initial.turnedOff
        if observesActivation {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidBecomeActive() }
            }
        }
    }

    /// Cheap, prompt-free checks plus saved results for checks that need an
    /// explicit action (Keychain, Automation). Safe in the background server.
    static func current(keychainReady: Bool?, defaults: UserDefaults = .standard) -> CompanionMacAccessStatus {
        var items = saved(defaults: defaults).itemStates
        if let keychainReady { items[.keychain] = keychainReady ? .ready : .needsAttention }
        items[.fullDiskAccess] = fullDiskAccess()
        items[.accessibility] = AXIsProcessTrusted() ? .ready : .needsAttention
        items[.screenRecording] = CGPreflightScreenCaptureAccess() ? .ready : .needsAttention
        items[.microphone] = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .ready
        case .denied, .restricted: .needsAttention
        default: .unknown
        }
        return CompanionMacAccessStatus(items: items, appName: appName)
    }

    static func liveProbe(defaults: UserDefaults) -> Probe {
        let denied = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
        return Probe(states: current(keychainReady: nil, defaults: defaults).itemStates,
                     turnedOff: denied ? [.microphone] : [])
    }

    static var appName: String {
        CompanionMacAccessStatus.appName(
            displayName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundleName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
    }

    /// Full Disk Access has no query API. Reading a file only it unlocks is the
    /// supported signal; a missing file is inconclusive rather than a denial.
    nonisolated static func fullDiskAccess(probes: [URL] = fullDiskAccessProbes) -> State {
        var denied = false
        for url in probes {
            let descriptor = open(url.path, O_RDONLY)
            if descriptor >= 0 { close(descriptor); return .ready }
            if errno == EPERM || errno == EACCES { denied = true }
        }
        return denied ? .needsAttention : .unknown
    }

    nonisolated static var fullDiskAccessProbes: [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        return [library.appending(path: "Application Support/com.apple.TCC/TCC.db"),
                library.appending(path: "Safari/Bookmarks.plist"),
                URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")]
    }

    // MARK: - What the page shows

    nonisolated static func access(state: State, turnedOff: Bool, awaitingReopen: Bool) -> Access {
        if state == .ready { return .allowed }
        if awaitingReopen { return .needsReopen }
        return turnedOff ? .turnedOff : .notAllowed
    }

    func access(_ item: Item) -> Access {
        Self.access(state: states[item] ?? .unknown, turnedOff: turnedOff.contains(item),
                    awaitingReopen: returnedAfterRequest.contains(item))
    }

    /// Permissions not yet allowed, in setup order.
    var remaining: [Item] { Self.setupOrder.filter { access($0) != .allowed } }
    /// Remaining permissions that only reopening the app can finish.
    var awaitingReopen: [Item] { remaining.filter { access($0) == .needsReopen } }

    /// "All allowed", "2 to allow": the Settings landing summary.
    var summary: String {
        let count = remaining.count
        return count == 0 ? "All allowed" : "\(count) to allow"
    }

    // MARK: - Refreshing

    func refresh(keychainReady: Bool?) {
        let observed = probe(defaults)
        var changes = observed.states
        if let keychainReady { changes[.keychain] = keychainReady ? .ready : .needsAttention }
        update(changes)
        // The probe judges every denial except Automation's, which comes from its own check.
        setTurnedOff(turnedOff.intersection([.automation]).union(observed.turnedOff))
        guard automationTask == nil, Date().timeIntervalSince(automationCheckedAt) > 30 else { return }
        automationCheckedAt = Date()
        automationTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.automationProbe(false)
            self.automationTask = nil
            if let result { self.record(automation: result) }
        }
    }

    func recordKeychain(ready: Bool?) {
        guard let ready else { return }
        update([.keychain: ready ? .ready : .needsAttention])
    }

    /// The user came back to the app, typically from System Settings. A
    /// permission asked for this launch that still reads as off may only need
    /// the app to be reopened.
    func appDidBecomeActive() {
        let pending = requestedThisLaunch.intersection(Self.reopenSensitive).filter { states[$0] != .ready }
        if !pending.isSubset(of: returnedAfterRequest) { returnedAfterRequest.formUnion(pending) }
    }

    // MARK: - Asking

    /// Grants an item that macOS lets the app request, or opens the System
    /// Settings pane for one it can only detect.
    func setUp(_ item: Item) async {
        requested = item
        if item == .keychain { keychainRequest?(); return }
        guard settingUp == nil else { return }
        settingUp = item
        requestedThisLaunch.insert(item)
        defer { settingUp = nil }
        if let requestOverride { await requestOverride(item) } else { await liveRequest(item) }
        refresh(keychainReady: nil)
    }

    private func liveRequest(_ item: Item) async {
        switch item {
        case .fullDiskAccess:
            openPrivacyPane("Privacy_AllFiles")
        case .accessibility:
            if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
                openPrivacyPane("Privacy_Accessibility")
            }
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
                openPrivacyPane("Privacy_ScreenCapture")
            }
        case .automation:
            let result = await automationProbe(true)
            if let result { record(automation: result) }
            if result != .allowed { openPrivacyPane("Privacy_Automation") }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .authorized: break
            default: openPrivacyPane("Privacy_Microphone")
            }
        case .keychain:
            break
        }
    }

    // MARK: - Set up all

    /// Works through every permission not yet allowed, in `setupOrder`: asks
    /// for each one, then waits until macOS reports it allowed before moving on.
    func startSetUpAll() {
        guard run == nil else { return }
        let steps = remaining.filter { access($0) != .needsReopen }
        guard !steps.isEmpty else { return }
        run = SetupRun(steps: steps)
        runTask = Task { [weak self] in await self?.performRun() }
    }

    func skipStep() { skipsCurrentStep = true }

    func stopSetUpAll() {
        runTask?.cancel()
        runTask = nil
        run = nil
    }

    /// Asks again for the current step, e.g. after a cancelled Keychain prompt.
    func retryStep() async {
        guard let item = run?.current else { return }
        await setUp(item)
    }

    private func performRun() async {
        while let current = run, !Task.isCancelled {
            let item = current.current
            skipsCurrentStep = false
            if access(item) != .allowed {
                await setUp(item)
                while !Task.isCancelled, !skipsCurrentStep, access(item) != .allowed {
                    do { try await Task.sleep(for: pollInterval) } catch { break }
                    refresh(keychainReady: nil)
                }
            }
            guard !Task.isCancelled, var next = run, next.index == current.index else { return }
            guard next.index + 1 < next.steps.count else { break }
            next.index += 1
            run = next
        }
        if !Task.isCancelled { run = nil; runTask = nil }
    }

    // MARK: - Reopening

    /// Quits and reopens this app so macOS applies Accessibility and Screen
    /// Recording changes. The relaunch waits for this process to exit.
    func reopenApp() {
        do { try WovenMatterBackendProcess.relaunchAfterCurrentProcessExits() } catch { return }
        WovenMatterLifecycleDelegate.requestTerminationAfterUpdate()
    }

    // MARK: - Storage

    private func record(automation result: AutomationResult) {
        update([.automation: result == .allowed ? .ready : .needsAttention])
        setTurnedOff(result == .denied ? turnedOff.union([.automation]) : turnedOff.subtracting([.automation]))
    }

    private func setTurnedOff(_ value: Set<Item>) {
        let next = value.filter { states[$0] != .ready }
        if next != turnedOff { turnedOff = next }
    }

    private func update(_ changes: [Item: State]) {
        var next = states
        for (item, state) in changes where state != .unknown || next[item] == nil { next[item] = state }
        let granted = Set(next.filter { $0.value == .ready }.keys)
        if !returnedAfterRequest.isDisjoint(with: granted) { returnedAfterRequest.subtract(granted) }
        if let requested, granted.contains(requested) { self.requested = nil }
        guard next != states else { return }
        states = next
        let status = CompanionMacAccessStatus(items: next, appName: Self.appName)
        if let data = try? JSONEncoder().encode(status) { defaults.set(data, forKey: Self.storageKey) }
    }

    private static func saved(defaults: UserDefaults) -> CompanionMacAccessStatus {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(CompanionMacAccessStatus.self, from: $0) }
            ?? CompanionMacAccessStatus(appName: appName)
    }

    /// Apple Events consent per target app. Asking requires the target running;
    /// System Events is launched hidden, without activating it.
    static func automation(ask: Bool) async -> AutomationResult? {
        var results: [AutomationResult] = []
        for target in automationTargets {
            if ask, let path = target.path,
               NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).isEmpty {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false; configuration.hides = true; configuration.addsToRecentItems = false
                _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
            }
            let bundleID = target.bundleID
            let status = await Task.detached(priority: .utility) { () -> OSStatus in
                let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                return AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
            }.value
            switch Int(status) {
            case Int(noErr): results.append(.allowed)
            case -1743: results.append(.denied) // errAEEventNotPermitted
            case -1744: results.append(.notAsked) // errAEEventWouldRequireUserConsent
            default: break // procNotFound: target not running, inconclusive
            }
        }
        if results.contains(.denied) { return .denied }
        if results.contains(.notAsked) { return .notAsked }
        return results.isEmpty ? nil : .allowed
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            NSWorkspace.shared.open(url)
        }
    }
}

extension CompanionMacAccessStatus {
    var itemStates: [Item: State] {
        Dictionary(uniqueKeysWithValues: items.compactMap { key, value in Item(rawValue: key).map { ($0, value) } })
    }
}

struct MacAccessSessionNotice: Equatable {
    let message: String
    /// The session runs on this Mac, so Settings → Permissions & Access here can fix it.
    let isThisMac: Bool
}

extension ApplicationModel {
    /// A clear message for a session that runs on a Mac missing a permission it
    /// needs, shown wherever the session is viewed. Linux sessions use their
    /// host's access mode and have no Mac permissions.
    func macAccessNotice(for conversation: WorkspaceConversationRecord) async -> MacAccessSessionNotice? {
        guard conversation.remoteWorkspaceID == nil, !conversation.isArchived else { return nil }
        let computerUse = agentTools?.sessionPolicies[conversation.id]?.enabled.contains(.computer) == true
        if let database = dashboardStore?.database,
           let workspace = try? await database.companionConversationExecutionWorkspace(conversationID: conversation.id),
           workspace.kind == .mac,
           let identity = try? await database.companionLibraryIdentity(),
           workspace.executionDeviceID != identity.hostDeviceID {
            return workspace.macAccess?.sessionNotice(deviceName: workspace.name, isThisDevice: false, computerUse: computerUse)
                .map { MacAccessSessionNotice(message: $0, isThisMac: false) }
        }
        return MacAccessSetupModel.current(keychainReady: keychainAccessReady)
            .sessionNotice(deviceName: "This Mac", isThisDevice: true, computerUse: computerUse)
            .map { MacAccessSessionNotice(message: $0, isThisMac: true) }
    }
}
