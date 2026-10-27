import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// One account flow per harness installation. Both settings and setup use this
/// view; workspace inventory links here instead of starting authentication.
struct SettingsRemoteHarnessAccountView: View {
    @Bindable var model: RemoteWorkspacesModel
    let runtimeKind: AgentRuntimeKind
    let workspace: RemoteWorkspaceConfiguration
    var embedded = false
    @State private var authorizationCode = ""

    var body: some View {
        Group {
            if embedded { accountContent }
            else { SettingsCard(title: "Account", detail: workspace.name) { accountContent } }
        }.id(workspace.id.uuidString + runtimeKind.rawValue)
        .task { await model.refreshSignInStatus(workspace) }
        .onChange(of: model.authenticationSessions[workspace.id]?.state) { _, state in
            if state == "succeeded" { Task { await model.refreshSignInStatus(workspace) } }
        }
    }

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let harness = model.currentHarnesses(for: workspace).first(where: { $0.id == runtimeKind }) {
                if workspace.kind == .host, harness.source == "system", let path = harness.path {
                    SettingsNote("Using \(path) (installed on host)")
                }
                HStack {
                    SettingsHarnessAccountDetails(
                        status: model.signInStatuses[workspace.id]?.first { $0.id == runtimeKind.rawValue },
                        fallback: HarnessAccountPresentation.remoteLabel(harness))
                    Spacer()
                    harnessButtons(harness, workspace: workspace)
                        .disabled(model.busyWorkspaceIDs.contains(workspace.id))
                }
            } else {
                SettingsEmpty("Connect this workspace to check sign-in.")
                Button("Refresh") { model.refresh(workspace) }.buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.busyWorkspaceIDs.contains(workspace.id))
            }
            if let session = model.authenticationSessions[workspace.id], session.harnessID == runtimeKind {
                signInCard(session, workspace: workspace)
            }
            if let error = model.actionErrors[workspace.id]?[runtimeKind] { SettingsError(error) }
        }
    }

    @ViewBuilder
    private func harnessButtons(
        _ harness: RemoteHarnessStatus,
        workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        if harness.installationStatus.map({ $0 != "installed" }) ?? ["cli_missing", "adapter_missing"].contains(harness.state) {
            Text("Install the harness first").font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
        } else if harness.authenticationStatus != "verified" && harness.authenticationStatus != "configured" {
            if harness.setupMethods.count == 1,
               let method = harness.setupMethods.first {
                Button("Sign in") {
                    startSignIn(harness, method: method, workspace: workspace)
                }
                .buttonStyle(DashboardPrimaryButtonStyle())
            } else if !harness.setupMethods.isEmpty {
                Menu("Sign in…") {
                    ForEach(harness.setupMethods) { method in
                        Button(method.displayName) {
                            startSignIn(harness, method: method, workspace: workspace)
                        }
                    }
                }
                .buttonStyle(DashboardPrimaryButtonStyle())
            } else {
                Text("No supported sign-in methods")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
        } else {
            Button("Recheck") {
                model.performHarnessAction("recheck", harness: harness, configuration: workspace)
            }
            .buttonStyle(SettingsQuietButtonStyle())
            if !harness.setupMethods.isEmpty {
                Menu("Change sign-in…") {
                    ForEach(harness.setupMethods) { method in
                        Button(method.displayName) {
                            startSignIn(harness, method: method, workspace: workspace)
                        }
                    }
                }
                .buttonStyle(SettingsQuietButtonStyle())
            }
        }
    }

    private func startSignIn(
        _ harness: RemoteHarnessStatus,
        method: RemoteHarnessSetupMethod,
        workspace: RemoteWorkspaceConfiguration
    ) {
        authorizationCode = ""
        model.startHarnessSignIn(
            harness: harness,
            method: method,
            configuration: workspace
        )
    }

    private func signInCard(
        _ session: RemoteHarnessAuthenticationSession,
        workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        SettingsInset {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(session.methodName)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    SettingsPill(
                        session.state.replacingOccurrences(of: "_", with: " ").capitalized,
                        tone: session.state == "waiting_for_user" ? .warning : .neutral
                    )
                    if session.state == "waiting_for_user" {
                        Button("Cancel") {
                            model.cancelHarnessSignIn(configuration: workspace)
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    }
                }
                Text(session.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)

                if let notice = session.notice {
                    SettingsNote(notice)
                }

                if let url = session.verificationURL {
                    Button("Open sign-in page") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                }

                if let userCode = session.userCode {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("One-time code")
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                            Text(userCode)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Copy code") { copy(userCode) }
                            .buttonStyle(SettingsQuietButtonStyle())
                    }
                }

                if session.state == "waiting_for_user",
                   session.acceptsAuthorizationCode {
                    HStack {
                        credentialInput(session, workspace: workspace)
                        Button("Submit") {
                            submitAuthorizationCode(workspace)
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                        .disabled(
                            authorizationCode.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                    }
                }

                if let error = session.error {
                    SettingsError(error)
                }
            }
        }
    }

    @ViewBuilder
    private func credentialInput(
        _ session: RemoteHarnessAuthenticationSession,
        workspace: RemoteWorkspaceConfiguration
    ) -> some View {
        let label = session.credentialInputLabel ?? "Authorization code"
        if session.credentialInputSecret == true {
            SecureField(label, text: $authorizationCode)
                .settingsInput()
                .onSubmit { submitAuthorizationCode(workspace) }
        } else {
            TextField(label, text: $authorizationCode)
                .settingsInput()
                .onSubmit { submitAuthorizationCode(workspace) }
        }
    }

    private func submitAuthorizationCode(
        _ workspace: RemoteWorkspaceConfiguration
    ) {
        let code = authorizationCode.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !code.isEmpty else { return }
        model.submitAuthorizationCode(code, configuration: workspace)
        authorizationCode = ""
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

}
