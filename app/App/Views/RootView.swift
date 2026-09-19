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
        .toggleStyle(DashboardSwitchToggleStyle())
        .preferredColorScheme(.light)
        .background(theme.palette.workspace)
        .alert("Session limit reached", isPresented: $model.activeSessionLimitPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You're at your limit of \(model.agentTools?.settings.maximumRunningSessions ?? 16) sessions running simultaneously. Let a session finish or change the limit in General settings.")
        }
        .sheet(item: Binding(get: { model.pendingSessionAccess.first }, set: { value in
            if value == nil, let request = model.pendingSessionAccess.first { model.resolveSessionToolAccess(id: request.id, allowed: false) }
        })) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text("Allow session access?").font(.headline)
                Text("Conversation history is off. Allow “\(request.sourceTitle)” to read and coordinate “\(request.targetTitle)”? Access lasts while coordination is active.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.resolveSessionToolAccess(id: request.id, allowed: false) }
                    Button("Allow access") { model.resolveSessionToolAccess(id: request.id, allowed: true) }
                        .buttonStyle(DashboardPrimaryButtonStyle())
                }
            }.padding(24).frame(width: 440)
        }
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
            Text("Opening workspace…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DashboardPalette.foreground)
                .padding(.top, 16)
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
