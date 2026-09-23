import AppKit
import Observation
import CryptoKit

@MainActor
final class WovenMatterLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var model: ApplicationModel?
    private var terminating = false
    static func requestTerminationAfterUpdate() {
        // AppKit's deferred termination enters a nested run loop. Leave the
        // initiating Swift task first so it cannot block main-actor cleanup.
        // DispatchQueue.main.async would still hold the main dispatch queue.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard LocalExecutionRole.current.ownsExecution else { return true }
        model?.refreshRuntimeInventory()
        model?.refreshLocalACPRuntimesNow()
        model?.remoteWorkspaces.refreshRuntimeMaintenanceAtStartup()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // The explicit handoff already flushed notes and stopped the execution
        // owner. Do not issue a second flush to a backend that has exited.
        if model.isPreparedForExecutionRestart { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        if LocalExecutionRole.current == .frontend {
            Task {
                let flushed = await model.flushNotesBeforeBackendClientQuit()
                if !flushed { terminating = false }
                sender.reply(toApplicationShouldTerminate: flushed)
            }
            return .terminateLater
        }
        model.flushNoteDrafts()
        Task {
            do {
                try await model.prepareOpenCodeInstancesToQuit()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                if LocalExecutionRole.current == .backend {
                    NSLog("Woven Matter backend cleanup failed: %@", error.localizedDescription)
                    sender.reply(toApplicationShouldTerminate: true)
                    return
                }
                let alert = NSAlert()
                alert.messageText = "OpenCode could not be stopped"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Cancel quit")
                alert.addButton(withTitle: "Quit anyway")
                let quit = alert.runModal() == .alertSecondButtonReturn
                terminating = false
                sender.reply(toApplicationShouldTerminate: quit)
                if !quit { await model.restoreOpenCodeInstances() }
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        if LocalExecutionRole.current == .backend {
            model?.flushNoteDrafts()
            model?.shutdownLocalACPSessions()
        }
    }

}


/// Desired mode is committed only as part of an explicit, validated restart.
/// The running frontend never changes execution ownership in place.
@MainActor @Observable
final class LocalBackgroundExecution {
    static let shared = LocalBackgroundExecution()
    nonisolated static let preferenceKey = "localBackgroundExecutionEnabled"
    private(set) var isEnabled: Bool
    var pendingEnabled: Bool?
    private(set) var isChanging = false
    private(set) var errorMessage: String?
    var transitionHandler: ((Bool) async throws -> Void)?
    var isAvailable: Bool { transitionHandler != nil }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.preferenceKey)
    }

    static func launchAgentPropertyList(bundleURL: URL, executableURL: URL, identifier: String) -> [String: Any] {
        ["Label": identifier + ".background",
         "ProgramArguments": [executableURL.path, "--backend"],
         "RunAtLoad": true,
         "KeepAlive": ["SuccessfulExit": false],
         "ThrottleInterval": 5,
         "LimitLoadToSessionType": "Aqua",
         "ProcessType": "Background",
         "WorkingDirectory": bundleURL.deletingLastPathComponent().path]
    }

    func setEnabled(_ enabled: Bool) {
        pendingEnabled = enabled == isEnabled ? nil : enabled
        errorMessage = nil
    }

    func applyPendingChange() async {
        guard let enabled = pendingEnabled, !isChanging else { return }
        guard let transitionHandler else {
            errorMessage = "Background execution is not ready. Please reopen Woven Matter and try again."
            return
        }
        isChanging = true
        defer { isChanging = false }
        do {
            // Handler validates idle state and owns safe execution-owner handoff.
            // It calls commitEnabled only after shutdown can safely proceed.
            try await transitionHandler(enabled)
            pendingEnabled = nil
            errorMessage = nil
        } catch {
            errorMessage = "Background execution could not be changed: " + error.localizedDescription
        }
    }

    static func launchBackendProcess() async throws { try await WovenMatterBackendProcess.launch() }
    static func relaunchAfterCurrentProcessExits() throws { try WovenMatterBackendProcess.relaunchAfterCurrentProcessExits() }

    func commitEnabled(_ enabled: Bool) throws {
        guard let identifier = Bundle.main.bundleIdentifier,
              let executable = Bundle.main.executableURL else {
            throw NSError(domain: "BackgroundExecution", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The installed app could not be located."])
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")
        let url = directory.appending(path: identifier + ".background.plist")
        if enabled {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: Self.launchAgentPropertyList(
                bundleURL: Bundle.main.bundleURL, executableURL: executable, identifier: identifier),
                format: .xml, options: 0)
            // Set permissions on the temporary file before replacing the login
            // job, so a failed write cannot partially commit the desired mode.
            let temporary = directory.appending(path: "." + UUID().uuidString + ".plist")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            // Handoff has already stopped the idle backend. Unload its job so a
            // later crash/restart cannot revive execution after opting out.
            try LocalBackendSupervisor.current().suspend()
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        defaults.set(enabled, forKey: Self.preferenceKey)
        isEnabled = enabled
    }
}


/// launchd owns the process from the first opt-in restart, not just the next
/// login. Successful shutdown stays stopped; unexpected exits are restarted.
/// Tests inject a command runner and never register a real login job.
struct LocalBackendSupervisor {
    let domain: String
    let label: String
    let plistURL: URL
    let run: ([String]) throws -> Int32

    var service: String { domain + "/" + label }

    static func current() throws -> Self {
        guard let identifier = Bundle.main.bundleIdentifier else {
            throw NSError(domain: "BackgroundExecution", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The installed app could not be located."])
        }
        return .init(domain: "gui/\(getuid())", label: identifier + ".background",
            plistURL: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/LaunchAgents/" + identifier + ".background.plist"), run: runLaunchctl)
    }

    func start() throws {
        if try run(["print", service]) != 0 {
            try checked(["bootstrap", domain, plistURL.path])
        }
        // No -k: opening the UI must never restart an already-running backend.
        try checked(["kickstart", service])
    }

    func suspend() throws {
        guard try run(["print", service]) == 0 else { return }
        try checked(["bootout", service])
    }

    private func checked(_ arguments: [String]) throws {
        let status = try run(arguments)
        guard status == 0 else {
            throw NSError(domain: "BackgroundExecution", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "The background service could not be "
                    + (arguments.first == "bootout" ? "unloaded" : "started")
                    + " (launchctl \(status))."
            ])
        }
    }

    private static func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        try runCommand(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments, timeout: 10)
    }

    static func runCommand(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Int32 {
        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
            throw NSError(domain: "BackgroundExecution", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "The background service manager did not respond. Try again."])
        }
        return process.terminationStatus
    }
}

/// A failed restart must restore the prior mode and execution owner. Dependencies
/// are injected so failure paths can be tested without changing login jobs.
@MainActor
enum LocalExecutionTransition {
    static func perform(prepare: () async throws -> Void,
                        commit: () throws -> Void,
                        relaunch: () throws -> Void,
                        rollback: () throws -> Void,
                        recover: () async throws -> Void) async throws {
        var committed = false
        do {
            try await prepare()
            try commit()
            committed = true
            try relaunch()
        } catch {
            let original = error
            var failures: [String] = []
            if committed {
                do { try rollback() } catch { failures.append(error.localizedDescription) }
            }
            do { try await recover() } catch { failures.append(error.localizedDescription) }
            if failures.isEmpty { throw original }
            throw NSError(domain: "BackgroundExecution", code: 3, userInfo: [
                NSLocalizedDescriptionKey: original.localizedDescription + " Recovery failed: " + failures.joined(separator: "; ")
            ])
        }
    }
}

/// Captured once at startup; changing the preference cannot change a running
/// process's ownership role. Standalone and backend share the execution lease.
enum LocalExecutionRole: String {
    case standalone, frontend, backend

    static let current = resolve(arguments: CommandLine.arguments,
        backgroundEnabled: UserDefaults.standard.bool(forKey: LocalBackgroundExecution.preferenceKey))

    static func resolve(arguments: [String], backgroundEnabled: Bool) -> Self {
        if arguments.contains("--backend") { return .backend }
        return backgroundEnabled ? .frontend : .standalone
    }

    var ownsExecution: Bool { self != .frontend }
    var leaseFileName: String { self == .frontend ? "frontend-owner.lock" : "workspace-owner.lock" }

    static func backendSocketURL(workspaceDirectory: URL) -> URL {
        // sun_path is only 104 bytes on macOS. A workspace/variant path may be
        // longer; a stable digest keeps the private endpoint within that limit.
        let digest = SHA256.hash(data: Data(workspaceDirectory.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/private/tmp/wovenmatter-backend-\(getuid())-\(digest)/control.sock")
    }
}

/// Headless process entry point, used only after an execution controller is
/// supplied. No WindowGroup, view model mirror or frontend work is created here.
@MainActor
enum WovenMatterBackendProcess {
    /// Call only after holding the execution lease. Never unlink a live socket,
    /// another user's endpoint, a symlink, or an unexpected file.
    static func removeStaleSocketAfterAcquiringLease(_ url: URL) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_uid == getuid(), (metadata.st_mode & S_IFMT) == S_IFSOCK else {
            throw POSIXError(.EPERM)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let failure = errno
        guard result != 0, failure == ECONNREFUSED else { throw POSIXError(.EADDRINUSE) }
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func waitForExecutionOwnerToExit(leaseURL: URL) async throws {
        let descriptor = Darwin.open(leaseURL.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        for _ in 0..<100 {
            try Task.checkCancellation()
            // WorkspaceProcessLease uses POSIX record locks, not BSD flock.
            // F_TEST observes the existing owner without acquiring ownership.
            if Darwin.lockf(descriptor, F_TEST, 0) == 0 { return }
            guard errno == EACCES || errno == EAGAIN else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "BackgroundExecution", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "The background service is still stopping. Try again shortly."])
    }

    static func launch() async throws {
        guard LocalBackgroundExecution.shared.isEnabled else {
            throw NSError(domain: "BackgroundExecution", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Background execution is disabled on this Mac."])
        }
        // Refresh the literal executable path if this app variant was moved or
        // replaced. Bundle-specific labels keep development and production apart.
        try LocalBackgroundExecution.shared.commitEnabled(true)
        try await Task.detached(priority: .userInitiated) {
            try LocalBackendSupervisor.current().start()
        }.value
    }

    /// The shell only waits for this pid and opens the literal bundle argument.
    /// No user text is interpolated into shell source; no backend is killed here.
    static func relaunchAfterCurrentProcessExits() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"", "wovenmatter-relaunch",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func run(delegate: NSApplicationDelegate, start: () throws -> Void) throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.delegate = delegate
        try start()
        withExtendedLifetime(delegate) { application.run() }
    }
}
