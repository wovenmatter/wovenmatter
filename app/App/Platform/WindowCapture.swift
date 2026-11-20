#if DEBUG
import AppKit

/// Debug builds only: `--capture-windows FOLDER` writes a PNG of each visible
/// window to FOLDER five seconds after launch and again on every SIGUSR1, so
/// a build can be checked without Screen Recording permission.
@MainActor
enum WindowCapture {
    private static var folder: URL?
    private static var count = 0
    private static var signalSource: (any DispatchSourceSignal)?

    static func startIfRequested() {
        let arguments = CommandLine.arguments
        guard folder == nil, let index = arguments.firstIndex(of: "--capture-windows"), index + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { capture() } }
        source.resume()
        signalSource = source
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { capture() } }
    }

    /// `--settings-page agents`, `accounts` or `piDurable` opens that Settings page
    /// once this Mac's server has answered, so a capture can show it.
    static func openRequestedSettings(_ model: ApplicationModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--settings-page"), index + 1 < arguments.count else { return }
        let page = arguments[index + 1]
        Task { @MainActor in
            while model.thisMachineID == nil { try? await Task.sleep(for: .milliseconds(200)) }
            if page == "piDurable" { model.navigation.pendingDefaultAgentSettingsScope = "global"; return }
            model.navigation.pendingConnectionsScope = page == "accounts" ? model.thisMachineID : page
        }
    }

    /// Writes every visible window as NN-title.png.
    static func capture(_ label: String? = nil) {
        guard let folder else { return }
        count += 1
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let title = (label ?? (window.title.isEmpty ? "window-\(index)" : window.title))
                .replacingOccurrences(of: "/", with: "-")
            let url = folder.appending(path: String(format: "%02d-%d-%@.png", count, index, title))
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#endif
