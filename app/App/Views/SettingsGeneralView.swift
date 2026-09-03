import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsGeneralView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void

    @Environment(\.dashboardTheme) private var theme
    @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
    @AppStorage(DashboardSidebarStyle.storageKey) private var storedSidebarStyle = DashboardSidebarStyle.defaultStyle.rawValue
    @AppStorage(DashboardCodexLogoStyle.storageKey) private var storedCodexLogoStyle =
        DashboardCodexLogoStyle.defaultStyle.rawValue
    @State private var releaseUpdateState: ReleaseUpdateState = .idle
    private let releaseUpdateInstaller = WovenMatterReleaseUpdateInstaller()

    private var codexLogoStyle: DashboardCodexLogoStyle {
        DashboardCodexLogoStyle(rawValue: storedCodexLogoStyle) ?? .defaultStyle
    }

    private var sidebarStyleBinding: Binding<DashboardSidebarStyle> {
        Binding(
            get: {
                DashboardSidebarStyle(rawValue: storedSidebarStyle)
                    ?? .defaultStyle
            },
            set: { storedSidebarStyle = $0.rawValue }
        )
    }

    var body: some View {
        SettingsPage(
            title: "General",
            detail: "Appearance, updates, and app-wide behavior.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            appearanceCard
            releaseUpdateCard
            conversationTitlesCard
            supportedHarnessesCard
        }
        .onChange(of: storedTheme) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
        .onChange(of: storedSidebarStyle) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
    }

    private var releaseUpdateCard: some View {
        SettingsCard(
            title: "Software updates",
            detail: "Production releases are signed, notarized, and downloaded from GitHub Releases."
        ) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(releaseUpdateState.title(currentVersion: currentVersion))
                        .font(.system(size: 13, weight: .medium))
                    Text(releaseUpdateState.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(releaseUpdateState.buttonTitle) {
                    performReleaseUpdateAction()
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(releaseUpdateState.isWorking)
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    private func performReleaseUpdateAction() {
        switch releaseUpdateState {
        case .available(let manifest), .downloadFailed(let manifest, _):
            downloadRelease(manifest)
        case .ready(let release), .installFailed(let release, _):
            installRelease(release)
        case .idle, .current, .failed:
            checkForRelease()
        case .checking, .downloading, .installing:
            break
        }
    }

    private func checkForRelease() {
        releaseUpdateState = .checking
        Task {
            do {
                switch try await WovenMatterReleaseUpdateClient().check(
                    currentVersion: currentVersion
                ) {
                case .current:
                    releaseUpdateState = .current
                case .available(let manifest):
                    if let cached = try await releaseUpdateInstaller.cachedRelease(
                        for: manifest
                    ) {
                        releaseUpdateState = .ready(cached)
                    } else {
                        releaseUpdateState = .available(manifest)
                    }
                }
            } catch {
                releaseUpdateState = .failed(error.localizedDescription)
            }
        }
    }

    private func downloadRelease(_ manifest: WovenMatterReleaseManifest) {
        releaseUpdateState = .downloading(manifest)
        Task {
            do {
                releaseUpdateState = .ready(
                    try await releaseUpdateInstaller.download(manifest)
                )
            } catch {
                releaseUpdateState = .downloadFailed(
                    manifest,
                    error.localizedDescription
                )
            }
        }
    }

    private func installRelease(_ release: WovenMatterDownloadedRelease) {
        releaseUpdateState = .installing(release)
        Task {
            do {
                try await releaseUpdateInstaller.beginInstallation(of: release)
                NSApplication.shared.terminate(nil)
            } catch {
                releaseUpdateState = .installFailed(
                    release,
                    error.localizedDescription
                )
            }
        }
    }

    private var appearanceCard: some View {
        SettingsCard(
            title: "Appearance",
            detail: "Choose the dashboard color treatment and how workspace navigation is arranged."
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(DashboardTheme.allCases) { option in
                    themeChoice(option)
                }
            }

            Text("Theme changes apply immediately and stay with this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(DashboardPalette.mutedForeground)

            Divider()
                .overlay(theme.palette.border)
                .padding(.vertical, 2)

            sidebarLayoutSelector
        }
    }

    private var sidebarLayoutSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sidebar layout")
                    .font(.system(size: 13, weight: .medium))
                Text("Choose how navigation and folder contents share the sidebar area.")
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DashboardSegmentedSelector(
                options: DashboardSidebarStyle.allCases,
                selection: sidebarStyleBinding
            ) { style in
                style.title
            }
            .frame(maxWidth: 520)

            Text(sidebarStyleBinding.wrappedValue.detail)
                .font(.system(size: 11))
                .foregroundStyle(DashboardPalette.mutedForeground)
        }
    }

    private func themeChoice(_ option: DashboardTheme) -> some View {
        let selected = theme == option
        let description = option == .green
            ? "White workspace with British Racing Green glass sidebars and controls."
            : "Warm cognac surround with white sidebars and restrained green actions."

        return Button {
            storedTheme = option.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                SettingsThemePreview(theme: option)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DashboardPalette.foreground)
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DashboardPalette.primary)
                        .opacity(selected ? 1 : 0)
                }
            }
            .padding(12)
            .background(selected ? theme.palette.themeSoft : theme.palette.themeWhisper)
            .clipShape(DashboardShapes.card)
            .overlay {
                if selected {
                    DashboardShapes.card
                        .stroke(theme.palette.themeRing, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var conversationTitlesCard: some View {
        SettingsCard(
            title: "Conversation titles",
            detail: "Automatically name new conversations using the Codex CLI account signed in on this Mac."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.titleGenerationStatus)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                    Spacer()
                    Toggle(
                        "Generate with Codex",
                        isOn: Binding(
                            get: { model.titleGenerationSettings.isEnabled },
                            set: { model.setTitleGenerationEnabled($0) }
                        )
                    )
                    .toggleStyle(.switch)
                }

                if model.titleGenerationSettings.isEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            Text("Model")
                                .font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 12)
                            SettingsMenuPicker(
                                selection: model.titleGenerationSettings.model,
                                options: model.titleGenerationCapabilities?.models ?? []
                            ) { option in
                                model.setTitleGenerationModel(option)
                            }
                        }

                        HStack(spacing: 16) {
                            Text("Thinking level")
                                .font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 12)
                            SettingsMenuPicker(
                                selection: model.titleGenerationSettings.thinking,
                                options: model.titleGenerationCapabilities?.thinkingLevels ?? [],
                                capitalizeOptions: true
                            ) { option in
                                model.setTitleGenerationThinking(option)
                            }
                        }

                        HStack {
                            Spacer()
                            Button(
                                model.isRefreshingTitleGenerationCapabilities
                                    ? "Checking…" : "Refresh options"
                            ) {
                                model.refreshTitleGenerationCapabilitiesNow()
                            }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .disabled(model.isRefreshingTitleGenerationCapabilities)
                        }
                    }
                }
            }
        }
    }

    private var supportedHarnessesCard: some View {
        SettingsCard(
            title: "Supported harnesses"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(DashboardHarnessLogo.displayCases, id: \.self) { harness in
                    if harness == .codex {
                        Button {
                            storedCodexLogoStyle = codexLogoStyle.next.rawValue
                        } label: {
                            supportedHarnessTile(harness)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                        .padding(10)
                                        .accessibilityHidden(true)
                                }
                        }
                        .buttonStyle(.plain)
                        .help("Switch Codex to the \(codexLogoStyle.next.displayName) logo")
                        .accessibilityLabel("Codex harness logo")
                        .accessibilityValue(codexLogoStyle.displayName)
                        .accessibilityHint("Switches to the \(codexLogoStyle.next.displayName) logo")
                    } else {
                        supportedHarnessTile(harness)
                    }
                }
            }
        }
    }

    private func supportedHarnessTile(_ harness: DashboardHarnessLogo) -> some View {
        VStack(spacing: 9) {
            DashboardHarnessLogoIcon(logo: harness, size: 34)
                .frame(height: 38)

            Text(harness.displayName)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .padding(.horizontal, 8)
        .background(theme.palette.themeWhisper)
        .clipShape(DashboardShapes.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(harness.displayName)
    }

}

private enum ReleaseUpdateState {
    case idle
    case checking
    case current
    case available(WovenMatterReleaseManifest)
    case downloading(WovenMatterReleaseManifest)
    case ready(WovenMatterDownloadedRelease)
    case installing(WovenMatterDownloadedRelease)
    case downloadFailed(WovenMatterReleaseManifest, String)
    case installFailed(WovenMatterDownloadedRelease, String)
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    var buttonTitle: String {
        switch self {
        case .idle, .current, .failed: "Check for Updates"
        case .checking: "Checking…"
        case .available: "Download Update"
        case .downloading: "Downloading…"
        case .ready: "Install Update"
        case .installing: "Installing…"
        case .downloadFailed: "Try Download Again"
        case .installFailed: "Try Install Again"
        }
    }

    func title(currentVersion: String) -> String {
        switch self {
        case .available(let manifest),
             .downloading(let manifest),
             .downloadFailed(let manifest, _):
            "Woven Matter \(manifest.version) is available"
        case .ready(let release),
             .installing(let release),
             .installFailed(let release, _):
            "Woven Matter \(release.manifest.version) is ready"
        default: "Woven Matter \(currentVersion)"
        }
    }

    var detail: String {
        switch self {
        case .idle: "Check the latest published Apple Silicon release."
        case .checking: "Checking the signed production release channel…"
        case .current: "This Mac has the latest published version."
        case .available: "Download and verify the signed update inside Woven Matter."
        case .downloading: "Downloading the signed update…"
        case .ready: "The update is downloaded and verified. Install it now to relaunch."
        case .installing: "Preparing the update and relaunching Woven Matter…"
        case .downloadFailed(_, let message), .installFailed(_, let message): message
        case .failed(let message): message
        }
    }
}
