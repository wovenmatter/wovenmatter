import AppKit
import Foundation

// Use AppKit's normal quit request so pending writes and active execution can
// refuse a rebuild. Never force-terminate, and never identify an app by name.
let target = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
/// The instance's server is the same program run with `--server`. macOS can
/// list it as an application too; it never answers a quit request, and
/// stopping it is the caller's next step, not this script's.
func isServer(_ pid: pid_t) -> Bool {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "args=", "-p", String(pid)]
    let output = Pipe()
    ps.standardOutput = output
    ps.standardError = FileHandle.nullDevice
    guard (try? ps.run()) != nil else { return false }
    let arguments = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ps.waitUntilExit()
    return arguments.contains(" --server ")
}
func isFrontend(_ application: NSRunningApplication) -> Bool {
    guard !application.isTerminated, application.activationPolicy != .prohibited,
          application.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == target,
          !isServer(application.processIdentifier) else { return false }
    return true
}
if CommandLine.arguments.contains("--wait") {
    let deadline = Date().addingTimeInterval(20)
    var firstSeen: Date?
    while Date() < deadline {
        let running = NSWorkspace.shared.runningApplications.contains(where: isFrontend)
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
let applications = NSWorkspace.shared.runningApplications.filter(isFrontend)
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
