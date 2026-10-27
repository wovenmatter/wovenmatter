import AppKit
import Foundation

// Use AppKit's normal quit request so pending writes and active execution can
// refuse a rebuild. Never force-terminate, and never identify an app by name.
let target = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
if CommandLine.arguments.contains("--wait") {
    let deadline = Date().addingTimeInterval(20)
    var firstSeen: Date?
    while Date() < deadline {
        let running = NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && $0.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == target
        }
        if running {
            if firstSeen == nil { firstSeen = Date() }
            if Date().timeIntervalSince(firstSeen!) >= 2 { exit(0) }
        } else if firstSeen != nil {
            fputs("The development app exited during startup.\n", stderr)
            exit(1)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    fputs("The development app did not stay open at the expected executable path.\n", stderr)
    exit(1)
}
let applications = NSWorkspace.shared.runningApplications.filter {
    $0.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == target
}
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
