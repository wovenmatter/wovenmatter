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
            case .starting:
                startupView
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
        .alert("Session limit reached", isPresented: $model.activeSessionLimitPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You're at your limit of \(model.agentTools.settings.maximumRunningSessions) sessions running simultaneously. Let a session finish or change the limit in Settings → Woven MCP.")
        }
        .alert("Session access could not be granted", isPresented: Binding(
            get: { model.sessionAccessError != nil }, set: { if !$0 { model.sessionAccessError = nil } }
        )) {
            Button("OK", role: .cancel) { model.sessionAccessError = nil }
        } message: { Text(model.sessionAccessError ?? "") }
        .sheet(item: Binding(get: { model.agentTools.pendingSessionAccess.first }, set: { value in
            if value == nil, let request = model.agentTools.pendingSessionAccess.first { Task { await model.agentTools.resolveSessionToolAccess(id: request.id, allowed: false) } }
        })) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text("Allow session access?").font(.headline)
                Text("Conversation history is off. Allow “\(request.sourceTitle)” to read and coordinate “\(request.targetTitle)”? Access lasts while coordination is active.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { Task { await model.agentTools.resolveSessionToolAccess(id: request.id, allowed: false) } }
                    Button("Allow access") { Task { await model.agentTools.resolveSessionToolAccess(id: request.id, allowed: true) } }
                        .buttonStyle(WovenPrimaryButtonStyle())
                }
            }.padding(24).frame(width: 440)
        }
    }

    private var startupView: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(WovenPalette.primaryFill)
                    .frame(width: 56, height: 56)
                    .shadow(color: WovenPalette.primaryFill.opacity(0.3), radius: 15, y: 8)
                ProgressView()
                    .controlSize(.small)
                    .tint(WovenPalette.primaryForeground)
            }
            Text(model.startupProgress?.title ?? "Opening workspace…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(WovenPalette.foreground)
                .padding(.top, 16)
            if let progress = model.startupProgress {
                Text(progress.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .padding(.top, 4)
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(WovenPalette.primaryFill)
                        .frame(width: 280)
                        .animation(.linear(duration: 0.25), value: fraction)
                        .padding(.top, 16)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
