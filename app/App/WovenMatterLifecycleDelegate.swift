import AppKit

@MainActor
final class WovenMatterLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var model: ApplicationModel?
    private var terminating = false
    private var terminationApproved = false

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.refreshRuntimeInventory()
        model?.refreshLocalACPRuntimesNow()
        model?.remoteWorkspaces.refreshRuntimeMaintenanceAtStartup()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationApproved, let model else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        model.flushNoteDrafts()
        Task {
            do {
                try await model.prepareOpenCodeInstancesToQuit()
                terminationApproved = true
                sender.terminate(nil)
            } catch {
                let alert = NSAlert()
                alert.messageText = "OpenCode could not be stopped"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Cancel quit")
                alert.addButton(withTitle: "Quit anyway")
                let quit = alert.runModal() == .alertSecondButtonReturn
                if quit {
                    terminationApproved = true
                    sender.terminate(nil)
                } else {
                    await model.restoreOpenCodeInstances()
                    terminating = false
                }
            }
        }
        // Let the initiating main-actor task return before cleanup runs.
        // terminateLater spins a nested AppKit loop that can starve this Task.
        return .terminateCancel
    }
}
