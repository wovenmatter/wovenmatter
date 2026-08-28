import SwiftUI

struct RootView: View {
    @Bindable var model: ApplicationModel
    @AppStorage(DashboardTheme.storageKey) private var themeRawValue = DashboardTheme.green.rawValue

    private var theme: DashboardTheme {
        DashboardTheme(rawValue: themeRawValue) ?? .green
    }

    var body: some View {
        Group {
            switch model.state {
            case .starting:
                startupView
            case .ready:
                WorkspaceView(model: model)
            case .failed(let message):
                failureView(message: message)
            }
        }
        .environment(\.dashboardTheme, theme)
        .preferredColorScheme(.light)
        .background(theme.palette.workspace)
    }

    private var startupView: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(DashboardPalette.primary)
                    .frame(width: 56, height: 56)
                    .shadow(color: DashboardPalette.primary.opacity(0.3), radius: 15, y: 8)
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            Text("Opening your local workspace")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DashboardPalette.foreground)
                .padding(.top, 16)
            Text("Opening the native workspace stored on this Mac.")
                .font(.system(size: 12.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.workspace)
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(DashboardPalette.primary)
                    .frame(width: 56, height: 56)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(.white)
            }
            Text("Workspace unavailable")
                .font(.system(size: 15, weight: .medium))
                .padding(.top, 16)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 4)
            Button("Try Again") { model.retry() }
                .buttonStyle(DashboardPrimaryButtonStyle())
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.workspace)
    }
}
