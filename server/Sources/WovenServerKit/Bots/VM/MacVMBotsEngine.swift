#if os(macOS)
import Foundation
import WovenProtocol

/// Bots on a Mac run in Woven's own Linux VM, which runs Docker Engine. The
/// VM helper ships in the app (`Contents/Helpers/WovenMatterVMHelper`, guest
/// files in `Contents/Resources/WovenVM`); its disks, sockets and logs live in
/// `<data folder>/vm`, outside the bots folder. The pool is the VM's memory
/// and the disk cap its data disk's cap; per-bot memory is each container's
/// limit, which the runtime sets.
struct MacVMBotsEngine: BotsEngine {
  let vm: WovenVMController
  let dataFolder: URL
  var kind: String { "mac-vm" }

  /// The engine for this app, or why this Mac cannot run one.
  static func make(dataFolder: URL) -> any BotsEngine {
    #if arch(arm64)
    let helper = Resources.root.deletingLastPathComponent().appending(path: "Helpers/WovenMatterVMHelper")
    guard let bundle = Bundle.main.bundleIdentifier, FileManager.default.isExecutableFile(atPath: helper.path) else {
      return UnavailableBotsEngine(reason: "This build of Woven Matter has no VM helper, so it cannot run bots.")
    }
    let vm = WovenVMController(root: dataFolder.appending(path: "vm", directoryHint: .isDirectory),
                               sockets: SocketFolder.directory(for: dataFolder),
                               bundleIdentifier: bundle, helper: helper,
                               jobFile: dataFolder.appending(path: bundle + ".vm.plist"))
    return MacVMBotsEngine(vm: vm, dataFolder: dataFolder)
    #else
    return UnavailableBotsEngine(reason: "Bots on a Mac need Apple silicon.")
    #endif
  }

  func prepare(_ resources: BotsResources) async throws -> String {
    do {
      try await vm.start()
      // Before the first boot this sizes the VM.
      try await vm.apply(vmResources(resources))
      try await waitUntilReady()
    } catch let error as WovenVMError {
      throw RuntimeError.failed(Self.sentence(error))
    }
    let clock = ContinuousClock(), deadline = clock.now + .seconds(120)
    while !(await UnixHTTP.dockerAnswers(vm.engineSocket)) {
      guard clock.now < deadline else { throw RuntimeError.failed("Docker Engine in the bots' VM does not answer.") }
      try await Task.sleep(for: .seconds(1))
    }
    return vm.engineSocket
  }

  func apply(_ resources: BotsResources) async throws {
    do { try await vm.apply(vmResources(resources)) } catch let error as WovenVMError {
      throw RuntimeError.failed(Self.sentence(error))
    }
  }

  func capacity() async -> BotsCapacity? {
    if let report = try? await vm.status().resources {
      return BotsCapacity(memoryBytes: Int64(clamping: report.hostMemoryBytes),
                          diskTotalBytes: Int64(clamping: report.hostDiskTotalBytes),
                          diskFreeBytes: Int64(clamping: report.hostDiskFreeBytes),
                          diskUsedByBotsBytes: report.guestDiskUsedBytes.map { Int64(clamping: $0) })
    }
    // The helper is not running: this Mac's own measures, nothing yet stored.
    let volume = Self.volume(dataFolder)
    return BotsCapacity(memoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory),
                        diskTotalBytes: volume.total, diskFreeBytes: volume.free)
  }

  func stop() async {
    await vm.stop()
  }

  // MARK: -

  /// The helper limits each setup step itself; this only ends a wait that
  /// would otherwise never end. The first start downloads Ubuntu and
  /// installs Docker Engine.
  private func waitUntilReady() async throws {
    let clock = ContinuousClock(), started = clock.now
    while true {
      let status: WovenVMStatus
      do { status = try await vm.status() } catch {
        // launchd may be restarting the helper.
        guard clock.now - started < .seconds(60) else { throw error }
        try await Task.sleep(for: .seconds(1))
        continue
      }
      switch status.phase {
      case .ready: return
      case .failed: throw WovenVMError.failed(status.failure ?? "no reason was given")
      case .stopped where clock.now - started > .seconds(60):
        throw WovenVMError.unavailable("The bots' VM did not start.")
      default:
        guard clock.now - started < .seconds(4 * 3600) else {
          throw WovenVMError.unavailable("The bots' VM did not become ready in time.")
        }
        try await Task.sleep(for: .seconds(1))
      }
    }
  }

  /// The VM needs at least 1 GB of memory and 10 GB of disk, and the helper
  /// refuses more than this Mac has.
  private func vmResources(_ resources: BotsResources) -> WovenVMResources {
    let memory = ProcessInfo.processInfo.physicalMemory
    let volume = Self.volume(dataFolder).total
    let disk = volume > 0 ? UInt64(volume) : UInt64.max
    return WovenVMResources(
      memoryBytes: resources.poolBytes.map { min(memory, max(UInt64(clamping: $0), WovenVMResources.minimumMemoryBytes)) },
      diskBytes: resources.diskBytes.map { min(disk, max(UInt64(clamping: $0), WovenVMResources.minimumDiskBytes)) })
  }

  private static func volume(_ url: URL) -> (total: Int64, free: Int64) {
    let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
    return (Int64(values?.volumeTotalCapacity ?? 0), max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
  }

  private static func sentence(_ error: WovenVMError) -> String {
    switch error {
    case .failed(let message): "The bots' VM failed: \(message)"
    case .unavailable(let message), .invalid(let message): message
    }
  }
}
#endif
