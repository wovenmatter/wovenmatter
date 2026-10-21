import AppKit
import Foundation

// Use AppKit's normal quit request so pending writes and active execution can
// refuse a rebuild. Never force-terminate, and never identify an app by name.
let target = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let applications = NSWorkspace.shared.runningApplications.filter { $0.executableURL?.standardizedFileURL == target }
if CommandLine.arguments.contains("--check") { exit(applications.isEmpty ? 1 : 0) }
for application in applications {
    guard application.terminate() else {
        fputs("The development instance refused to quit. Finish its active work before rebuilding.\n", stderr)
        exit(75)
    }
}
for _ in 0..<100 {
    if applications.allSatisfy(\.isTerminated) { exit(0) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
fputs("The development instance is still open. Finish its active work before rebuilding.\n", stderr)
exit(75)
