import AppKit

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
        model?.refreshRuntimeInventory()
        model?.refreshLocalACPRuntimesNow()
        model?.remoteWorkspaces.refreshRuntimeMaintenanceAtStartup()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdownLocalACPSessions()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        model.flushNoteDrafts()
        Task {
            do {
                try await model.prepareOpenCodeInstancesToQuit()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
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
}
