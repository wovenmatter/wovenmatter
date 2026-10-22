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
    private(set) var updating = false
    private(set) var resolvingInstaller = false
    private(set) var signInStatuses: [AgentRuntimeKind: AgentSignInStatus] = [:]
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
                for kind in HarnessOnboarding.runtimes {
                    try Task.checkCancellation()
                    try await application.requestSetupRuntimeCommand(.checkUpdate(kind))
                }
                try await waitForMaintenance()
                await refreshSignIns()
            } catch is CancellationError { }
            catch { notice = "Could not finish checking this Mac. Choose Check again to retry." }
        }
    }

    func refreshSignIns() async {
        await withTaskGroup(of: (AgentRuntimeKind, AgentSignInStatus).self) { group in
            for kind in HarnessOnboarding.runtimes {
                let inventory = application.runtimeInventories[kind]
                let executable = inventory?.components.first(where: { $0.name.hasSuffix("(sign-in CLI)") })?.executable
                    ?? (LocalACPRuntimeCatalog.definition(for: kind)?.underlyingCLIName == nil
                        ? inventory?.components.first?.executable : nil)
                group.addTask { (kind, await HarnessOnboarding.checkSignIn(kind, executable: executable)) }
            }
            for await (kind, status) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                signInStatuses[kind] = status
            }
        }
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
                    if kind == .opencode {
                        guard let openCode = application.openCode else { throw RuntimeMaintenanceError.unavailable }
                        try await openCode.download()
                        try await application.requestSetupRuntimeCommand(.checkUpdate(kind))
                    } else {
                        try await application.requestSetupRuntimeCommand(.install(kind))
                    }
                    try await waitForMaintenance()
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

    func update(_ kind: AgentRuntimeKind) {
        guard !busy, !maintenanceBusy, !application.localRuntimeMaintenanceHasActiveConversation else { return }
        activeInstall = kind
        updating = true
        errors[kind] = nil
        work = Task {
            defer { activeInstall = nil; updating = false }
            do {
                if kind == .opencode {
                    guard let openCode = application.openCode else { throw RuntimeMaintenanceError.unavailable }
                    try await openCode.download()
                    try await application.requestSetupRuntimeCommand(.checkUpdate(kind))
                } else {
                    try await application.requestSetupRuntimeCommand(.update(kind))
                }
                try await waitForMaintenance()
                await refreshSignIns()
            } catch is CancellationError { }
            catch { errors[kind] = "The update could not finish. Try again later." }
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

    private func waitForMaintenance() async throws {
        let deadline = Date().addingTimeInterval(15 * 60)
        while maintenanceBusy {
            try Task.checkCancellation()
            guard Date() < deadline else { throw RuntimeMaintenanceError.timeout }
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
    }
}

extension ApplicationModel {
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
