import Darwin
import Foundation
import WovenMatterClient

private enum OpenClawLocalGatewayLifecycleError: LocalizedError {
  case processExited
  case startupTimedOut

  var errorDescription: String? {
    switch self {
    case .processExited: "OpenClaw Gateway exited before opening its listener."
    case .startupTimedOut: "OpenClaw Gateway did not open its listener within 15 seconds."
    }
  }
}

actor OpenClawLocalGatewayLifecycle {
  struct OwnedProcess: Sendable {
    let isRunning: @Sendable () -> Bool
    let terminate: @Sendable () -> Void
    var waitForExit: @Sendable () async -> Void = {}
    var exitStatus: @Sendable () -> Int32? = { nil }
    var startupOutput: @Sendable () -> String = { "" }
  }
  typealias Launcher = @Sendable (LocalACPRuntimeLaunchConfiguration, URL) throws -> OwnedProcess
  private struct Entry {
    let process: OwnedProcess
    var agents: Set<UUID>
    let port: Int
    let generation: UUID
    var ready = false
  }
  private struct Pending {
    let generation: UUID
    let task: Task<Int, any Error>
    var waiters: Set<UUID>
  }
  private struct Retirement {
    let id: UUID
    let task: Task<Void, Never>
  }
  private var retiring: [String: Retirement] = [:]
  private let launchProcess: Launcher
  private let isReady: @Sendable (Int) -> Bool
  private let pause: @Sendable () async throws -> Void
  private var entries: [String: Entry] = [:]
  private var pending: [String: Pending] = [:]
  private var keysByAgent: [UUID: String] = [:]
  private var isShutDown = false

  init(
    launchProcess: @escaping Launcher = OpenClawLocalGatewayLifecycle.launch,
    isReady: @escaping @Sendable (Int) -> Bool = OpenClawLocalGatewayLifecycle.portAcceptsConnections,
    pause: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(100))
    }
  ) {
    self.launchProcess = launchProcess
    self.isReady = isReady
    self.pause = pause
  }

  static func stablePort(for identity: String) -> Int {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in identity.utf8 {
      hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return 20_000 + Int(hash % 20_000)
  }

  func ensure(
    agentID: UUID,
    identity: String,
    launch: LocalACPRuntimeLaunchConfiguration,
    workingDirectory: URL,
    configuredPort: Int? = nil,
    reuseExistingListener: Bool = false
  ) async throws -> Int {
    try Task.checkCancellation()
    guard !isShutDown else { throw CancellationError() }
    await waitForRetirement(identity: identity)
    try Task.checkCancellation()
    guard !isShutDown else { throw CancellationError() }
    let waiter = UUID()
    let start: Pending
    if var existing = pending[identity] {
      existing.waiters.insert(waiter)
      pending[identity] = existing
      start = existing
    } else if var entry = entries[identity], entry.process.isRunning(), isReady(entry.port) {
      entry.agents.insert(agentID)
      entries[identity] = entry
      keysByAgent[agentID] = identity
      return entry.port
    } else {
      let generation = UUID()
      let task = Task { try await self.start(identity: identity, generation: generation,
                                            launch: launch, workingDirectory: workingDirectory,
                                            configuredPort: configuredPort, reuseExistingListener: reuseExistingListener) }
      start = Pending(generation: generation, task: task, waiters: [waiter])
      pending[identity] = start
    }
    return try await withTaskCancellationHandler {
      do {
        let port = try await start.task.value
        try Task.checkCancellation()
        guard !isShutDown, entries[identity]?.generation == start.generation else {
          throw CancellationError()
        }
        entries[identity]?.agents.insert(agentID)
        keysByAgent[agentID] = identity
        finishWaiting(identity: identity, generation: start.generation, waiter: waiter)
        return port
      } catch {
        finishWaiting(identity: identity, generation: start.generation, waiter: waiter)
        throw error
      }
    } onCancel: {
      Task { await self.finishWaiting(identity: identity, generation: start.generation, waiter: waiter) }
    }
  }

  private func finishWaiting(identity: String, generation: UUID, waiter: UUID) {
    guard var current = pending[identity], current.generation == generation else { return }
    current.waiters.remove(waiter)
    if current.waiters.isEmpty {
      pending.removeValue(forKey: identity)
      current.task.cancel()
      if let entry = entries[identity], entry.generation == generation, entry.agents.isEmpty {
        retire(entry.process, identity: identity)
        entries.removeValue(forKey: identity)
      }
    } else { pending[identity] = current }
  }

  private func start(identity: String, generation: UUID,
                     launch: LocalACPRuntimeLaunchConfiguration, workingDirectory: URL,
                     configuredPort: Int?, reuseExistingListener: Bool) async throws -> Int {
    try Task.checkCancellation()
    guard !isShutDown else { throw CancellationError() }
    let stale = entries.removeValue(forKey: identity)
    if let stale {
      retire(stale.process, identity: identity)
      await waitForRetirement(identity: identity)
    }
    try Task.checkCancellation()
    guard !isShutDown else { throw CancellationError() }
    let port = configuredPort ?? Self.stablePort(for: identity)
    // A pre-existing listener is borrowed, never terminated by Woven. Protocol
    // and authentication are verified by the Gateway client before linking.
    let process: OwnedProcess
    if reuseExistingListener, isReady(port) {
      let ready = isReady
      process = OwnedProcess(isRunning: { ready(port) }, terminate: {})
    } else {
      process = try launchProcess(launch, workingDirectory)
    }
    entries[identity] = Entry(process: process, agents: [], port: port, generation: generation)
    do {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(15))
      while process.isRunning(), clock.now < deadline {
        try Task.checkCancellation()
        guard !isShutDown, entries[identity]?.generation == generation else { throw CancellationError() }
        if isReady(port) {
          entries[identity]?.ready = true
          entries[identity]?.agents.formUnion(stale?.agents ?? [])
          return port
        }
        try await pause()
      }
      try Task.checkCancellation()
      guard process.isRunning() else { throw OpenClawLocalGatewayLifecycleError.processExited }
      throw OpenClawLocalGatewayLifecycleError.startupTimedOut
    } catch {
      retire(process, identity: identity)
      await waitForRetirement(identity: identity)
      if entries[identity]?.generation == generation { entries.removeValue(forKey: identity) }
      if let startupError = error as? OpenClawLocalGatewayLifecycleError {
        throw GatewayStartupFailure(reason: startupError.localizedDescription,
          status: process.exitStatus(), detail: process.startupOutput())
      }
      throw error
    }
  }

  private func retire(_ process: OwnedProcess, identity: String) {
    process.terminate()
    let previous = retiring[identity]?.task
    retiring[identity] = Retirement(id: UUID(), task: Task {
      await previous?.value
      await process.waitForExit()
    })
  }

  private func waitForRetirement(identity: String) async {
    while let retirement = retiring[identity] {
      await retirement.task.value
      if retiring[identity]?.id == retirement.id { retiring.removeValue(forKey: identity) }
    }
  }

  private static func launch(_ launch: LocalACPRuntimeLaunchConfiguration, _ workingDirectory: URL) throws -> OwnedProcess {
    let process = Process()
    process.executableURL = launch.executableURL
    process.arguments = launch.arguments
    process.currentDirectoryURL = workingDirectory
    var environment = ProcessInfo.processInfo.environment
    for key in launch.environmentKeysToRemove { environment.removeValue(forKey: key) }
    for prefix in launch.environmentKeyPrefixesToRemove {
      for key in environment.keys where key.hasPrefix(prefix) { environment.removeValue(forKey: key) }
    }
    environment.merge(launch.environment) { _, staged in staged }
    process.environment = environment
    // A pipe would break when the desktop exits and can terminate the Gateway
    // on its next log write. A private host log has an independent lifetime.
    let logURL = FileManager.default.temporaryDirectory.appending(path: "wovenmatter-openclaw-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
      attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    let log = try FileHandle(forWritingTo: logURL)
    process.standardOutput = log
    process.standardError = log
    process.standardInput = FileHandle.nullDevice
    do { try process.run() }
    catch { try? log.close(); try? FileManager.default.removeItem(at: logURL); throw error }
    try? log.close()
    let owner = GatewayProcessOwner(process)
    let sensitiveValues = environment.compactMap { key, value in
      let name = key.lowercased()
      return ["token", "password", "secret", "credential", "api_key", "private_key"].contains(where: name.contains) && !value.isEmpty ? value : nil
    }.sorted { $0.count > $1.count }
    return OwnedProcess(isRunning: { process.isRunning }, terminate: { owner.terminate() },
      waitForExit: { await owner.waitForExit() },
      exitStatus: { process.isRunning ? nil : process.terminationStatus },
      startupOutput: {
        guard let file = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd() else { return "" }
        try? file.seek(toOffset: length > 16384 ? length - 16384 : 0)
        let data = (try? file.read(upToCount: 16_384)) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        if length > 16384, !lines.isEmpty { lines.removeFirst() }
        return GatewayStartupOutput.redact(lines.joined(separator: "\n"), sensitiveValues: sensitiveValues)
      })
  }

  private static func portAcceptsConnections(_ port: Int) -> Bool {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(
          descriptor,
          $0,
          socklen_t(MemoryLayout<sockaddr_in>.size)
        ) == 0
      }
    }
  }

  func release(agentID: UUID) {
    guard let key = keysByAgent.removeValue(forKey: agentID), var entry = entries[key] else { return }
    entry.agents.remove(agentID)
    if entry.agents.isEmpty && !entry.ready {
      retire(entry.process, identity: key)
      entries.removeValue(forKey: key)
    } else {
      entries[key] = entry
    }
  }

  func shutdown() async {
    isShutDown = true
    for start in pending.values { start.task.cancel() }
    pending.removeAll()
    // A ready Gateway owns scheduled execution beyond the desktop lifetime.
    // Only incomplete startup is cancelled when the application closes.
    for (identity, entry) in entries where !entry.ready { retire(entry.process, identity: identity) }
    entries.removeAll()
    keysByAgent.removeAll()
    let retirements = retiring.values.map(\.task)
    for task in retirements { await task.value }
    retiring.removeAll()
  }
}

/// One bounded reaper per owned process, independent of the cancelled startup task.
private final class GatewayProcessOwner: @unchecked Sendable {
  private let process: Process
  private let lock = NSLock()
  private var reaper: Task<Void, Never>?

  init(_ process: Process) { self.process = process }

  func terminate() {
    lock.withLock {
      guard reaper == nil else { return }
      let process = self.process
      if process.isRunning { process.terminate() }
      reaper = Task.detached {
        let clock = ContinuousClock()
        let gracefulDeadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning, clock.now < gracefulDeadline {
          try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        let forcedDeadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning, clock.now < forcedDeadline {
          try? await Task.sleep(for: .milliseconds(10))
        }
        // Never block a caller indefinitely on a process stuck in kernel exit.
        if !process.isRunning { process.waitUntilExit() }
      }
    }
  }

  func waitForExit() async {
    terminate()
    let task = lock.withLock { reaper }
    await task?.value
  }
}

private struct GatewayStartupFailure: LocalizedError {
  let reason: String
  let status: Int32?
  let detail: String
  var errorDescription: String? {
    let exit = status.map { " Exit status: \($0)." } ?? ""
    return reason + exit + (detail.isEmpty ? "" : "\n" + detail)
  }
}

private enum GatewayStartupOutput {
  static func redact(_ output: String, sensitiveValues: [String] = []) -> String {
    if output.contains("gateway.auth.mode=none cannot be used with gateway.tailscale.mode=") {
      return "OpenClaw rejected unauthenticated startup with Tailscale Serve/Funnel enabled. Tailscale Serve/Funnel requires an authenticated Gateway."
    }
    var result = output
    for value in sensitiveValues { result = result.replacingOccurrences(of: value, with: "[redacted]") }
    result = result.replacingOccurrences(of: #"\x1B\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    result = result.components(separatedBy: .newlines).map { line in
      if line.range(of: #"(?i)(token|password|secret|credential|api[_-]?key|authorization|private[_ -]?key)"#, options: .regularExpression) != nil {
        return "[credential-related startup output redacted]"
      }
      return line.replacingOccurrences(of: #"(?i)(https?|wss?)://[^\s]+"#, with: "[URL redacted]", options: .regularExpression)
        .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }.filter { !$0.isEmpty }.suffix(8).joined(separator: "\n")
    return String(result.prefix(2048))
  }
}
