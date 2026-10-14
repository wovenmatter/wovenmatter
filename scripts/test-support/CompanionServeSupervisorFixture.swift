import Darwin
import Foundation

// Compiled together with the production supervisor by CompanionTransportTests.
// This executable has no app initialization, workspace, Tailscale, or provider access.
@main
enum CompanionServeSupervisorFixture {
  static func main() throws {
    if let status = CompanionServeSupervisor.dispatch(arguments: CommandLine.arguments) {
      if let report = ProcessInfo.processInfo.environment["WOVEN_FIXTURE_REAP_REPORT"],
         let pidFile = ProcessInfo.processInfo.environment["WOVEN_FIXTURE_CHILD_PID_FILE"],
         let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
         let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        var childStatus: Int32 = 0
        let result = waitpid(pid, &childStatus, WNOHANG)
        try "\(result):\(errno)".write(toFile: report, atomically: true, encoding: .utf8)
      }
      Darwin.exit(status)
    }
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "--fixture-exit":
      Darwin.exit(Int32(arguments[1])!)
    case "--fixture-resistant-child", "--fixture-cooperative-child":
      if arguments[0] == "--fixture-resistant-child" { signal(SIGTERM, SIG_IGN) }
      try String(getpid()).write(toFile: arguments[1], atomically: true, encoding: .utf8)
      while true { pause() }
    case "--fixture-crashing-parent":
      let executable = URL(fileURLWithPath: CommandLine.arguments[0])
      let heartbeat = Pipe()
      _ = fcntl(heartbeat.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
      let helper = Process()
      helper.executableURL = executable
      helper.arguments = [CompanionServeSupervisor.argument, executable.path,
                          "--fixture-resistant-child", arguments[2]]
      helper.standardInput = heartbeat
      helper.standardOutput = FileHandle.nullDevice
      helper.standardError = FileHandle.nullDevice
      try helper.run()
      try heartbeat.fileHandleForReading.close()
      try String(helper.processIdentifier).write(toFile: arguments[1], atomically: true, encoding: .utf8)
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      while !FileManager.default.fileExists(atPath: arguments[2]) && ProcessInfo.processInfo.systemUptime < deadline {
        usleep(10_000)
      }
      guard FileManager.default.fileExists(atPath: arguments[2]) else { Darwin.exit(74) }
      // No Swift deinit/terminate handler can run: the kernel must close the pipe.
      withExtendedLifetime(heartbeat) { _ = kill(getpid(), SIGKILL) }
      Darwin.exit(75)
    default:
      Darwin.exit(73)
    }
  }
}
