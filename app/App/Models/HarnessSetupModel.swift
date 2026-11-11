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
/// Authentication starts only when the user presses a Sign in button. Codex, Claude
/// Code, and Grok Build sign in inside the app; OpenCode's own picker runs in Terminal.
@MainActor @Observable
final class HarnessSignInModel {
    private(set) var statuses: [AgentRuntimeKind: AgentSignInStatus] = [:]
    private(set) var checking: Set<AgentRuntimeKind> = []
    private(set) var opening: Set<AgentRuntimeKind> = []
    private(set) var removing: Set<AgentRuntimeKind> = []
    private(set) var messages: [AgentRuntimeKind: String] = [:]
    private(set) var sessions: [AgentRuntimeKind: HarnessSignInSession] = [:]
    private var awaitingReturn: Set<AgentRuntimeKind> = []

    /// Starts the harness's own sign-in command and shows its link and code here. A key
    /// method sends `key` on standard input and closes it, as `--with-api-key` expects.
    func start(_ kind: AgentRuntimeKind, method: HarnessSignInFlow.Method, key: String? = nil) {
        guard sessions[kind]?.isActive != true else { return }
        messages[kind] = nil
        let session = HarnessSignInSession(kind: kind, method: method)
        sessions[kind] = session
        Task {
            guard let executable = await Self.executable(kind) else {
                session.fail("\(kind.displayName) isn't installed on this Mac.")
                return
            }
            let searchPath = await Task.detached { LocalACPRuntimeResolver.executableSearchPath }.value
            let environment = ProcessInfo.processInfo.environment.merging(["PATH": searchPath]) { _, new in new }
            session.run(executable: executable, environment: environment, key: key) { [weak self] succeeded in
                await self?.finish(session, exitedCleanly: succeeded)
            }
        }
    }

    func submit(_ kind: AgentRuntimeKind, code: String) { sessions[kind]?.send(code) }
    func cancel(_ kind: AgentRuntimeKind) { sessions[kind]?.cancel() }
    func dismiss(_ kind: AgentRuntimeKind) { if sessions[kind]?.isActive == false { sessions[kind] = nil } }

    private func finish(_ session: HarnessSignInSession, exitedCleanly: Bool) async {
        guard exitedCleanly else { return }
        await refresh(session.kind)
        if ["verified", "credentials_present"].contains(statuses[session.kind]?.state ?? "") {
            awaitingReturn.insert(session.kind)
            session.succeed()
        } else {
            session.fail("Sign-in finished, but \(session.kind.displayName) didn't confirm an account. Try again.")
        }
    }

    /// Signs the harness out on this Mac with its own logout command.
    func signOut(_ kind: AgentRuntimeKind) async {
        guard let arguments = HarnessSignInFlow.signOutArguments(kind) else { return }
        await runRemoval(kind, arguments: arguments)
    }

    /// Removes one saved OpenCode credential, by its integration and label.
    func remove(_ account: AgentSignInStatus.Account) async {
        guard let target = account.target, let credential = account.credential else { return }
        await runRemoval(.opencode, arguments: HarnessSignInFlow.openCodeRemoveArguments(target: target, credential: credential))
    }

    private func runRemoval(_ kind: AgentRuntimeKind, arguments: [String]) async {
        guard removing.insert(kind).inserted else { return }
        defer { removing.remove(kind) }
        messages[kind] = nil
        sessions[kind] = nil
        guard let executable = await Self.executable(kind) else { return }
        let succeeded = await HarnessSignInFlow.runSignOut(executable: executable, arguments: arguments)
        await refresh(kind)
        if !succeeded { messages[kind] = "Couldn't remove the account. Check that \(kind.displayName) is installed, then try again." }
    }

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

    /// OpenCode only: its interactive `auth login` picks an integration and stores a key.
    func signIn(_ kind: AgentRuntimeKind) {
        guard kind == .opencode, opening.insert(kind).inserted else { return }
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

    nonisolated static func executable(_ kind: AgentRuntimeKind) async -> URL? {
        await Task.detached(priority: .utility) {
            guard let definition = LocalACPRuntimeCatalog.definition(for: kind) else { return nil }
            return LocalACPRuntimeResolver.resolveExecutable(named: definition.underlyingCLIName ?? definition.commandName)
        }.value
    }
}

/// One in-app sign-in on this Mac: the harness's own command, with the link and code it
/// prints shown in Settings. The harness stores its credentials; Woven Matter never reads them.
@MainActor @Observable
final class HarnessSignInSession {
    enum State: Equatable { case starting, waiting, succeeded, failed, cancelled }

    let kind: AgentRuntimeKind
    let method: HarnessSignInFlow.Method
    private(set) var state: State = .starting
    private(set) var url: URL?
    private(set) var code: String?
    private(set) var error: String?
    private(set) var sentCode = false
    private var output = ""
    private var process: Process?
    private var input: FileHandle?
    private var deadline: Task<Void, Never>?
    private var cancelRequested = false
    private var timedOut = false

    static let timeout: Duration = .seconds(30 * 60)

    init(kind: AgentRuntimeKind, method: HarnessSignInFlow.Method) {
        self.kind = kind
        self.method = method
    }

    var isActive: Bool { state == .starting || state == .waiting }

    /// While no link has appeared, the command's last lines, so a prompt or problem the
    /// parser doesn't recognize is still visible.
    var outputTail: String? {
        guard url == nil, state == .waiting else { return nil }
        let lines = HarnessSignInFlow.sanitized(output).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.suffix(4).joined(separator: "\n")
    }

    var message: String {
        switch state {
        case .starting: "Preparing sign-in…"
        case .waiting:
            if case .keyBeforeStart = method.input { "Saving your key…" }
            else if url != nil && code != nil { "Open the sign-in page and enter the one-time code." }
            else if url != nil { "Finish signing in to \(kind.displayName) in your browser." }
            else { "Preparing sign-in…" }
        case .succeeded: "Signed in to \(kind.displayName)."
        case .failed: error ?? "Sign-in didn't finish. Try again."
        case .cancelled: "Sign-in cancelled."
        }
    }

    func run(executable: URL, environment: [String: String], key: String?,
             onExit: @escaping @MainActor (Bool) async -> Void) {
        guard state == .starting, !cancelRequested else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = method.arguments
        process.environment = environment
        let stdinPipe = Pipe(), outputPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                outputPipe.fileHandleForReading.readabilityHandler = nil
                self.deadline?.cancel()
                self.process = nil
                self.input = nil
                if self.cancelRequested {
                    self.state = .cancelled
                } else if self.timedOut {
                    self.fail("Sign-in timed out. Try again.")
                } else if status != 0 {
                    self.fail("Sign-in didn't finish. Try again, or check that \(self.kind.displayName) can reach its service.")
                } else {
                    await onExit(true)
                }
            }
        }
        do {
            try process.run()
        } catch {
            fail("Couldn't start \(kind.displayName) sign-in. Check that it is installed, then try again.")
            return
        }
        self.process = process
        input = stdinPipe.fileHandleForWriting
        state = .waiting
        if let key {
            try? input?.write(contentsOf: Data((key.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
            try? input?.close()
            input = nil
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard let self, !Task.isCancelled, self.isActive else { return }
            self.timedOut = true
            self.stop()
        }
    }

    /// Sends a code from the sign-in page, as the command asks for it.
    func send(_ value: String) {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == .waiting, !code.isEmpty, code.count <= 8_192, !code.contains(where: \.isNewline),
              let input else { return }
        do {
            try input.write(contentsOf: Data((code + "\n").utf8))
            sentCode = true
        } catch {
            fail("Couldn't send the code. Try signing in again.")
            stop()
        }
    }

    func cancel() {
        guard isActive else { return }
        cancelRequested = true
        if process == nil { state = .cancelled } else { stop() }
    }

    func succeed() { state = .succeeded; error = nil }

    func fail(_ message: String) {
        error = message
        state = .failed
    }

    private func append(_ text: String) {
        guard isActive else { return }
        output = String((output + text).suffix(65_536))
        let found = HarnessSignInFlow.artifacts(output)
        if url == nil, let link = found.url { url = link }
        if code == nil, let value = found.code { code = value }
    }

    private func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task {
            try? await Task.sleep(for: .milliseconds(1_500))
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
