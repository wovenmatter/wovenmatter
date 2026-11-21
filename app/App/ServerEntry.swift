import Foundation
import Synchronization
import WovenServerKit

/// The app's own signed program run as this Mac's background server
/// (`--server DATA-FOLDER …`). It runs `WovenServerKit` and nothing of the UI,
/// so the permissions macOS grants Woven Matter cover the server and every
/// process it starts. This is the only file in the app that imports the server.
enum ServerEntry {
    static let argument = "--server"

    static func run(_ arguments: [String]) -> Never {
        // The harness catalog, Pi Durable and the bots runtime ship inside the
        // app, with the Node that runs them.
        if let resources = Bundle.main.resourcePath {
            setenv("WOVEN_RESOURCES", resources, 0)
            setenv("WOVEN_NODE", resources + "/default-agent/bin/node", 0)
        }
        let replaced = ReplacedApp(started: installedVersion())
        Task.detached {
            do {
                // The status `run` returns: a machine another one removed exits
                // with `removedStatus`, and launchd, which restarts the server only
                // after a crash, leaves it stopped.
                let status = try await ServerCommand.run(arguments)
                if status == 0, let version = replaced.version { restart(arguments, onto: version) }
                exit(status)
            } catch {
                FileHandle.standardError.write(Data("woven-server: \(error)\n".utf8))
                exit(2)
            }
        }
        dispatchMain()
    }

    /// The release of the app on disk now, which an update replaces under the running server.
    private static func installedVersion() -> String? {
        let plist = Bundle.main.bundleURL.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// Notices an update replacing the app, then stops the server as SIGTERM does,
    /// so `run` can start the new program in this process.
    private final class ReplacedApp: Sendable {
        private let found = Mutex<String?>(nil)
        var version: String? { found.withLock { $0 } }

        init(started: String?) {
            guard let started else { return }
            Task.detached { [self] in
                while true {
                    try? await Task.sleep(for: .seconds(30))
                    guard let now = ServerEntry.installedVersion(), now != started else { continue }
                    found.withLock { $0 = now }
                    kill(getpid(), SIGTERM)
                    return
                }
            }
        }
    }

    /// Replaces this process with the updated app's program, same arguments and
    /// its new release, under the same launchd job.
    private static func restart(_ arguments: [String], onto version: String) {
        guard let program = Bundle.main.executableURL?.path else { return }
        var argv = [program, argument] + arguments
        if let index = argv.firstIndex(of: "--app-version"), index + 1 < argv.count { argv[index + 1] = version }
        let pointers = argv.map { strdup($0) } + [nil]
        execv(program, pointers)
    }
}
