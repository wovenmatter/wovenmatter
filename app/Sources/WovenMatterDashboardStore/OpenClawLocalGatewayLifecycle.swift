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
  private struct Entry {
    let process: Process
    var agents: Set<UUID>
    let port: Int
  }

  private var entries: [String: Entry] = [:]
  private var keysByAgent: [UUID: String] = [:]

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
    workingDirectory: URL
  ) async throws -> Int {
    var retainedAgents: Set<UUID> = [agentID]
    if var entry = entries[identity], entry.process.isRunning,
       Self.portAcceptsConnections(entry.port) {
      entry.agents.insert(agentID)
      entries[identity] = entry
      keysByAgent[agentID] = identity
      return entry.port
    }
    if let stale = entries.removeValue(forKey: identity) {
      retainedAgents.formUnion(stale.agents)
      if stale.process.isRunning { stale.process.terminate() }
    }
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
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let port = Self.stablePort(for: identity)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while process.isRunning, clock.now < deadline {
      if Self.portAcceptsConnections(port) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard process.isRunning else {
      throw OpenClawLocalGatewayLifecycleError.processExited
    }
    guard Self.portAcceptsConnections(port) else {
      process.terminate()
      throw OpenClawLocalGatewayLifecycleError.startupTimedOut
    }
    entries[identity] = Entry(process: process, agents: retainedAgents, port: port)
    keysByAgent[agentID] = identity
    return port
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
    if entry.agents.isEmpty {
      if entry.process.isRunning { entry.process.terminate() }
      entries.removeValue(forKey: key)
    } else {
      entries[key] = entry
    }
  }

  func shutdown() {
    for entry in entries.values where entry.process.isRunning { entry.process.terminate() }
    entries.removeAll()
    keysByAgent.removeAll()
  }
}
