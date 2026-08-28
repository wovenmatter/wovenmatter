import Foundation
import WovenMatterClient

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
  ) throws -> Int {
    if var entry = entries[identity], entry.process.isRunning {
      entry.agents.insert(agentID)
      entries[identity] = entry
      keysByAgent[agentID] = identity
      return entry.port
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
    entries[identity] = Entry(process: process, agents: [agentID], port: port)
    keysByAgent[agentID] = identity
    return port
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
