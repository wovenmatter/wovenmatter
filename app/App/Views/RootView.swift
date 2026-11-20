import SwiftUI

struct RootView: View {
    @Bindable var model: ApplicationModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(WovenTheme.storageKey) private var themeRawValue = WovenTheme.green.rawValue

    private var theme: WovenTheme {
        WovenTheme(rawValue: themeRawValue) ?? .green
    }

    var body: some View {
        Group {
            switch model.state {
            case .ready:
                WorkspaceView(model: model)
            case .failed(let message):
                failureView(message: message)
            }
        }
        .task(id:model.state) {
            guard model.state == .ready else { return }
            if HarnessSetupPresentation.shared.takeAutomaticPresentation() {
                openWindow(id: HarnessSetupPresentation.windowID)
            }
        }
        .environment(\.wovenTheme, theme)
        .toggleStyle(CompactSwitchToggleStyle())
        .preferredColorScheme(theme.colorScheme)
        .background(theme.palette.workspace)
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(WovenPalette.primaryFill)
                    .frame(width: 56, height: 56)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(WovenPalette.primaryForeground)
            }
            Text("Workspace unavailable")
                .font(.system(size: 15, weight: .medium))
                .padding(.top, 16)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(WovenPalette.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 4)
            Button("Try Again") { model.retry() }
                .buttonStyle(WovenPrimaryButtonStyle())
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.workspace)
    }
}
