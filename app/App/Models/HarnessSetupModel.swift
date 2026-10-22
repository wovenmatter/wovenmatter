import AppKit
import Observation
import WovenMatterClient
import WovenMatterCore

@MainActor
final class HarnessSetupPresentation {
    static let shared = HarnessSetupPresentation()
    static let windowID = "harness-setup"
    private var requestedAutomatically = false

    func prepareForLaunch() {
        let defaults = UserDefaults.standard
        let database = try? ApplicationModel.dashboardSupportDirectory().appending(path: "workspace.sqlite")
        HarnessOnboarding.prepareFirstLaunch(defaults: defaults,
            hasExistingWorkspace: database.map { FileManager.default.fileExists(atPath: $0.path) } ?? true,
            hasExistingPreferences: defaults.object(forKey: "wovenmatter.title-generation.enabled") != nil
                || defaults.bool(forKey: LocalExecutionRole.libraryClientPreferenceKey))
    }

    func takeAutomaticPresentation() -> Bool {
        guard !requestedAutomatically,
              UserDefaults.standard.string(forKey: HarnessOnboarding.preferenceKey) == "pending" else { return false }
        requestedAutomatically = true
        return true
    }

    func dismiss() {
        UserDefaults.standard.set("dismissed", forKey: HarnessOnboarding.preferenceKey)
    }
}

@MainActor @Observable
final class HarnessSetupModel {
    let application: ApplicationModel
    var selected: Set<AgentRuntimeKind> = []
    private(set) var checking = false
    private(set) var activeInstall: AgentRuntimeKind?
    private(set) var resolvingInstaller = false
    var errors: [AgentRuntimeKind: String] = [:]
    var notice: String?
    private var work: Task<Void, Never>?
    private var closed = false

    init(application: ApplicationModel) { self.application = application }

    func open() {
        closed = false
        refresh()
    }

    var busy: Bool { checking || activeInstall != nil }
    var maintenanceBusy: Bool {
        application.checkingRuntimeInventory || !application.checkingRuntimeKinds.isEmpty
            || !application.installingLocalACPRuntimeKinds.isEmpty
            || application.openCode?.isInstalling == true
            || application.preparedLocalACPRuntimeInstall != nil
    }

    func refresh() {
        guard !busy, !maintenanceBusy else { return }
        checking = true
        work = Task {
            defer { checking = false }
            do {
                try await application.requestSetupRuntimeCommand(.refreshInventory)
                try await waitForMaintenance()
                await refreshSignIns()
            } catch is CancellationError { }
            catch { notice = "Could not finish checking this Mac. Choose Check again to retry." }
        }
    }

    func refreshSignIns() async {
        for kind in HarnessOnboarding.runtimes { await application.refreshHarnessSignIn(kind) }
    }

    func installSelected() {
        guard !busy, !maintenanceBusy, !application.localRuntimeMaintenanceHasActiveConversation else { return }
        let kinds = HarnessOnboarding.runtimes.filter { selected.contains($0) }
        guard let first = kinds.first else { return }
        activeInstall = first
        notice = nil
        work = Task {
            defer { activeInstall = nil }
            for kind in kinds {
                guard !Task.isCancelled else { return }
                activeInstall = kind
                errors[kind] = nil
                do {
                    try await application.requestSetupRuntimeCommand(.install(kind))
                    try await waitForMaintenance(kind)
                    if application.runtimeInventories[kind]?.isInstalled == true {
                        selected.remove(kind)
                    } else if selected.contains(kind) {
                        errors[kind] = application.runtimeFailureDetails[kind]
                            ?? "Installation was skipped or could not finish. Select this harness to try again."
                    }
                } catch is CancellationError { return }
                catch { errors[kind] = "Installation could not finish. Select this harness to try again." }
            }
            await refreshSignIns()
        }
    }

    func resolveInstaller(install: Bool) {
        guard !resolvingInstaller, let kind = activeInstall,
              application.preparedLocalACPRuntimeInstall?.definition.runtimeKind == kind else { return }
        resolvingInstaller = true
        Task {
            defer { resolvingInstaller = false }
            do {
                try await application.requestSetupRuntimeCommand(install ? .confirmInstall : .cancelInstall)
                if !install { selected.remove(kind) }
            } catch { errors[kind] = "Could not confirm the installer. Try again." }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        work?.cancel()
        work = nil
        // Leave an already running verified installer to finish; stop the queue.
        if let kind = activeInstall, kind != .opencode {
            let application = application
            Task {
                // Preparation may finish after the window closes. Do not leave
                // its approval blocking every subsequent maintenance action.
                let deadline = Date().addingTimeInterval(15 * 60)
                while application.installingLocalACPRuntimeKinds.contains(kind),
                      application.preparedLocalACPRuntimeInstall == nil, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if application.preparedLocalACPRuntimeInstall?.definition.runtimeKind == kind {
                    application.cancelPreparedLocalACPRuntimeInstall()
                }
            }
        }
        HarnessSetupPresentation.shared.dismiss()
    }

    private func waitForMaintenance(_ kind: AgentRuntimeKind? = nil) async throws {
        let deadline = Date().addingTimeInterval(15 * 60)
        while kind.map({ application.runtimeMaintenanceBusy($0) || application.checkingRuntimeKinds.contains($0) }) ?? maintenanceBusy {
            try Task.checkCancellation()
            guard Date() < deadline else { throw RuntimeMaintenanceError.timeout }
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
    }
}

extension ApplicationModel {
    func refreshHarnessSignIn(_ kind: AgentRuntimeKind) async {
        await harnessSignIn.refresh(kind)
        if harnessSignIn.takeCompletedSignIn(kind) {
            // An explicit completed sign-in can clear a previous authentication
            // failure. Ordinary status refreshes never start a readiness session.
            refreshLocalACPRuntimesNow(checkCredentialsFor: [kind])
        }
    }

    /// Await command acceptance so setup also observes operations owned by the
    /// background service before advancing its installation queue.
    func requestSetupRuntimeCommand(_ command: BackendRuntimeCommand) async throws {
        let payload = try JSONEncoder().encode(command)
        if isBackendFrontend {
            let response = try await callBackend(method: "runtime.command", payload: payload)
            applyBackendRuntimeSnapshot(try JSONDecoder().decode(BackendRuntimeSnapshot.self, from: response))
        } else {
            _ = try await handleBackendRuntimeRequest(payload: payload)
        }
    }
}

/// Native CLI accounts are distinct from Pi Durable's provider connections.
/// Authentication starts only when the user presses a Sign in button.
@MainActor @Observable
final class HarnessSignInModel {
    private(set) var statuses: [AgentRuntimeKind: AgentSignInStatus] = [:]
    private(set) var checking: Set<AgentRuntimeKind> = []
    private(set) var opening: Set<AgentRuntimeKind> = []
    private(set) var messages: [AgentRuntimeKind: String] = [:]
    private var awaitingReturn: Set<AgentRuntimeKind> = []

    func refresh(_ kind: AgentRuntimeKind) async {
        guard checking.insert(kind).inserted else { return }
        defer { checking.remove(kind) }
        let executable = await Self.executable(kind)
        statuses[kind] = await HarnessOnboarding.checkSignIn(kind, executable: executable)
        if statuses[kind]?.state == "verified" || statuses[kind]?.state == "credentials_present" {
            messages[kind] = nil
        }
    }

    func takeCompletedSignIn(_ kind: AgentRuntimeKind) -> Bool {
        guard ["verified", "credentials_present"].contains(statuses[kind]?.state ?? "") else { return false }
        return awaitingReturn.remove(kind) != nil
    }

    func signIn(_ kind: AgentRuntimeKind) {
        guard opening.insert(kind).inserted else { return }
        Task {
            defer { opening.remove(kind) }
            do {
                guard let executable = await Self.executable(kind),
                      let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
                else { throw RuntimeMaintenanceError.unavailable }
                let searchPath = await Task.detached { LocalACPRuntimeResolver.executableSearchPath }.value
                guard let script = HarnessOnboarding.signInScript(kind, executable: executable, searchPath: searchPath)
                else { throw RuntimeMaintenanceError.unavailable }
                let directory = try ApplicationModel.dashboardSupportDirectory().appending(path: "Sign-in", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let file = directory.appending(path: kind.rawValue + ".command")
                try Data(script.utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init())
                awaitingReturn.insert(kind)
                messages[kind] = "Finish signing in in Terminal, then return here."
            } catch {
                messages[kind] = "Could not open sign-in. Check that this harness and Terminal are installed, then try again."
            }
        }
    }

    private nonisolated static func executable(_ kind: AgentRuntimeKind) async -> URL? {
        await Task.detached(priority: .utility) {
            guard let definition = LocalACPRuntimeCatalog.definition(for: kind) else { return nil }
            return LocalACPRuntimeResolver.resolveExecutable(named: definition.underlyingCLIName ?? definition.commandName)
        }.value
    }
}
