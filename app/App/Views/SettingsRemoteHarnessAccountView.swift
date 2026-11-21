import AppKit
import SwiftUI

/// One account flow per harness installation on another machine. Both settings and
/// setup use this view; machine pages link here instead of starting authentication.
struct SettingsRemoteHarnessAccountView: View {
    @Bindable var model: MachinesStore
    let runtimeKind: AgentRuntimeKind
    let machine: Machine
    var embedded = false
    @State private var authorizationCode = ""
    @State private var keyMethod: HarnessSignInMethod?
    @State private var key = ""
    @State private var confirmsRemoval = false

    private var session: HarnessSignInSession? { model.signInSession(runtimeKind, on: machine.id) }

    var body: some View {
        Group {
            if embedded { accountContent }
            else { SettingsSection(title: "Account", detail: machine.name) { accountContent } }
        }.id(machine.id + runtimeKind.rawValue)
        .task { await model.refreshSignIn(runtimeKind, on: machine.id) }
        .onChange(of: session?.state) { _, state in
            if state == .succeeded { Task { await model.refreshSignIn(runtimeKind, on: machine.id) } }
        }
        .confirmationDialog("Remove your \(runtimeKind.displayName) account from \(machine.name)?",
                            isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove account", role: .destructive) { Task { await model.signOut(runtimeKind, on: machine.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(runtimeKind.displayName) signs out on \(machine.name). Sign in again to use it there.")
        }
    }

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let harness = model.harness(runtimeKind, on: machine.id) {
                if harness.isSystemInstall, let path = harness.path {
                    SettingsNote("Using \(path) (installed on the machine)")
                }
                let status = model.signInStatus(runtimeKind, on: machine.id)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Account").font(.settingsRow)
                        SettingsHarnessAccountDetails(
                            status: status,
                            fallback: HarnessAccountPresentation.accountLabel(runtimeKind, status: status))
                    }
                    Spacer()
                    harnessButtons(harness, status: status)
                        .disabled(model.isBusy(machine.id) || model.isSignInBusy(runtimeKind, on: machine.id))
                }
                if let keyMethod { keyEntry(keyMethod) }
            } else {
                SettingsEmpty("Connect this workspace to check sign-in.")
                Button("Refresh") { model.refreshHarnesses(on: machine.id) }.buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.isBusy(machine.id))
            }
            if let session, session.state != .succeeded {
                signInCard(session)
            }
            if model.isMaintaining(runtimeKind, on: machine.id) {
                SettingsNote("Account changes wait until \(runtimeKind.displayName) finishes installing or updating.")
            }
            if let message = model.signInMessage(runtimeKind, on: machine.id) { SettingsError(message) }
        }
    }

    @ViewBuilder
    private func harnessButtons(_ harness: HarnessInstallation, status: AgentSignInStatus?) -> some View {
        let methods = HarnessSignInFlow.methods(runtimeKind)
        if !harness.isInstalled {
            Text("Install the harness first").font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
        } else if status?.hasCredentials != true {
            if methods.count == 1, let method = methods.first {
                Button(method.title) { begin(method) }
                    .buttonStyle(SettingsQuietButtonStyle())
            } else if !methods.isEmpty {
                Menu("Sign in") {
                    ForEach(methods) { method in
                        Button(method.title) { begin(method) }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .buttonStyle(SettingsQuietButtonStyle())
            } else {
                Text("No supported sign-in methods")
                    .font(.settingsSecondary)
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
        } else {
            Button("Remove account") { confirmsRemoval = true }
                .buttonStyle(SettingsQuietButtonStyle())
        }
    }

    private func begin(_ method: HarnessSignInMethod) {
        authorizationCode = ""
        if case .keyBeforeStart = method.input {
            key = ""
            keyMethod = method
        } else {
            keyMethod = nil
            model.startSignIn(runtimeKind, method: method, on: machine.id)
        }
    }

    private func keyEntry(_ method: HarnessSignInMethod) -> some View {
        HStack(spacing: 8) {
            SecureField({ if case .keyBeforeStart(let label) = method.input { label } else { "Key" } }(), text: $key)
                .wovenInput()
                .onSubmit { saveKey(method) }
            Button("Save key") { saveKey(method) }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { keyMethod = nil; key = "" }
        }
        .buttonStyle(SettingsQuietButtonStyle())
    }

    private func saveKey(_ method: HarnessSignInMethod) {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.startSignIn(runtimeKind, method: method, key: value, on: machine.id)
        key = ""
        keyMethod = nil
    }

    private func signInCard(_ session: HarnessSignInSession) -> some View {
        SettingsInset {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(session.method.title)
                        .font(.settingsBody.weight(.semibold))
                    Spacer()
                    SettingsStatus(
                        session.isActive ? (session.url == nil ? "Starting" : "Waiting for you")
                            : session.state == .failed ? "Failed" : "Cancelled",
                        tone: session.state == .waiting ? .warning : .neutral
                    )
                    if session.isActive {
                        Button("Cancel") { model.cancelSignIn(runtimeKind, on: machine.id) }
                            .buttonStyle(SettingsQuietButtonStyle())
                    } else {
                        Button("Done") { model.dismissSignIn(runtimeKind, on: machine.id) }
                            .buttonStyle(SettingsQuietButtonStyle())
                    }
                }
                Text(session.message)
                    .font(.settingsSecondary)
                    .foregroundStyle(WovenPalette.mutedForeground)

                if let notice = session.notice {
                    SettingsNote(notice)
                }

                SettingsSignInHandoff(url: session.url, code: session.code)
                    .buttonStyle(SettingsQuietButtonStyle())

                if session.state == .waiting, session.acceptsCode {
                    HStack {
                        TextField(session.codeLabel, text: $authorizationCode)
                            .wovenInput()
                            .onSubmit { submitAuthorizationCode() }
                        Button(session.sentCode ? "Sent" : "Submit") { submitAuthorizationCode() }
                            .buttonStyle(SettingsQuietButtonStyle())
                            .disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if let tail = session.outputTail {
                    Text(tail).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(WovenPalette.mutedForeground).textSelection(.enabled)
                }

                if session.state == .failed, let error = session.error {
                    SettingsError(error)
                }
            }
        }
    }

    private func submitAuthorizationCode() {
        let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        model.submitSignInCode(runtimeKind, code: code, on: machine.id)
        authorizationCode = ""
    }
}
