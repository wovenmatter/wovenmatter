import Foundation
import Synchronization
import WovenProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The bots runtime's process, as the host supervises it.
protocol BotsRuntimeProcess: Sendable {
  /// Returns once the process has exited, or when the waiting task is cancelled.
  func exited() async
  /// Ends the process: SIGTERM, then SIGKILL after a grace period.
  func stop() async
}

/// How the home machine runs the bots: its container engine and how the
/// runtime is started. Tests give a stand-in for both.
struct BotsHosting: Sendable {
  /// The engine for a data folder and, on Linux, a development instance's own engine.
  var engine: @Sendable (_ dataFolder: URL, _ instance: String?) -> any BotsEngine
  /// Starts the runtime with its config file, logging to `log`.
  var launch: @Sendable (_ config: URL, _ log: URL) throws -> any BotsRuntimeProcess
  /// Writes each bot's files out of the engine and back, for a transfer.
  var files: BotsFiles = .node
  /// Called once a transfer's target has begun to make itself the home,
  /// before it writes the setting. Tests pause here.
  var committing: @Sendable () async -> Void = {}

  static let standard = BotsHosting(engine: { standardBotsEngine(dataFolder: $0, instance: $1) },
                                    launch: { try NodeBotsRuntime(config: $0, log: $1) })
}

/// `D/bots-runtime/config.json`, as the runtime reads it (strictly).
struct BotsRuntimeConfig: Encodable, Equatable {
  struct Engine: Encodable, Equatable {
    var socket: String
    var kind: String
  }

  struct Image: Encodable, Equatable {
    var tag: String
  }

  struct Limits: Encodable, Equatable {
    var botMemoryBytes: Int64?

    private enum Key: String, CodingKey { case botMemoryBytes }

    // No cap is an explicit null.
    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: Key.self)
      try container.encode(botMemoryBytes, forKey: .botMemoryBytes)
    }
  }

  struct PiDurable: Encodable, Equatable {
    var bundle: String
    var directory: String
  }

  var dataDir: String
  var socket: String
  var engine: Engine
  var image: Image
  var limits: Limits
  var piDurable: PiDurable

  /// Writes the file, readable only by this user, replacing the old one in one step.
  func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let partial = url.appendingPathExtension("partial")
    FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
    try encoder.encode(self).write(to: partial)
    guard rename(partial.path, url.path) == 0 else { throw RuntimeError.failed("Could not save \(url.path).") }
  }
}

/// `node <Resources>/bots/src/cli.ts serve --config …`, in its own process
/// group, with its output appended to the log.
final class NodeBotsRuntime: BotsRuntimeProcess {
  private let process = Process()
  private let state = ExitState()

  init(config: URL, log: URL) throws {
    guard let node = Resources.node else { throw RuntimeError.failed("The bots need Node, which is not on this machine.") }
    let entry = Resources.root.appendingPathComponent("bots/src/cli.ts")
    guard FileManager.default.fileExists(atPath: entry.path) else {
      throw RuntimeError.failed("The bots runtime is missing from \(entry.deletingLastPathComponent().path).")
    }
    // A log past 10 MB starts again.
    if let size = (try? FileManager.default.attributesOfItem(atPath: log.path))?[.size] as? Int, size > 10 << 20 {
      try? FileManager.default.removeItem(at: log)
    }
    let descriptor = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard descriptor >= 0 else { throw RuntimeError.failed("Could not open \(log.path).") }
    let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    // Its own process group, so stopping it stops whatever it started.
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", #"ulimit -c 0; set -m; exec "$@""#, "woven-bots", node, entry.path, "serve", "--config", config.path]
    process.currentDirectoryURL = config.deletingLastPathComponent()
    // Only what Node needs: the server's own environment may hold keys.
    let environment = ProcessInfo.processInfo.environment
    process.environment = [
      "PATH": ChildProcess.searchPath(environment["PATH"]),
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "TMPDIR": NSTemporaryDirectory(),
      "LANG": "en_US.UTF-8",
      "NODE_ENV": "production",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    let state = state
    process.terminationHandler = { _ in
      let waiters = state.value.withLock { state in
        state.done = true
        defer { state.waiters.removeAll() }
        return Array(state.waiters.values)
      }
      for waiter in waiters { waiter.resume() }
    }
    try process.run()
  }

  func exited() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let done = state.value.withLock { state in
          if state.done || Task.isCancelled { return true }
          state.waiters[id] = continuation
          return false
        }
        if done { continuation.resume() }
      }
    } onCancel: {
      state.value.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
    }
  }

  func stop() async {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    if killpg(pid, SIGTERM) != 0 { kill(pid, SIGTERM) }
    // Waits out the grace period even when the caller is being cancelled.
    let process = process
    await Task.detached {
      let deadline = ContinuousClock.now + .seconds(5)
      while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
      if process.isRunning, killpg(pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
    }.value
  }
}

/// Whether a process has exited, and who waits for it.
private final class ExitState: Sendable {
  let value = Mutex<(done: Bool, waiters: [UUID: CheckedContinuation<Void, Never>])>((false, [:]))
}
