import AppKit
import SwiftUI

/// Settings → Permissions & Access: every macOS permission Woven Matter uses, in one
/// section: what each one is for, its own Allow button, and "Allow all".
struct SettingsPermissionsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    var onBack: () -> Void

    @State private var macAccess = MacAccessSetupModel.shared

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
                            .buttonStyle(WovenPrimaryButtonStyle())
                            .disabled(macAccess.allowingAll || macAccess.settingUp != nil
                                      || macAccess.remaining.allSatisfy { macAccess.access($0) == .needsReopen })
                    }
                }
                .frame(minHeight: SettingsMetrics.rowHeight)
                ForEach(MacAccessSetupModel.setupOrder, id: \.self) { item in
                    row(item)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                macAccess.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
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
            } else if access == .needsReopen {
                Button("Reopen") { macAccess.reopenApp() }.buttonStyle(SettingsQuietButtonStyle())
            } else {
                Button(macAccess.settingUp == item ? "Opening\u{2026}" : "Allow") { Task { await macAccess.setUp(item) } }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(macAccess.allowingAll || macAccess.settingUp != nil)
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
                LucideIcon(glyph: .check, size: 13).foregroundStyle(WovenPalette.success)
                Text("Allowed").font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
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
                LucideIcon(glyph: .check, size: 12).foregroundStyle(WovenPalette.success)
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
            .foregroundStyle(WovenPalette.success)
            .accessibilityHint("Opens Settings, Permissions & Access")
        }
        .font(.settingsSecondary)
        .foregroundStyle(WovenPalette.mutedForeground)
        .task { macAccess.refresh() }
    }
}

extension MacAccessStatus.Item {
    /// The name System Settings uses, so people can find it there.
    var permissionTitle: String { displayName }

    /// What the permission does, in one line.
    var permissionDetail: String {
        switch self {
        case .microphone: "Uses this Mac's microphone and its built-in dictation model for dictation."
        case .automation: "Lets agents control Finder, System Events, and other apps on this Mac."
        case .fullDiskAccess: "Lets agents open and edit files anywhere on this Mac, including Desktop, Documents, and Downloads."
        case .accessibility: "Lets agents click, type, and use menus in other apps."
        case .screenRecording: "Lets agents see windows and what's on the screen for Computer Use."
        }
    }

    /// Items macOS asks about in a dialog; the rest are switched on in System Settings.
    var asksInApp: Bool { [.automation, .microphone].contains(self) }
}
