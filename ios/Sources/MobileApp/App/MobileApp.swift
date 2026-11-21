import SwiftUI
import WovenProtocol

@main
struct MobileApp: App {
    @State private var model = MobileModel()
    @AppStorage(WovenTheme.storageKey) private var storedTheme = WovenTheme.green.rawValue
    @Environment(\.scenePhase) private var scenePhase
    private var theme: WovenTheme { WovenTheme(rawValue: storedTheme) ?? .green }

    var body: some Scene {
        WindowGroup {
            MobileShell(model: model)
                .preferredColorScheme(theme.colorScheme)
                .environment(\.wovenTheme, theme)
                .tint(theme.palette.themeAccent)
                .foregroundStyle(WovenPalette.foreground)
                .toggleStyle(SwitchToggleStyle(tint: WovenPalette.primary))
                .scrollIndicators(.never)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { MobileDictation.shared.stop() }
                    guard phase != .inactive else { return }
                    Task { await model.device.setActive(phase == .active) }
                }
                .onOpenURL { url in
                    // A connection link from a Mac's QR code: `…://connect/<code>`.
                    guard let code = ConnectionCode(link: url) else { return }
                    model.openSettings(.connect(code))
                }
        }
    }
}
