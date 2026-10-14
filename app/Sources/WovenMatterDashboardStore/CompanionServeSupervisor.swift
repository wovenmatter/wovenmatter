import Darwin
import Dispatch
import Foundation

/// Headless helper mode of the app. The parent's heartbeat pipe is deliberately
/// not inherited by Tailscale. EOF or helper termination reaps only our Serve child.
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
    // Dev relaunches and process managers can signal the helper directly, not
    // only close the parent's heartbeat. Handle that before spawning the child
    // so a terminated helper cannot leave an orphan holding the HTTPS route.
    let terminationPipe = Pipe()
    let terminationWriter = terminationPipe.fileHandleForWriting
    _ = fcntl(terminationWriter.fileDescriptor, F_SETFD, FD_CLOEXEC)
    _ = fcntl(terminationWriter.fileDescriptor, F_SETFL, O_NONBLOCK)
    let handledSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
    // A caught handler resets on exec; SIG_IGN would instead make cooperative
    // children inherit ignored termination signals. Dispatch handles the event
    // off the signal stack and wakes the synchronous supervisor through a pipe.
    let previousHandlers = handledSignals.map { ($0, Darwin.signal($0, { _ in })) }
    let sources = handledSignals.map { number -> any DispatchSourceSignal in
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
      source.setEventHandler { try? terminationWriter.write(contentsOf: Data([1])) }
      source.resume()
      return source
    }
    defer {
      for source in sources { source.cancel() }
      for (number, handler) in previousHandlers { _ = Darwin.signal(number, handler) }
      try? terminationPipe.fileHandleForReading.close()
      try? terminationWriter.close()
    }
    let child = Process()
    child.executableURL = executable; child.arguments = arguments
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    onStarted(child.processIdentifier)
    var parentClosed = false
    while child.isRunning {
      var descriptors = [heartbeatDescriptor, terminationPipe.fileHandleForReading.fileDescriptor].map {
        pollfd(fd: $0, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
      }
      let result = descriptors.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, nfds_t($0.count), 100) }
      if result < 0 && errno == EINTR { continue }
      if result < 0 || (result > 0 && descriptors.contains(where: { $0.revents != 0 })) { parentClosed = true; break }
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
