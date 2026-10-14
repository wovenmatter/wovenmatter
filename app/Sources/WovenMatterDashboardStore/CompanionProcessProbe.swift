import Darwin
import Foundation
import WovenMatterCore

/// Bounded CLI inspection, including a child that stalls, ignores TERM, or leaves
/// stdout open in a descendant. Reads occur on a dedicated queue, never an actor.
final class CompanionProcessProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var child: Process?
  private var cancelled = false

  func run(executable: URL, arguments: [String], maximumBytes: Int = 2 * 1_024 * 1_024, timeout: TimeInterval = 10) async throws -> Data {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { [self] in
          do { continuation.resume(returning: try execute(executable: executable, arguments: arguments, maximumBytes: maximumBytes, timeout: timeout)) }
          catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: { self.cancel() }
  }

  private func cancel() {
    lock.withLock {
      cancelled = true
      if let child, child.isRunning { child.terminate() }
    }
  }

  private func execute(executable: URL, arguments: [String], maximumBytes: Int, timeout: TimeInterval) throws -> Data {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable; process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try lock.withLock {
      guard !cancelled else { throw CancellationError() }
      try process.run(); child = process
    }
    let handle = pipe.fileHandleForReading
    defer {
      try? handle.close()
      if process.isRunning {
        process.terminate()
        let limit = Date().addingTimeInterval(0.25)
        while process.isRunning && Date() < limit { usleep(10_000) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
      }
      process.waitUntilExit()
      lock.withLock { child = nil }
    }
    let descriptor = handle.fileDescriptor
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
    var output = Data()
    var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      guard !lock.withLock({ cancelled }) else { throw CancellationError() }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw CompanionAPIError(code: "probe_timeout", message: "Tailscale did not respond in time.")
      }
      var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      let ready = Darwin.poll(&descriptorState, 1, 100)
      if ready < 0 {
        if errno == EINTR { continue }
        throw POSIXError(.EIO)
      }
      if ready == 0 { continue }
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EAGAIN || errno == EINTR { continue }
        throw POSIXError(.EIO)
      }
      guard count <= maximumBytes - output.count else {
        throw CompanionAPIError(code: "probe_too_large", message: "Tailscale returned an oversized response.")
      }
      output.append(contentsOf: bytes.prefix(count))
    }
    // The read deadline also applies if a process closes stdout but keeps running.
    while process.isRunning {
      guard !lock.withLock({ cancelled }) else { throw CancellationError() }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw CompanionAPIError(code: "probe_timeout", message: "Tailscale did not finish in time.")
      }
      usleep(10_000)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw CompanionAPIError(code: "tailscale_unavailable", message: "Tailscale is unavailable. Check its connection on this Mac.")
    }
    return output
  }
}
