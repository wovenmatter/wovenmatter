import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// Settings → Permissions & Access: every macOS permission Woven Matter uses,
/// grouped by what it lets Woven Matter do, with one "Set up all" flow.
struct SettingsPermissionsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void

    @State private var macAccess = MacAccessSetupModel.shared
    @State private var showsCredentialDisclosure = false

    static let lead = "Agents running on this Mac or your other devices stop and wait for a prompt here unless Woven Matter has these permissions."

    var body: some View {
        SettingsPage(
            title: "Permissions & Access",
            detail: Self.lead,
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            PermissionsSetupCard(macAccess: macAccess, keychainChecking: model.isReconnectingSavedCredentials)
            ForEach(MacPermissionGroup.allCases) { group in
                SettingsCard(title: group.title, detail: group.detail) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(group.items.enumerated()), id: \.element) { index, item in
                            if index > 0 { Divider() }
                            row(item)
                        }
                    }
                }
            }
        }
        .onAppear {
            macAccess.keychainRequest = { [model] in
                if model.hasAcknowledgedCredentialAccessDisclosure {
                    Task { await model.reconnectSavedCredentials() }
                } else {
                    showsCredentialDisclosure = true
                }
            }
        }
        .task { await model.checkSavedCredentialAccess() }
        .task {
            while !Task.isCancelled {
                macAccess.refresh(keychainReady: model.keychainAccessReady)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: model.keychainAccessReady) { _, ready in macAccess.recordKeychain(ready: ready) }
        .onReceive(NotificationCenter.default.publisher(for: KeychainAccess.accessNeedsAttention).receive(on: DispatchQueue.main)) { _ in
            model.keychainAccessNeedsAttention()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.isReconnectingSavedCredentials { Task { await model.checkSavedCredentialAccess() } }
        }
        .sheet(isPresented: $showsCredentialDisclosure) {
            CredentialAccessDisclosureView(
                purpose: "Use saved credentials across the Woven Matter features you enable, including website sessions and passwords.",
                onEnable: {
                    showsCredentialDisclosure = false
                    Task { await model.reconnectSavedCredentials() }
                },
                onCancel: {
                    showsCredentialDisclosure = false
                    if macAccess.run?.current == .keychain { macAccess.skipStep() }
                }
            )
        }
    }

    private func isChecking(_ item: MacAccessSetupModel.Item) -> Bool {
        item == .keychain && model.isReconnectingSavedCredentials
    }

    /// Hints belong to the step in progress: the row last asked for, outside "Set up all".
    private func showsHint(_ item: MacAccessSetupModel.Item) -> Bool {
        guard macAccess.run == nil, macAccess.access(item) != .allowed else { return false }
        return item == .keychain ? model.isReconnectingSavedCredentials : macAccess.requested == item
    }

    @ViewBuilder
    private func row(_ item: MacAccessSetupModel.Item) -> some View {
        let access = macAccess.access(item)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.permissionTitle).font(.system(size: 13, weight: .medium))
                if access != .allowed {
                    Text(rowDetail(item, access))
                        .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsHint(item) {
                    Text(item.stepHint(access, appName: MacAccessSetupModel.appName))
                        .font(.system(size: 11.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            MacPermissionStatusLabel(access: access, checking: isChecking(item))
            if access != .allowed && !isChecking(item) {
                if access == .needsReopen {
                    Button("Open System Settings") { Task { await macAccess.setUp(item) } }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(macAccess.run != nil || macAccess.settingUp != nil)
                    Button("Reopen Woven Matter") { macAccess.reopenApp() }
                        .buttonStyle(SettingsQuietButtonStyle())
                } else {
                    Button(macAccess.settingUp == item ? "Opening\u{2026}" : item.actionTitle(access)) {
                        Task { await macAccess.setUp(item) }
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(macAccess.run != nil || macAccess.settingUp != nil || model.isAuthorizingUsageCredential)
                }
            }
        }
    }

    private func rowDetail(_ item: MacAccessSetupModel.Item, _ access: MacAccessSetupModel.Access) -> String {
        if item == .keychain, model.keychainAccessReady == false, !model.isReconnectingSavedCredentials,
           let status = model.credentialAccessStatus {
            return status
        }
        switch access {
        case .turnedOff: return "Switched off in System Settings. " + item.permissionDetail
        case .needsReopen: return "If you switched it on, reopen Woven Matter so macOS applies it."
        default: return item.permissionDetail
        }
    }
}

/// The top of the page: "Set up all", the step in progress, or "All set".
private struct PermissionsSetupCard: View {
    @Environment(\.dashboardTheme) private var theme
    let macAccess: MacAccessSetupModel
    let keychainChecking: Bool

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.workspace)
            .clipShape(DashboardShapes.card)
    }

    @ViewBuilder
    private var content: some View {
        let remaining = macAccess.remaining
        if let run = macAccess.run {
            let item = run.current
            let access = macAccess.access(item)
            header(title: "Step \(run.index + 1) of \(run.steps.count): \(item.permissionTitle)",
                   detail: item.stepHint(access, appName: MacAccessSetupModel.appName)) {
                if access == .needsReopen {
                    Button("Reopen Woven Matter") { macAccess.reopenApp() }
                        .buttonStyle(DashboardPrimaryButtonStyle())
                } else {
                    Button(item.retryTitle(access)) { Task { await macAccess.retryStep() } }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(macAccess.settingUp != nil || (item == .keychain && keychainChecking))
                }
                Button("Skip") { macAccess.skipStep() }
                    .buttonStyle(SettingsQuietButtonStyle())
                Button("Stop") { macAccess.stopSetUpAll() }
                    .buttonStyle(SettingsQuietButtonStyle())
            }
        } else if remaining.isEmpty {
            HStack(alignment: .center, spacing: 10) {
                DashboardLucideIcon(glyph: .circleCheck, size: 16)
                    .foregroundStyle(DashboardPalette.success)
                Text("All set").font(.system(size: 14, weight: .semibold))
                Text("Agents won't stop for a permission prompt on this Mac.")
                    .font(.system(size: 12.5)).foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else if remaining == macAccess.awaitingReopen {
            header(title: "Reopen Woven Matter to finish",
                   detail: "macOS applies \(Self.list(remaining.map(\.permissionTitle))) after the app reopens.") {
                Button("Reopen Woven Matter") { macAccess.reopenApp() }
                    .buttonStyle(DashboardPrimaryButtonStyle())
            }
        } else {
            header(title: remaining.count == 1 ? "1 permission to allow" : "\(remaining.count) permissions to allow",
                   detail: "Set up all asks for each one in turn and opens System Settings when macOS needs you to switch it on there.") {
                Button("Set up all") { macAccess.startSetUpAll() }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled(macAccess.settingUp != nil || keychainChecking)
            }
        }
    }

    private func header<Actions: View>(title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12.5)).foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions() }
        }
    }

    static func list(_ names: [String]) -> String {
        names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
    }
}

/// One status vocabulary everywhere: Allowed, Not allowed yet, Switched off, Reopen to finish.
struct MacPermissionStatusLabel: View {
    let access: MacAccessSetupModel.Access
    var checking = false

    var body: some View {
        if checking {
            SettingsPill("Checking\u{2026}", tone: .neutral)
        } else {
            switch access {
            case .allowed:
                HStack(spacing: 5) {
                    DashboardLucideIcon(glyph: .check, size: 13).foregroundStyle(DashboardPalette.success)
                    Text("Allowed").font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Allowed")
            case .notAllowed: SettingsPill("Not allowed yet", tone: .neutral)
            case .turnedOff: SettingsPill("Switched off", tone: .warning)
            case .needsReopen: SettingsPill("Reopen to finish", tone: .warning)
            }
        }
    }
}

/// A one-line status for other settings that depend on these permissions,
/// linking to Permissions & Access instead of duplicating its controls.
struct MacPermissionStatusLink: View {
    let items: [MacAccessSetupModel.Item]
    let onOpen: () -> Void
    @State private var macAccess = MacAccessSetupModel.shared

    var body: some View {
        let missing = items.filter { macAccess.access($0) != .allowed }
        HStack(alignment: .center, spacing: 8) {
            if missing.isEmpty {
                DashboardLucideIcon(glyph: .check, size: 12).foregroundStyle(DashboardPalette.success)
                Text(items.count == 1 ? "\(items[0].permissionTitle) is allowed." : "Allowed on this Mac.")
            } else {
                Text("\(PermissionsSetupCard.list(missing.map(\.permissionTitle))) \(missing.count == 1 ? "isn't" : "aren't") allowed yet on this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onOpen) {
                HStack(spacing: 3) {
                    Text("Permissions & Access")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(DashboardPalette.success)
            .accessibilityHint("Opens Settings, Permissions & Access")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(DashboardPalette.mutedForeground)
        .task { macAccess.refresh(keychainReady: nil) }
    }
}

/// Permissions grouped by what they let Woven Matter do.
enum MacPermissionGroup: String, CaseIterable, Identifiable {
    case files, signIns, computerUse, dictation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "Files and folders"
        case .signIns: "Saved sign-ins"
        case .computerUse: "Control apps and see the screen"
        case .dictation: "Dictation"
        }
    }

    var detail: String {
        switch self {
        case .files: "Open and change files anywhere on this Mac, including Desktop, Documents, and Downloads."
        case .signIns: "Use the accounts, keys, and website passwords you've saved in Woven Matter."
        case .computerUse: "Computer Use clicks, types, and reads the screen in apps on this Mac."
        case .dictation: "Speak instead of typing in chats and notes."
        }
    }

    var items: [MacAccessSetupModel.Item] {
        switch self {
        case .files: [.fullDiskAccess]
        case .signIns: [.keychain]
        case .computerUse: [.accessibility, .screenRecording, .automation]
        case .dictation: [.microphone]
        }
    }
}

extension CompanionMacAccessStatus.Item {
    /// The name System Settings uses, so people can find it there.
    var permissionTitle: String {
        self == .keychain ? "Keychain" : displayName
    }

    var permissionDetail: String {
        switch self {
        case .fullDiskAccess: "Opens files in protected folders without asking each time."
        case .keychain: "Reads the sign-ins Woven Matter keeps in your Mac's Keychain."
        case .accessibility: "Clicks, types, and uses menus in other apps."
        case .screenRecording: "Sees windows and what's on the screen."
        case .automation: "Controls Finder and System Events. Other apps ask the first time an agent uses them."
        case .microphone: "Hears you while you dictate. Audio stays on this Mac."
        }
    }

    /// Items macOS asks about in a dialog; the rest are switched on in System Settings.
    var asksInApp: Bool { [.keychain, .automation, .microphone].contains(self) }

    func actionTitle(_ access: MacAccessSetupModel.Access) -> String {
        access == .turnedOff || !asksInApp ? "Open System Settings" : "Allow"
    }

    func retryTitle(_ access: MacAccessSetupModel.Access) -> String {
        access == .turnedOff || !asksInApp ? "Open System Settings" : "Ask again"
    }

    /// What to do right now, shown only while this permission is being set up.
    func stepHint(_ access: MacAccessSetupModel.Access, appName app: String) -> String {
        switch access {
        case .allowed: return "Allowed."
        case .needsReopen: return "If you switched on \(app) in System Settings, reopen it so macOS applies the change."
        case .turnedOff: return "This is switched off for \(app). Switch it on in System Settings."
        case .notAllowed: break
        }
        return switch self {
        case .keychain: "macOS asks once for each saved sign-in. Enter your Mac password and choose Always Allow so it doesn't ask again."
        case .fullDiskAccess: "In System Settings, switch on \(app) in the Full Disk Access list."
        case .accessibility: "In System Settings, switch on \(app) in the Accessibility list."
        case .screenRecording: "In System Settings, switch on \(app) under Screen & System Audio Recording. If macOS offers Quit & Reopen, choose it."
        case .automation: "Choose Allow when macOS asks whether \(app) can control System Events and Finder."
        case .microphone: "Choose Allow when macOS asks to use the microphone."
        }
    }
}
