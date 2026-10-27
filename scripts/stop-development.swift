import AppKit
import Foundation

// Use AppKit's normal quit request so pending writes and active execution can
// refuse a rebuild. Never force-terminate, and never identify an app by name.
let target = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
func isFrontend(_ application: NSRunningApplication) -> Bool {
    guard !application.isTerminated, application.activationPolicy != .prohibited,
          application.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == target else { return false }
    // A new headless process can briefly appear regular before AppKit applies
    // its activation policy. Check its role before counting or terminating it.
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(application.processIdentifier), "-o", "args="]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let command = String(data: data, encoding: .utf8) else { return false }
    let arguments = command.split(whereSeparator: \.isWhitespace)
    return !arguments.contains("--backend") && !arguments.contains("--companion-serve-supervisor")
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
// The headless server shares this executable but has its own lifetime.
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
