import Darwin
import Foundation

/// Headless helper mode of the app. The parent's heartbeat pipe is deliberately
/// not inherited by Tailscale. EOF on app quit/crash removes only our Serve watcher.
public enum CompanionServeSupervisor {
  public static let argument = "--companion-serve-supervisor"

  /// Called before the app opens its workspace. The helper and the normal app
  /// share one executable, so only this explicit launch argument enters service mode.
  public static func dispatch(arguments: [String]) -> Int32? {
    guard let index = arguments.dropFirst().firstIndex(of: argument) else { return nil }
    return run(arguments: Array(arguments.dropFirst(index + 1)))
  }

  public static func run(arguments: [String]) -> Int32 {
    guard let executable = arguments.first, executable.hasPrefix("/") else { return 64 }
    do {
      return try supervise(executable: URL(fileURLWithPath: executable), arguments: Array(arguments.dropFirst()), heartbeatDescriptor: STDIN_FILENO)
    } catch { return 1 }
  }

  static func supervise(executable: URL, arguments: [String], heartbeatDescriptor: Int32,
                        onStarted: @Sendable (Int32) -> Void = { _ in }) throws -> Int32 {
    let child = Process()
    child.executableURL = executable; child.arguments = arguments
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    onStarted(child.processIdentifier)
    var parentClosed = false
    while child.isRunning {
      var descriptor = pollfd(fd: heartbeatDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
      let result = Darwin.poll(&descriptor, 1, 100)
      if result < 0 && errno == EINTR { continue }
      if result < 0 || (result > 0 && descriptor.revents != 0) { parentClosed = true; break }
    }
    if child.isRunning {
      child.terminate()
      let deadline = ProcessInfo.processInfo.systemUptime + 1
      while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
      if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
    }
    child.waitUntilExit()
    return parentClosed ? 0 : child.terminationStatus
  }
}
