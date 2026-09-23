import AppKit
import Foundation

// Only the model is substituted: the test compiles the production lifecycle delegate.
@MainActor
final class ApplicationModel {
    var isPreparedForExecutionRestart = false
    var flushCount = 0
    var cleanupCount = 0
    var cleanupFinished = false
    var remoteWorkspaces: ApplicationModel { self }
    func refreshRuntimeInventory() {}
    func refreshLocalACPRuntimesNow() {}
    func refreshRuntimeMaintenanceAtStartup() {}
    func flushNoteDrafts() { flushCount += 1 }
    func restoreOpenCodeInstances() async {}
    func shutdownLocalACPSessions() {}
    func flushNotesBeforeBackendClientQuit() async -> Bool { true }
    func prepareOpenCodeInstancesToQuit() async throws {
        cleanupCount += 1
        try await Task.sleep(for: .milliseconds(20))
        cleanupFinished = true
    }
}

@MainActor
private final class TerminationProbe: NSObject, NSApplicationDelegate {
    let model = ApplicationModel()
    let delegate = WovenMatterLifecycleDelegate()
    let resultURL: URL
    var deferredTermination = false

    init(resultURL: URL) {
        self.resultURL = resultURL
        super.init()
        delegate.model = model
        NotificationCenter.default.addObserver(self, selector: #selector(start),
            name: NSApplication.didFinishLaunchingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(finished),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc private func start(_ notification: Notification) {
        Task { @MainActor in
            try! await AppTerminationTests.verifyTransitionRecovery()
            try! await AppTerminationTests.verifyExecutionLeaseWait()
            WovenMatterLifecycleDelegate.requestTerminationAfterUpdate()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = delegate.applicationShouldTerminate(sender)
        // macOS logout/restart requests must be deferred, never cancelled.
        // A repeated request must also defer without starting duplicate cleanup.
        deferredTermination = reply == .terminateLater
            && delegate.applicationShouldTerminate(sender) == .terminateLater
        return reply
    }

    @objc private func finished(_ notification: Notification) {
        let passed = deferredTermination && model.flushCount == 1 && model.cleanupCount == 1 && model.cleanupFinished
        try! (passed ? "PASS\n" : "FAIL: termination cancelled, cleanup unfinished, or duplicate cleanup\n")
            .write(to: resultURL, atomically: true, encoding: .utf8)
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
    }

    @MainActor static func verifyTransitionRecovery() async throws {
        enum Failure: Error { case expected }
        let preparedModel = ApplicationModel()
        preparedModel.isPreparedForExecutionRestart = true
        let preparedDelegate = WovenMatterLifecycleDelegate()
        preparedDelegate.model = preparedModel
        precondition(preparedDelegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        precondition(preparedModel.flushCount == 0 && preparedModel.cleanupCount == 0)
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
        // Policy and login-job checks never register a job or enable the feature.
        let suite = "wovenmatter.background-policy-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(!LocalBackgroundExecution(defaults: defaults).isEnabled)
        precondition(LocalExecutionRole.resolve(arguments: [], backgroundEnabled: false) == .standalone)
        precondition(LocalExecutionRole.resolve(arguments: [], backgroundEnabled: true) == .frontend)
        precondition(LocalExecutionRole.resolve(arguments: ["--backend"], backgroundEnabled: false) == .backend)
        precondition(LocalExecutionRole.backend.leaseFileName == LocalExecutionRole.standalone.leaseFileName)
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
        // A separate queue catches the original main-actor deadlock too.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            try? "FAIL: shutdown timed out\n".write(to: resultURL, atomically: true, encoding: .utf8)
            _exit(70)
        }
        let application = NSApplication.shared
        let probe = TerminationProbe(resultURL: resultURL)
        application.delegate = probe
        application.setActivationPolicy(.prohibited)
        withExtendedLifetime(probe) { application.run() }
    }
}
