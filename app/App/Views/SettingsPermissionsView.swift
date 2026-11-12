import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// Settings → Permissions & Access: Keychain and every macOS permission Woven Matter
/// uses, in one section: what each one is for, its own Allow button, and "Allow all".
struct SettingsPermissionsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    var onBack: () -> Void

    @State private var macAccess = MacAccessSetupModel.shared
    @State private var showsCredentialDisclosure = false

    static let lead = "Give agents the access they need on this Mac. You only need to allow each one once."

    var body: some View {
        SettingsPage(
            title: "Permissions & Access",
            detail: Self.lead,
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            SettingsSection {
                HStack(alignment: .center, spacing: 16) {
                    Text(summaryTitle).font(.settingsSection)
                    Spacer(minLength: 16)
                    if !macAccess.remaining.isEmpty {
                        Button(macAccess.allowingAll ? "Allowing\u{2026}" : "Allow all") { macAccess.allowAll() }
                            .buttonStyle(DashboardPrimaryButtonStyle())
                            .disabled(macAccess.allowingAll || macAccess.settingUp != nil || model.isReconnectingSavedCredentials
                                      || macAccess.remaining.allSatisfy { macAccess.access($0) == .needsReopen })
                    }
                }
                .frame(minHeight: SettingsMetrics.rowHeight)
                ForEach(MacAccessSetupModel.setupOrder, id: \.self) { item in
                    row(item)
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
        .onChange(of: model.isReconnectingSavedCredentials) { _, checking in
            if !checking { macAccess.keychainRequestEnded() }
        }
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
                    macAccess.keychainRequestEnded()
                }
            )
        }
    }

    private func isChecking(_ item: MacAccessSetupModel.Item) -> Bool {
        item == .keychain && model.isReconnectingSavedCredentials
    }

    private var summaryTitle: String {
        let count = macAccess.remaining.count
        return count == 0 ? "All allowed" : count == 1 ? "1 not allowed yet" : "\(count) not allowed yet"
    }

    @ViewBuilder
    private func row(_ item: MacAccessSetupModel.Item) -> some View {
        let access = macAccess.access(item)
        // Each row says only what the permission does; the button handles the rest.
        SettingsRow(title: item.permissionTitle, detail: item.permissionDetail) {
            if access == .allowed {
                MacPermissionStatusLabel(access: access)
            } else if isChecking(item) {
                Text("Checking\u{2026}").font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
            } else if access == .needsReopen {
                Button("Reopen") { macAccess.reopenApp() }.buttonStyle(SettingsQuietButtonStyle())
            } else {
                Button(macAccess.settingUp == item ? "Opening\u{2026}" : "Allow") { Task { await macAccess.setUp(item) } }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(macAccess.allowingAll || macAccess.settingUp != nil || model.isAuthorizingUsageCredential)
            }
        }
    }
}

enum PermissionNames {
    static func list(_ names: [String]) -> String {
        names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
    }
}

/// The quiet "Allowed" mark for a granted permission.
struct MacPermissionStatusLabel: View {
    let access: MacAccessSetupModel.Access

    var body: some View {
        if access == .allowed {
            HStack(spacing: 5) {
                DashboardLucideIcon(glyph: .check, size: 13).foregroundStyle(DashboardPalette.success)
                Text("Allowed").font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Allowed")
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
                Text("\(PermissionNames.list(missing.map(\.permissionTitle))) \(missing.count == 1 ? "isn't" : "aren't") allowed yet on this Mac.")
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
        .font(.settingsSecondary)
        .foregroundStyle(DashboardPalette.mutedForeground)
        .task { macAccess.refresh(keychainReady: nil) }
    }
}

extension MacAccessStatus.Item {
    /// The name System Settings uses, so people can find it there.
    var permissionTitle: String {
        self == .keychain ? "Keychain" : displayName
    }

    /// What the permission does, in one line.
    var permissionDetail: String {
        switch self {
        case .keychain: "Stores your credentials, API keys, and website passwords in your Mac's Keychain."
        case .microphone: "Uses this Mac's microphone and its built-in dictation model for dictation."
        case .automation: "Lets agents control Finder, System Events, and other apps on this Mac."
        case .fullDiskAccess: "Lets agents open and edit files anywhere on this Mac, including Desktop, Documents, and Downloads."
        case .accessibility: "Lets agents click, type, and use menus in other apps."
        case .screenRecording: "Lets agents see windows and what's on the screen for Computer Use."
        }
    }

    /// Items macOS asks about in a dialog; the rest are switched on in System Settings.
    var asksInApp: Bool { [.keychain, .automation, .microphone].contains(self) }
}
