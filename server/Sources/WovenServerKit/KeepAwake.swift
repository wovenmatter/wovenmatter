import Foundation
import WovenLibrary
import WovenProtocol
#if os(macOS)
import IOKit.ps
import IOKit.pwr_mgt
#endif

/// Keeps this Mac from idle sleep while any of its sessions runs a turn, on
/// the power sources its `IdleSleepPolicy` names. The display may still sleep
/// and lock. It looks again at each run-state change and every 30 seconds, so
/// a changed policy or power source takes effect without a restart. Nothing
/// on Linux.
actor KeepAwake {
  private let library: Library
  private var running: Set<String> = []
  private var tasks: [Task<Void, Never>] = []
  #if os(macOS)
  private var assertion: IOPMAssertionID?
  #endif

  init(library: Library) { self.library = library }

  func start(board: RunBoard) async {
    #if os(macOS)
    let (current, changes) = board.subscribe()
    running = Set(current.filter { $0.run == .running }.map(\.sessionID))
    tasks = [
      Task { [weak self] in
        for await change in changes { await self?.changed(change) }
      },
      Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(30))
          await self?.update()
        }
      },
    ]
    await update()
    #endif
  }

  func stop() {
    for task in tasks { task.cancel() }
    tasks = []
    running = []
    #if os(macOS)
    hold(false)
    #endif
  }

  private func changed(_ state: SessionRunState) async {
    if state.run == .running { running.insert(state.sessionID) } else { running.remove(state.sessionID) }
    await update()
  }

  private func update() async {
    #if os(macOS)
    guard !running.isEmpty else { return hold(false) }
    let key = IdleSleepPolicy.settingKey(machineID: library.machineID)
    let policy = (try? await library.setting(key)?.value.decode(IdleSleepPolicy.self)) ?? IdleSleepPolicy()
    guard !running.isEmpty else { return hold(false) }
    hold(Self.onBattery ? policy.batteryPower : policy.externalPower)
    #endif
  }

  #if os(macOS)
  private static var onBattery: Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
    return (type as String) == kIOPMBatteryPowerKey
  }

  private func hold(_ wanted: Bool) {
    if wanted, assertion == nil {
      var id = IOPMAssertionID(0)
      let made = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Woven Matter agent work" as CFString, &id)
      if made == kIOReturnSuccess { assertion = id }
    } else if !wanted, let id = assertion {
      IOPMAssertionRelease(id)
      assertion = nil
    }
  }
  #endif
}
