import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import WovenMatterCore

/// One-time Mac access setup (Settings → General → Mac access). Sessions are
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

    static let shared = MacAccessSetupModel()
    static let storageKey = "wovenmatter.mac-access.v1"
    /// Apps agents most often control. Others prompt the first time an agent uses them.
    static let automationTargets: [(bundleID: String, path: String?)] = [
        ("com.apple.systemevents", "/System/Library/CoreServices/System Events.app"),
        ("com.apple.finder", nil),
    ]

    private(set) var states: [Item: State] = [:]
    private(set) var settingUp: Item?
    private var automationTask: Task<Void, Never>?
    private var automationCheckedAt = Date.distantPast

    init() { states = Self.current(keychainReady: nil).itemStates }

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

    func refresh(keychainReady: Bool?) {
        update(Self.current(keychainReady: keychainReady).itemStates)
        guard automationTask == nil, Date().timeIntervalSince(automationCheckedAt) > 30 else { return }
        automationCheckedAt = Date()
        automationTask = Task { [weak self] in
            let state = await Self.automation(ask: false)
            self?.automationTask = nil
            if let state, state != self?.states[.automation] { self?.update([.automation: state]) }
        }
    }

    /// Grants an item that macOS lets the app request, or opens the System
    /// Settings pane for one it can only detect. Keychain uses its own flow.
    func setUp(_ item: Item) async {
        guard settingUp == nil, item != .keychain else { return }
        settingUp = item
        defer { settingUp = nil }
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
            let state = await Self.automation(ask: true)
            if let state { update([.automation: state]) }
            if state != .ready { openPrivacyPane("Privacy_Automation") }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .authorized: break
            default: openPrivacyPane("Privacy_Microphone")
            }
        case .keychain:
            break
        }
        refresh(keychainReady: nil)
    }

    func recordKeychain(ready: Bool?) {
        guard let ready else { return }
        update([.keychain: ready ? .ready : .needsAttention])
    }

    private func update(_ changes: [Item: State]) {
        var next = states
        for (item, state) in changes where state != .unknown || next[item] == nil { next[item] = state }
        guard next != states else { return }
        states = next
        let status = CompanionMacAccessStatus(items: next, appName: Self.appName)
        if let data = try? JSONEncoder().encode(status) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    private static func saved(defaults: UserDefaults) -> CompanionMacAccessStatus {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(CompanionMacAccessStatus.self, from: $0) }
            ?? CompanionMacAccessStatus(appName: appName)
    }

    /// Apple Events consent per target app. Asking requires the target running;
    /// System Events is launched hidden, without activating it.
    private static func automation(ask: Bool) async -> State? {
        var results: [State] = []
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
            case Int(noErr): results.append(.ready)
            case -1743, -1744: results.append(.needsAttention) // errAEEventNotPermitted, errAEEventWouldRequireUserConsent
            default: break // procNotFound: target not running, inconclusive
            }
        }
        if results.contains(.needsAttention) { return .needsAttention }
        return results.isEmpty ? nil : .ready
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
    /// The session runs on this Mac, so Settings → General here can fix it.
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
