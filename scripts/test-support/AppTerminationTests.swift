import AppKit
import Foundation

// Only the model is substituted: the test compiles the production lifecycle delegate.
@MainActor
final class ApplicationModel {
    var flushCount = 0
    var cleanupCount = 0
    var cleanupFinished = false
    var remoteWorkspaces: ApplicationModel { self }
    func refreshRuntimeInventory() {}
    func refreshLocalACPRuntimesNow() {}
    func refreshRuntimeMaintenanceAtStartup() {}
    func flushNoteDrafts() { flushCount += 1 }
    func restoreOpenCodeInstances() async {}
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
    @MainActor static func main() {
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
