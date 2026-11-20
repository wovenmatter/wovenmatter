import AppKit

@MainActor
final class WovenMatterLifecycleDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false
    /// Closes the CEF browsers before quitting; false keeps the app open
    /// (a page's unload prompt was declined).
    var prepareBrowserTermination: (@MainActor () async -> Bool)?
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

    /// Waits for this pid to exit, then opens this app bundle again. Used after
    /// a macOS permission that only takes effect on relaunch.
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting, including Sparkle's install-on-quit, only closes the browsers
    /// first. Whatever the app started stops with it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
}
