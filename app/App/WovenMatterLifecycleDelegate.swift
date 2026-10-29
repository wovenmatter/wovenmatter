import AppKit
import Observation
import CryptoKit

@MainActor
final class WovenMatterLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var model: ApplicationModel?
    private var terminating = false
    var prepareBrowserTermination: (@MainActor () async -> Bool)?
    /// Shown after the update quit has been cancelled; tests record it instead.
    var presentUpdatePreparationFailure: @MainActor (any Error) -> Void = { error in
        let alert = NSAlert()
        alert.messageText = "Woven Matter could not prepare to update"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    private var menuCleanupScheduled = false

    override init() {
        super.init()
        // Workspace/browser tabs are app content, not macOS tabbed windows.
        NSWindow.allowsAutomaticWindowTabbing = false
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSMenu.didBeginTrackingNotification,
                     NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            center.addObserver(self, selector: #selector(scheduleMenuCleanup(_:)), name: name, object: nil)
        }
    }

    @objc private func scheduleMenuCleanup(_ notification: Notification) {
        guard !menuCleanupScheduled else { return }
        menuCleanupScheduled = true
        // Finish the framework's current menu mutation before applying policy.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.menuCleanupScheduled = false
                self?.applicationDidUpdate(Notification(name: NSApplication.didUpdateNotification))
            }
        }
    }

    func applicationDidUpdate(_ notification: Notification) {
        for window in NSApp.windows where window.tabbingMode != .disallowed {
            window.tabbingMode = .disallowed
        }
        // SwiftUI leaves empty system-menu placeholders that macOS augments
        // later. Remove them before export, and put our custom File menu in the
        // standard position. Its own command set stays limited to workspace actions.
        guard let menu = NSApp.mainMenu else { return }
        let fileTitle = String(localized: "File")
        // File can be briefly empty while SwiftUI installs its custom commands.
        for item in menu.items where item.title != fileTitle && item.submenu?.items.isEmpty == true {
            menu.removeItem(item)
        }
        if let file = menu.items.first(where: { $0.title == fileTitle }),
           menu.index(of: file) != 1 {
            menu.removeItem(file)
            menu.insertItem(file, at: min(1, menu.numberOfItems))
        }
    }

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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        // The explicit handoff already flushed notes and stopped the execution
        // owner. Do not issue a second flush to a backend that has exited.
        if model.isPreparedForExecutionRestart {
            guard let prepareBrowserTermination else { return .terminateNow }
            guard !terminating else { return .terminateLater }
            terminating = true
            Task {
                let allowed = await prepareBrowserTermination()
                if !allowed { terminating = false }
                sender.reply(toApplicationShouldTerminate: allowed)
            }
            return .terminateLater
        }
        if (DesktopUpdater.shared.isInstalling || DesktopUpdater.shared.hasStagedUpdate) && model.isBackendFrontend {
            guard !terminating else { return .terminateLater }
            terminating = true
            Task {
                do {
                    // Restore a ready owner before flushing editors or drafts,
                    // including recovery from a legacy AppKit-backed service.
                    try await model.ensureBackendReady()
                    guard await WorkspaceAssetSession.prepareForRestart() else {
                        terminating = false
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    try await model.prepareBackendForUpdate()
                    let allowed = await prepareBrowserTermination?() ?? true
                    if !allowed {
                        WorkspaceAssetSession.cancelPreparedRestart()
                        try await model.recoverBackendAfterFailedUpdate()
                        terminating = false
                    }
                    sender.reply(toApplicationShouldTerminate: allowed)
                } catch {
                    WorkspaceAssetSession.cancelPreparedRestart()
                    try? await model.recoverBackendAfterFailedUpdate()
                    terminating = false
                    sender.reply(toApplicationShouldTerminate: false)
                    presentUpdatePreparationFailure(error)
                }
            }
            return .terminateLater
        }
        guard !terminating else { return .terminateLater }
        terminating = true
        model.suspendNoteEditing()
        if LocalExecutionRole.current == .frontend || model.isLibraryClient {
            Task {
                var flushed = await model.flushNotesBeforeBackendClientQuit()
                if flushed {
                    do { try await model.prepareLibraryClientForQuit() }
                    catch {
                        flushed = false
                        let alert = NSAlert()
                        alert.messageText = "Finish local work before quitting"
                        alert.informativeText = error.localizedDescription
                        alert.addButton(withTitle: "Keep Woven Matter open")
                        alert.runModal()
                    }
                }
                if !flushed { terminating = false; model.resumeNoteEditing() }
                if flushed { await finishTermination(sender) }
                else { sender.reply(toApplicationShouldTerminate: false) }
            }
            return .terminateLater
        }
        Task {
            guard await model.flushNotesBeforeBackendClientQuit() else {
                terminating = false
                model.resumeNoteEditing()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            do {
                try await model.prepareOpenCodeInstancesToQuit()
                await finishTermination(sender)
            } catch {
                if LocalExecutionRole.current == .backend {
                    NSLog("Woven Matter backend cleanup failed: %@", error.localizedDescription)
                    await finishTermination(sender)
                    return
                }
                let alert = NSAlert()
                alert.messageText = "OpenCode could not be stopped"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Cancel quit")
                alert.addButton(withTitle: "Quit anyway")
                let quit = alert.runModal() == .alertSecondButtonReturn
                if quit {
                    await finishTermination(sender)
                } else {
                    terminating = false
                    model.resumeNoteEditing()
                    sender.reply(toApplicationShouldTerminate: false)
                    await model.restoreOpenCodeInstances()
                }
            }
        }
        return .terminateLater
    }
    private func finishTermination(_ sender: NSApplication) async {
        let allowed = await prepareBrowserTermination?() ?? true
        if !allowed {
            terminating = false
            model?.resumeNoteEditing()
            if LocalExecutionRole.current.ownsExecution { await model?.restoreOpenCodeInstances() }
        }
        sender.reply(toApplicationShouldTerminate: allowed)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if LocalExecutionRole.current.ownsExecution {
            // The asynchronous termination barrier already flushed note drafts.
            model?.shutdownLocalACPSessions()
        }
    }

}


/// Production execution always belongs to the background server.
/// Changes to the running mode are committed only through a validated restart.
/// The running frontend never changes execution ownership in place.
@MainActor @Observable
final class LocalBackgroundExecution {
    static let shared = LocalBackgroundExecution()
    private(set) var isEnabled: Bool

    init(developmentMode: DevelopmentLaunch.Mode? = DevelopmentLaunch.mode) {
        // Development profiles run separate processes without installing a login job.
        isEnabled = developmentMode == nil
    }

    static func launchAgentPropertyList(bundleURL: URL, executableURL: URL, identifier: String) -> [String: Any] {
        ["Label": identifier + ".background",
         "ProgramArguments": [executableURL.path, "--backend"],
         "RunAtLoad": true,
         "KeepAlive": ["SuccessfulExit": false],
         "ThrottleInterval": 5,
         "ExitTimeOut": 60,
         "LimitLoadToSessionType": "Aqua",
         "ProcessType": "Background",
         "WorkingDirectory": bundleURL.deletingLastPathComponent().path]
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
        isEnabled = enabled
    }
}


/// launchd owns the process from the first background launch, not just the next
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

/// Captured once at startup; a running process keeps its ownership role.
/// Isolated test hosts and the backend share the execution lease name.
enum LocalExecutionRole: String {
    case developmentHost, frontend, backend, libraryClient

    nonisolated static let libraryClientPreferenceKey = "wovenmatter.library.client-mode"
    #if COMPANION_FACADE_TESTS
    // Test processes own explicitly injected, isolated stores and never connect
    // to or install the user's production server.
    static let current: LocalExecutionRole = .developmentHost
    #else
    static let current: LocalExecutionRole = resolve(arguments: CommandLine.arguments,
        libraryClientEnabled: UserDefaults.standard.bool(forKey: libraryClientPreferenceKey),
        developmentMode: DevelopmentLaunch.mode)
    #endif

    static func resolve(arguments: [String], libraryClientEnabled: Bool = false,
                        developmentMode: DevelopmentLaunch.Mode? = nil) -> Self {
        if developmentMode != nil {
            return arguments.contains("--backend") ? .backend : .frontend
        }
        if arguments.contains("--backend") { return .backend }
        if libraryClientEnabled { return .libraryClient }
        return .frontend
    }

    var ownsExecution: Bool { self == .developmentHost || self == .backend }
    var leaseFileName: String {
        switch self {
        case .frontend: "frontend-owner.lock"
        case .libraryClient: "library-client-owner.lock"
        case .developmentHost, .backend: "workspace-owner.lock"
        }
    }

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
    private static var running = false
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

    /// Observe the lease without creating a file, claiming it, or launching work.
    static func executionOwnerIsPresent(leaseURL: URL) throws -> Bool {
        let descriptor = Darwin.open(leaseURL.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
              (metadata.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EPERM) }
        if Darwin.lockf(descriptor, F_TEST, 0) == 0 { return false }
        guard errno == EACCES || errno == EAGAIN else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return true
    }

    static func waitForExecutionOwnerToExit(leaseURL: URL) async throws {
        let descriptor = Darwin.open(leaseURL.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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

    /// Startup and recovery share one bounded readiness barrier. An owner that
    /// is still starting keeps its lease; waiting for that lease to disappear
    /// would turn a slow start into a failed recovery.
    static func ensureReady(timeout: TimeInterval = 60,
                            check: () async throws -> Bool,
                            ownerIsPresent: () throws -> Bool,
                            launch: () async throws -> Void) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var launched = false
        repeat {
            try Task.checkCancellation()
            if try await check() { return }
            if !launched, try !ownerIsPresent() {
                try await launch()
                launched = true
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw NSError(domain: "BackgroundExecution", code: 6, userInfo: [
            NSLocalizedDescriptionKey: "The background service did not become ready. Try reopening Woven Matter."
        ])
    }

    static func launch() async throws {
        if DevelopmentLaunch.mode != nil {
            guard let executable = Bundle.main.executableURL else {
                throw NSError(domain: "BackgroundExecution", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The development executable is unavailable."])
            }
            // All development profiles use the same server protocol and ownership
            // boundary, but never register a production or development login job.
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--backend"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return
        }
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

    /// Keep the main actor and Foundation services running without registering
    /// an NSApplication. Using even a prohibited AppKit app gives Sparkle and
    /// LaunchServices another instance of the frontend's bundle to quit/open.
    static func run(start: () -> Void, terminate: @escaping @MainActor () async -> Bool) {
        precondition(!running)
        running = true
        var context = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)!
        CFRunLoopAddSource(CFRunLoopGetMain(), keepAlive, .defaultMode)
        var terminating = false
        let signals = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                guard !terminating else { return }
                terminating = true
                Task { @MainActor in
                    // A maintenance operation can temporarily refuse shutdown.
                    // Fence new requests as soon as the shared stop path admits it.
                    while !(await terminate()) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            source.resume()
            return source
        }
        start()
        withExtendedLifetime(signals) {
            while running {
                // NSApplication normally supplies the autorelease pools. A
                // Foundation service must drain its own during a long lifetime.
                _ = autoreleasepool { CFRunLoopRunInMode(.defaultMode, 1, false) }
            }
        }
        for source in signals { source.cancel() }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), keepAlive, .defaultMode)
    }

    static func stop() {
        // Leave the initiating main-actor task before ending its run loop.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                running = false
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
    }
}
