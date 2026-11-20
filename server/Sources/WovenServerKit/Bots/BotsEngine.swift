import Foundation
import WovenProtocol

/// Limits for the bots on their home machine, from the synced setting
/// `bots.resources` (`{"poolBytes", "perBotBytes", "diskBytes"}`, each a
/// byte count or null for no cap).
public struct BotsResources: Codable, Sendable, Hashable {
  /// The memory every bot shares: the VM on a Mac, the engine's slice on Linux.
  public var poolBytes: Int64?
  /// Each bot's container memory limit.
  public var perBotBytes: Int64?
  /// One cap on what the bots store.
  public var diskBytes: Int64?

  public static let setting = "bots.resources"
  public static let defaults = BotsResources(poolBytes: 8 << 30, perBotBytes: 4 << 30, diskBytes: 50 << 30)

  public init(poolBytes: Int64?, perBotBytes: Int64?, diskBytes: Int64?) {
    self.poolBytes = poolBytes
    self.perBotBytes = perBotBytes
    self.diskBytes = diskBytes
  }
}

/// The Docker Engine the bots' containers run in, on the home machine: on a
/// Mac, Woven's own Linux VM through the VM helper; on Linux, the dedicated
/// dockerd. The runtime is given only its socket.
protocol BotsEngine: Sendable {
  /// "mac-vm" or "linux-dockerd", as the runtime's config names it.
  var kind: String { get }
  /// Starts the engine, or finds it running, and returns its Docker socket.
  /// Throws an error whose description says what the person can do.
  func prepare(_ resources: BotsResources) async throws -> String
  /// Applies changed limits to a running engine.
  func apply(_ resources: BotsResources) async throws
  /// This machine's memory and disk, and what the bots store.
  func capacity() async -> BotsCapacity?
  /// The bots moved away or the server stops: release what `prepare` started.
  func stop() async
}

/// `WOVEN_BOTS_ENGINE_SOCKET` names a Docker socket to use as it is, for
/// development and tests: nothing is set up or stopped.
struct GivenBotsEngine: BotsEngine {
  let socket: String
  var kind: String { "linux-dockerd" }

  func prepare(_ resources: BotsResources) async throws -> String {
    guard FileManager.default.fileExists(atPath: socket) else {
      throw RuntimeError.failed("No Docker socket at \(socket).")
    }
    return socket
  }

  func apply(_ resources: BotsResources) async throws {}
  func capacity() async -> BotsCapacity? { nil }
  func stop() async {}
}

/// The engine for this machine: the given socket when one is set, else the
/// platform's own.
func standardBotsEngine(dataFolder: URL) -> any BotsEngine {
  if let socket = ProcessInfo.processInfo.environment["WOVEN_BOTS_ENGINE_SOCKET"], !socket.isEmpty {
    return GivenBotsEngine(socket: socket)
  }
  return platformBotsEngine(dataFolder: dataFolder)
}
