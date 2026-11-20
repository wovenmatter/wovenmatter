import Foundation
import WovenServerKit

/// The app's own signed program run as this Mac's background server
/// (`--server DATA-FOLDER …`). It runs `WovenServerKit` and nothing of the UI,
/// so the permissions macOS grants Woven Matter cover the server and every
/// process it starts. This is the only file in the app that imports the server.
enum ServerEntry {
    static let argument = "--server"

    static func run(_ arguments: [String]) -> Never {
        // The harness catalog and Pi Durable ship inside the app.
        if let resources = Bundle.main.resourcePath { setenv("WOVEN_RESOURCES", resources, 0) }
        Task.detached {
            do {
                // The status `run` returns: a machine another one removed exits
                // with `removedStatus`, and launchd, which restarts the server only
                // after a crash, leaves it stopped.
                exit(try await ServerCommand.run(arguments))
            } catch {
                FileHandle.standardError.write(Data("woven-server: \(error)\n".utf8))
                exit(2)
            }
        }
        dispatchMain()
    }
}
