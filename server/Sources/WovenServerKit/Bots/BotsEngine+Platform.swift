import Foundation
import WovenProtocol

// Replaced by the Mac VM engine and the Linux dedicated dockerd.

/// This platform's own engine.
func platformBotsEngine(dataFolder: URL) -> any BotsEngine {
  UnavailableBotsEngine()
}

struct UnavailableBotsEngine: BotsEngine {
  var kind: String { MachinePlatform.current == .mac ? "mac-vm" : "linux-dockerd" }
  func prepare(_ resources: BotsResources) async throws -> String {
    throw RuntimeError.failed("This machine has no container engine for bots yet.")
  }
  func apply(_ resources: BotsResources) async throws {}
  func capacity() async -> BotsCapacity? { nil }
  func stop() async {}
}
