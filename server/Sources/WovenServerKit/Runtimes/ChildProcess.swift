import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A runtime's process, talking newline-delimited text over stdio. It leads
/// its own process group, so stopping it also stops whatever it started.
final class ChildProcess: Sendable {
  /// Lines from its standard output, until it exits.
  let lines: AsyncStream<String>
  let pid: Int32
  private let process: Process
  private let input: FileHandle
  private let writes = DispatchQueue(label: "woven.child.write")

  /// The longest line accepted from a runtime.
  static let maximumLine = 64 << 20

  /// Starts `executable` with `arguments` in `directory`. `environment` is
  /// added to this process's own environment.
  init(executable: String, arguments: [String], directory: String, environment: [String: String],
       logFile: URL? = nil) throws {
    let process = Process()
    // Foundation cannot put a child in its own process group; a shell that
    // turns on job control and then execs the command can.
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", #"ulimit -c 0; set -m; exec "$@""#, "woven-runtime", executable] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = ChildProcess.searchPath(env["PATH"])
    for (key, value) in environment { env[key] = value }
    process.environment = env
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    if let logFile {
      FileManager.default.createFile(atPath: logFile.path, contents: nil)
      process.standardError = (try? FileHandle(forWritingTo: logFile)) ?? FileHandle.nullDevice
    } else {
      process.standardError = FileHandle.nullDevice
    }
    try process.run()
    self.process = process
    self.pid = process.processIdentifier
    self.input = stdin.fileHandleForWriting
    let (lines, continuation) = AsyncStream<String>.makeStream()
    self.lines = lines
    let output = stdout.fileHandleForReading
    Thread.detachNewThread {
      var buffer = Data()
      while true {
        let chunk = output.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: 10) {
          let line = buffer[buffer.startIndex..<end]
          buffer.removeSubrange(buffer.startIndex...end)
          if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
        }
        if buffer.count > ChildProcess.maximumLine { break }
      }
      continuation.finish()
    }
  }

  /// Writes one line to its standard input.
  func send(_ line: String) {
    let data = Data((line + "\n").utf8)
    let input = input
    writes.async { try? input.write(contentsOf: data) }
  }

  var isRunning: Bool { process.isRunning }

  /// Ends the process group: closes stdin, then SIGTERM, then SIGKILL after
  /// a grace period.
  func stop(grace: Duration = .seconds(2)) async {
    let input = input
    writes.sync { try? input.close() }
    let pid = pid
    guard process.isRunning else { return }
    if killpg(pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
    let deadline = ContinuousClock.now + grace
    while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    if process.isRunning {
      if killpg(pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
    }
  }

  /// PATH with the places runtimes install themselves added, since a server
  /// started by the app has only the system's.
  static func searchPath(_ path: String?) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var parts = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
    for extra in ["\(home)/.local/bin", "\(home)/.grok/bin", "\(home)/.opencode/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    where !parts.contains(extra) {
      parts.append(extra)
    }
    return parts.joined(separator: ":")
  }

  /// The first executable named `name` on the search path.
  static func find(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
    if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
    for directory in searchPath(path).split(separator: ":") {
      let candidate = "\(directory)/\(name)"
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  /// Runs a command to completion and returns its exit status and output.
  static func run(_ executable: String, _ arguments: [String], directory: String? = nil,
                  environment: [String: String] = [:], timeout: Duration = .seconds(60)) async -> (status: Int32, output: String) {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath(env["PATH"])
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
          continuation.resume(returning: (-1, String(describing: error)))
          return
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let seconds = Double(timeout.components.seconds)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        continuation.resume(returning: (process.terminationStatus, String(decoding: data.suffix(65536), as: UTF8.self)))
      }
    }
  }

  /// Runs a shell command line.
  static func shell(_ command: String, timeout: Duration = .seconds(60)) async -> (status: Int32, output: String) {
    await run("/bin/sh", ["-c", command], timeout: timeout)
  }
}
