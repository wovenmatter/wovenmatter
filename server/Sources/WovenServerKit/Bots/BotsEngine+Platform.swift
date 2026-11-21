import Foundation
import WovenProtocol

/// This platform's own engine: Woven's Linux VM on a Mac, the dedicated
/// dockerd on Linux (a development instance's own).
func platformBotsEngine(dataFolder: URL, instance: String?) -> any BotsEngine {
  #if os(macOS)
  MacVMBotsEngine.make(dataFolder: dataFolder)
  #else
  LinuxDockerdBotsEngine(instance: instance)
  #endif
}

/// A machine that cannot run the bots' engine, with the reason.
struct UnavailableBotsEngine: BotsEngine {
  let reason: String
  var kind: String { MachinePlatform.current == .mac ? "mac-vm" : "linux-dockerd" }
  func prepare(_ resources: BotsResources) async throws -> String { throw RuntimeError.failed(reason) }
  func apply(_ resources: BotsResources) async throws {}
  func capacity() async -> BotsCapacity? { nil }
  func stop() async {}
}
