import AppKit
import Foundation

enum DevelopmentLaunch {
    enum Mode { case client, snapshot, live }
    static let mode: Mode? = nil
    static let isClient = false
    static let isLiveHost = false
    static let isSnapshot = false
}

@MainActor final class DesktopUpdater {
    static let shared = DesktopUpdater()
    var isInstalling = false
    var hasStagedUpdate = false
}
@MainActor enum WorkspaceAssetSession {
    static weak var model: ApplicationModel?
    static func prepareForRestart() async -> Bool {
        model?.recordWrite("assets")
        return true
    }
    static func cancelPreparedRestart() { model?.record("assets-cancel") }
}

private struct RestartRefused: LocalizedError {
    var errorDescription: String? { "The background service could not be restarted." }
}

// Only external application services are substituted: the test compiles the production lifecycle delegate.
// Each failure injection is one-shot, so a retry models Sparkle resending quit.
@MainActor
final class ApplicationModel {
    var isPreparedForExecutionRestart = false
    var isBackendFrontend = !CommandLine.arguments.contains("--standalone-update")
    var isLibraryClient = false
    var noteEditingSuspended = false
    func suspendNoteEditing() { noteEditingSuspended = true }
    func resumeNoteEditing() { noteEditingSuspended = false }
    /// Ordered lifecycle evidence. A write without a live backend is recorded
    /// under a distinct name rather than crashing before a result is written.
    var events: [String] = []
    var backendReady = !CommandLine.arguments.contains("--backend-already-stopped")
        && !CommandLine.arguments.contains("--backend-restart-fails")
    // The initial restart and the recovery restart are both refused.
    var restartRefusals = CommandLine.arguments.contains("--backend-restart-fails") ? 2 : 0
    var noteSaveFailures = CommandLine.arguments.contains("--note-save-fails") ? 1 : 0
    var browserCancellations = CommandLine.arguments.contains("--browser-cancels") ? 1 : 0
    var sessionShutdownCount = 0
    var remoteWorkspaces: ApplicationModel { self }

    func record(_ event: String) { events.append(event) }
    func recordWrite(_ event: String) { events.append(backendReady ? event : event + "-without-backend") }

    func ensureBackendReady() async throws {
        if backendReady { record("ready"); return }
        // Model the lease wait and readiness barrier; no write may overtake it.
        try await Task.sleep(for: .milliseconds(20))
        if restartRefusals > 0 {
            restartRefusals -= 1
            record("restart-refused")
            throw RestartRefused()
        }
        backendReady = true
        record("restart")
    }
    func prepareBackendForUpdate() async throws {
        suspendNoteEditing()
        guard await flushNotesBeforeBackendClientQuit() else { resumeNoteEditing(); throw CancellationError() }
        // Acknowledged application.stop, lease release and supervisor suspend.
        try await Task.sleep(for: .milliseconds(20))
        recordWrite("stop")
        backendReady = false
        isPreparedForExecutionRestart = true
    }
    func recoverBackendAfterFailedUpdate() async throws {
        record("recover")
        isPreparedForExecutionRestart = false
        defer { resumeNoteEditing() }
        try await ensureBackendReady()
    }
    func refreshRuntimeInventory() {}
    func refreshLocalACPRuntimesNow() {}
    func refreshRuntimeMaintenanceAtStartup() {}
    func restoreOpenCodeInstances() async {}
    func shutdownLocalACPSessions() { sessionShutdownCount += 1 }
    func prepareLibraryClientForQuit() async throws {}
    func flushNotesBeforeBackendClientQuit() async -> Bool {
        if noteSaveFailures > 0 {
            noteSaveFailures -= 1
            recordWrite("flush-failed")
            return false
        }
        recordWrite("flush")
        return true
    }
    func prepareOpenCodeInstancesToQuit() async throws {
        try await Task.sleep(for: .milliseconds(20))
        record("cleanup")
    }
}

/// Observes the delegate's real AppKit replies. A cancelled quit leaves the
/// app running; the retry is a fresh terminate, as Sparkle sends on retry.
private final class ProbeApplication: NSApplication {
    var replied: (@MainActor (Bool) -> Void)?

    override func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
        // Record first: an allowed reply terminates inside super.
        replied?(shouldTerminate)
        super.reply(toApplicationShouldTerminate: shouldTerminate)
    }
}

@MainActor
private final class TerminationProbe: NSObject, NSApplicationDelegate {
    let model = ApplicationModel()
    let delegate = WovenMatterLifecycleDelegate()
    let resultURL: URL
    var terminationRequests = 0
    var everyRequestDeferred = true

    init(resultURL: URL) {
        self.resultURL = resultURL
        DesktopUpdater.shared.isInstalling = (CommandLine.arguments.contains("--updater") || CommandLine.arguments.contains("--standalone-update"))
        DesktopUpdater.shared.hasStagedUpdate = CommandLine.arguments.contains("--staged-update")
        super.init()
        delegate.model = model
        WorkspaceAssetSession.model = model
        delegate.prepareBrowserTermination = { [model] in
            try? await Task.sleep(for: .milliseconds(30))
            if model.browserCancellations > 0 {
                model.browserCancellations -= 1
                model.record("browser-cancelled")
                return false
            }
            model.record("browser")
            return true
        }
        delegate.presentUpdatePreparationFailure = { [model] _ in model.record("alert") }
        NotificationCenter.default.addObserver(self, selector: #selector(start),
            name: NSApplication.didFinishLaunchingNotification, object: nil)
    }

    @objc private func start(_ notification: Notification) {
        if CommandLine.arguments.contains("--wait-for-stop") { return }
        Task { @MainActor in
            try! await AppTerminationTests.verifyTransitionRecovery()
            try! await AppTerminationTests.verifyExecutionLeaseWait()
            try! await AppTerminationTests.verifyReadinessBarrier()
            if DesktopUpdater.shared.hasStagedUpdate {
                // An ordinary Cmd-Q after extraction does not call willInstallUpdate.
                precondition(!DesktopUpdater.shared.isInstalling)
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
                }
            } else {
                WovenMatterLifecycleDelegate.requestTerminationAfterUpdate()
            }
        }
    }

    var isUpdateHandoff: Bool {
        (DesktopUpdater.shared.isInstalling || DesktopUpdater.shared.hasStagedUpdate) && model.isBackendFrontend
    }

    /// The exact production choreography, including one cancelled attempt
    /// and its retry for each injected failure.
    var expectedEvents: [String] {
        let arguments = CommandLine.arguments
        guard isUpdateHandoff else { return ["flush", "cleanup", "browser", "reply-true"] }
        let handoff = ["assets", "flush", "stop", "browser", "reply-true"]
        if arguments.contains("--backend-already-stopped") { return ["restart"] + handoff }
        if arguments.contains("--backend-restart-fails") {
            // Nothing flushes to a missing owner; recovery is refused too, and
            // the retried quit restores the owner before any write.
            return ["restart-refused", "assets-cancel", "recover", "restart-refused", "reply-false", "alert",
                    "restart"] + handoff
        }
        if arguments.contains("--note-save-fails") {
            // The owner was never stopped, so recovery keeps the healthy backend.
            return ["ready", "assets", "flush-failed", "assets-cancel", "recover", "ready", "reply-false", "alert",
                    "ready"] + handoff
        }
        if arguments.contains("--browser-cancels") {
            // The acknowledged stop already ran, so recovery restarts the owner.
            return ["ready", "assets", "flush", "stop", "browser-cancelled", "assets-cancel", "recover", "restart",
                    "reply-false", "ready"] + handoff
        }
        // Healthy fast path: no lease wait or restart.
        return ["ready"] + handoff
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        delegate.applicationShouldTerminateAfterLastWindowClosed(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        delegate.applicationWillTerminate(notification)
        let expected = expectedEvents
        var failures: [String] = []
        if model.events != expected {
            failures.append("events \(model.events), expected \(expected)")
        }
        if !everyRequestDeferred { failures.append("a termination request was not deferred") }
        if !CommandLine.arguments.contains("--wait-for-stop"),
           terminationRequests != expected.filter({ $0 == "reply-false" }).count + 1 {
            failures.append("\(terminationRequests) termination requests")
        }
        if model.sessionShutdownCount != 1 { failures.append("\(model.sessionShutdownCount) session shutdowns") }
        if !model.noteEditingSuspended { failures.append("note editing resumed during termination") }
        if model.isPreparedForExecutionRestart != isUpdateHandoff { failures.append("unexpected execution restart state") }
        if delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) {
            failures.append("closing the last window terminates")
        }
        try! (failures.isEmpty ? "PASS\n" : "FAIL: " + failures.joined(separator: "; ") + "\n")
            .write(to: resultURL, atomically: true, encoding: .utf8)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationRequests += 1
        let reply = delegate.applicationShouldTerminate(sender)
        // macOS logout/restart requests must be deferred, never cancelled.
        // A repeated request must also defer without starting duplicate cleanup.
        everyRequestDeferred = everyRequestDeferred && reply == .terminateLater
            && delegate.applicationShouldTerminate(sender) == .terminateLater
        return reply
    }
}

@main
private struct AppTerminationTests {
    @MainActor static func verifyStaleSocketRecovery() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/wm-backend-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = directory.appending(path: "control.sock")
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(endpoint.path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(bound == 0 && listen(listener, 1) == 0)
        do {
            try WovenMatterBackendProcess.removeStaleSocketAfterAcquiringLease(endpoint)
            preconditionFailure("Live backend socket was removed")
        } catch let error as POSIXError { precondition(error.code == .EADDRINUSE) }
        precondition(FileManager.default.fileExists(atPath: endpoint.path))
        close(listener)
        try WovenMatterBackendProcess.removeStaleSocketAfterAcquiringLease(endpoint)
        precondition(!FileManager.default.fileExists(atPath: endpoint.path))
        try Data("not a socket".utf8).write(to: endpoint)
        do {
            try WovenMatterBackendProcess.removeStaleSocketAfterAcquiringLease(endpoint)
            preconditionFailure("Non-socket endpoint was removed")
        } catch let error as POSIXError { precondition(error.code == .EPERM) }
    }

    @MainActor static func verifyExecutionLeaseWait() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = root.appending(path: "owner.lock")
        let ready = root.appending(path: "ready")
        let release = root.appending(path: "release")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--lease-probe", lease.path, ready.path, release.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(FileManager.default.fileExists(atPath: ready.path))
        var finished = false
        let waiter = Task { @MainActor in
            try await WovenMatterBackendProcess.waitForExecutionOwnerToExit(leaseURL: lease)
            finished = true
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(!finished, "The active POSIX lease must block handoff")
        try Data().write(to: release)
        try await waiter.value
        precondition(finished)
        child.waitUntilExit()
        precondition(child.terminationStatus == 0)
        try await WovenMatterBackendProcess.waitForExecutionOwnerToExit(leaseURL: root.appending(path: "never-started.lock"))
    }

    @MainActor static func verifyReadinessBarrier() async throws {
        var checks = 0
        var launches = 0
        // A slow but live owner must be waited for, never replaced or waited
        // on for lease release. This used to fail recovery after 10 seconds.
        try await WovenMatterBackendProcess.ensureReady(check: {
            checks += 1
            return checks == 3
        }, ownerIsPresent: { true }, launch: { launches += 1 })
        precondition(checks == 3 && launches == 0)
        checks = 0
        try await WovenMatterBackendProcess.ensureReady(check: {
            checks += 1
            return checks == 3
        }, ownerIsPresent: { false }, launch: { launches += 1 })
        precondition(checks == 3 && launches == 1)
        checks = 0
        launches = 0
        // An owner that exits while starting permits exactly one launch.
        try await WovenMatterBackendProcess.ensureReady(check: {
            checks += 1
            return checks == 4
        }, ownerIsPresent: { checks < 2 }, launch: { launches += 1 })
        precondition(launches == 1)
        do {
            try await WovenMatterBackendProcess.ensureReady(timeout: 0.05,
                check: { false }, ownerIsPresent: { true }, launch: { preconditionFailure("Replaced live owner") })
            preconditionFailure("Readiness wait did not time out")
        } catch { precondition((error as NSError).domain == "BackgroundExecution") }
        do {
            try await WovenMatterBackendProcess.ensureReady(check: { throw RestartRefused() },
                ownerIsPresent: { true }, launch: { preconditionFailure("Launched over startup failure") })
            preconditionFailure("Startup failure was hidden")
        } catch is RestartRefused { }
    }

    @MainActor static func verifyTransitionRecovery() async throws {
        enum Failure: Error { case expected }
        let preparedModel = ApplicationModel()
        preparedModel.isPreparedForExecutionRestart = true
        let preparedDelegate = WovenMatterLifecycleDelegate()
        preparedDelegate.model = preparedModel
        precondition(preparedDelegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        precondition(preparedModel.events.isEmpty)
        for failingStep in ["prepare", "commit", "relaunch"] {
            var events: [String] = []
            do {
                try await LocalExecutionTransition.perform(prepare: {
                    events.append("prepare")
                    if failingStep == "prepare" { throw Failure.expected }
                }, commit: {
                    events.append("commit")
                    if failingStep == "commit" { throw Failure.expected }
                }, relaunch: {
                    events.append("relaunch")
                    if failingStep == "relaunch" { throw Failure.expected }
                }, rollback: { events.append("rollback") }, recover: { events.append("recover") })
                preconditionFailure("Expected transition failure")
            } catch Failure.expected {}
            precondition(events.last == "recover")
            precondition(events.contains("rollback") == (failingStep == "relaunch"))
        }
        let started = Date()
        do {
            _ = try LocalBackendSupervisor.runCommand(executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"], timeout: 0.05)
            preconditionFailure("Expected supervised command timeout")
        } catch { precondition(Date().timeIntervalSince(started) < 2) }

        var commands: [[String]] = []
        var loaded = false
        let supervisor = LocalBackendSupervisor(domain: "gui/999999", label: "wovenmatter.tests.fake",
            plistURL: URL(fileURLWithPath: "/private/tmp/not-installed.plist")) { arguments in
                commands.append(arguments)
                if arguments.first == "print" { return loaded ? 0 : 113 }
                if arguments.first == "bootstrap" { loaded = true }
                if arguments.first == "bootout" { loaded = false }
                return 0
            }
        try supervisor.start()
        precondition(commands.map { $0[0] } == ["print", "bootstrap", "kickstart"])
        commands = []
        try supervisor.start()
        precondition(commands.map { $0[0] } == ["print", "kickstart"])
        precondition(!commands.contains { $0.contains("-k") })
        commands = []
        try supervisor.suspend()
        precondition(commands.map { $0[0] } == ["print", "bootout"] && !loaded)
        commands = []
        try supervisor.start()
        precondition(commands.map { $0[0] } == ["print", "bootstrap", "kickstart"] && loaded)
        let failing = LocalBackendSupervisor(domain: "gui/999999", label: "wovenmatter.tests.fake",
            plistURL: URL(fileURLWithPath: "/private/tmp/not-installed.plist")) { _ in 113 }
        do { try failing.start(); preconditionFailure("Expected bootstrap failure") } catch { }

        var events: [String] = []
        try await LocalExecutionTransition.perform(prepare: { events.append("prepare") },
            commit: { events.append("commit") }, relaunch: { events.append("relaunch") },
            rollback: { events.append("rollback") }, recover: { events.append("recover") })
        precondition(events == ["prepare", "commit", "relaunch"])
    }

    @MainActor static func main() {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--headless-probe" {
            let ready = URL(fileURLWithPath: CommandLine.arguments[2])
            let stopped = URL(fileURLWithPath: CommandLine.arguments[3])
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { _exit(70) }
            precondition(NSApp == nil)
            WovenMatterBackendProcess.run(start: {
                Task { @MainActor in
                    // Use the same discovery API as Sparkle after async work.
                    try! await Task.sleep(for: .milliseconds(50))
                    precondition(NSApp == nil)
                    let matches = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
                    precondition(!matches.contains { $0.processIdentifier == getpid() }, "Service registered as GUI")
                    try! String(getpid()).write(to: ready, atomically: true, encoding: .utf8)
                }
            }, terminate: {
                precondition(NSApp == nil)
                try! "PASS".write(to: stopped, atomically: true, encoding: .utf8)
                WovenMatterBackendProcess.stop()
                return true
            })
            precondition(NSApp == nil)
            return
        }
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--lease-probe" {
            let descriptor = Darwin.open(CommandLine.arguments[2], O_CREAT | O_RDWR, 0o600)
            precondition(descriptor >= 0 && Darwin.lockf(descriptor, F_TLOCK, 0) == 0)
            try! Data().write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            for _ in 0..<500 where !FileManager.default.fileExists(atPath: CommandLine.arguments[4]) {
                Thread.sleep(forTimeInterval: 0.01)
            }
            Darwin.close(descriptor)
            return
        }
        try! verifyStaleSocketRecovery()
        // Policy and login-job checks never register a job.
        precondition(LocalBackgroundExecution(developmentMode: nil).isEnabled)
        for mode in [DevelopmentLaunch.Mode.client, .snapshot, .live] {
            precondition(!LocalBackgroundExecution(developmentMode: mode).isEnabled)
        }
        precondition(LocalExecutionRole.resolve(arguments: []) == .frontend)
        precondition(!LocalExecutionRole.frontend.ownsExecution)
        precondition(LocalExecutionRole.resolve(arguments: ["--backend"]) == .backend)
        precondition(LocalExecutionRole.resolve(arguments: [], libraryClientEnabled: true) == .libraryClient)
        precondition(!LocalExecutionRole.libraryClient.ownsExecution)
        precondition(LocalExecutionRole.libraryClient.leaseFileName != LocalExecutionRole.developmentHost.leaseFileName)
        precondition(LocalExecutionRole.resolve(arguments: ["--backend"], libraryClientEnabled: true) == .backend)
        precondition(LocalExecutionRole.backend.leaseFileName == LocalExecutionRole.developmentHost.leaseFileName)
        precondition(LocalExecutionRole.frontend.leaseFileName != LocalExecutionRole.backend.leaseFileName)
        let endpoint = LocalExecutionRole.backendSocketURL(workspaceDirectory: URL(fileURLWithPath: "/private/tmp/" + String(repeating: "long", count: 100)))
        precondition(endpoint.path.utf8.count < 104)
        precondition(endpoint == LocalExecutionRole.backendSocketURL(workspaceDirectory: URL(fileURLWithPath: "/private/tmp/" + String(repeating: "long", count: 100))))
        let job = LocalBackgroundExecution.launchAgentPropertyList(
            bundleURL: URL(fileURLWithPath: "/Applications/Woven Matter.app"),
            executableURL: URL(fileURLWithPath: "/Applications/Woven Matter.app/Contents/MacOS/WovenMatter"),
            identifier: "wovenmatter.test")
        precondition(job["RunAtLoad"] as? Bool == true)
        precondition(job["ProgramArguments"] as? [String] == ["/Applications/Woven Matter.app/Contents/MacOS/WovenMatter", "--backend"])
        precondition((job["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        precondition(job["ThrottleInterval"] as? Int == 5)
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[1])
        // A separate queue catches the original main-actor deadlock and any
        // cancelled quit that is never retried or never replies.
        DispatchQueue.global().asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--wait-for-stop") ? 30 : 5)) {
            try? "FAIL: shutdown timed out\n".write(to: resultURL, atomically: true, encoding: .utf8)
            _exit(70)
        }
        // Created before any other NSApplication.shared access, so AppKit uses it.
        let application = ProbeApplication.shared as! ProbeApplication
        let probe = TerminationProbe(resultURL: resultURL)
        application.replied = { [model = probe.model] allowed in
            model.record("reply-\(allowed)")
            // Default mode only: the retry waits until AppKit leaves the modal
            // deferred-termination loop, as a later Sparkle quit would.
            if !allowed {
                RunLoop.main.perform(inModes: [.default]) {
                    MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
                }
            }
        }
        application.delegate = probe
        application.setActivationPolicy(CommandLine.arguments.contains("--wait-for-stop") ? .accessory : .prohibited)
        withExtendedLifetime(probe) { application.run() }
    }
}
