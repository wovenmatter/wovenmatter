import Foundation
import Testing
@testable import WovenMatterClient

@MainActor
struct SleepProtectionLevelTests {
    @MainActor private final class Activities {
        var active: [ObjectIdentifier: ProcessInfo.ActivityOptions] = [:]
        var workChanges: [Bool] = []
        var preventsIdleSleep: Bool { active.values.contains { $0.contains(.idleSystemSleepDisabled) } }
        var preventsDisplaySleep: Bool { active.values.contains { $0.contains(.idleDisplaySleepDisabled) } }

        func owner(policy: WorkPowerPolicy, higher: WorkPowerPolicy = .init(),
                   source: @escaping () -> WorkPowerSource, defaults: UserDefaults? = nil,
                   ownsExecution: Bool = true) -> ActiveWorkSleepPrevention {
            ActiveWorkSleepPrevention(ownsExecution: ownsExecution, policy: policy,
                closedLidPolicy: higher, currentPowerSource: source, defaults: defaults,
                beginActivity: { options, _ in
                    let activity = NSObject()
                    self.active[ObjectIdentifier(activity)] = options
                    return activity
                }, endActivity: { activity in
                    #expect(self.active.removeValue(forKey: ObjectIdentifier(activity)) != nil)
                }, onWorkChanged: { self.workChanges.append($0) })
        }
    }

    @Test func batteryOnlyAndUnknownPowerDoNotLeakAnIdleSleepAssertion() {
        var source = WorkPowerSource.external
        let activities = Activities()
        let owner = activities.owner(policy: .init(batteryPower: true), source: { source })
        _ = owner.beginDispatch()
        #expect(!activities.preventsIdleSleep)
        source = .battery
        owner.powerSourceChanged()
        #expect(activities.preventsIdleSleep)
        source = .unknown
        owner.powerSourceChanged()
        #expect(!activities.preventsIdleSleep)
        owner.stop()
        source = .battery
        owner.powerSourceChanged()
        owner.setPolicy(.displaySleepDefault)
        #expect(activities.active.isEmpty)
    }

    @Test func higherLevelIncludesNormalProtectionOnlyOnItsSelectedSources() {
        var source = WorkPowerSource.external
        let activities = Activities()
        let owner = activities.owner(policy: .init(), higher: .init(batteryPower: true), source: { source })
        _ = owner.beginDispatch()
        #expect(!activities.preventsIdleSleep)
        source = .battery
        owner.powerSourceChanged()
        #expect(activities.preventsIdleSleep)
        #expect(!owner.snapshot.policy.isEnabled) // Higher level does not rewrite normal preferences.
        owner.setClosedLidPolicy(.init())
        #expect(!activities.preventsIdleSleep)
        #expect(activities.workChanges == [true])
        owner.setPolicy(.init(batteryPower: true))
        owner.setClosedLidPolicy(.init(batteryPower: true))
        owner.setClosedLidPolicy(.init())
        #expect(activities.preventsIdleSleep) // Downgrade retains the selected normal level.
        owner.stop()
        #expect(activities.active.isEmpty)
    }

    @Test func frontendDisplaysBothPolicyAndStatusWithoutAcquiringOrSavingActivity() {
        let activities = Activities()
        let owner = activities.owner(policy: .displaySleepDefault, source: { .battery }, ownsExecution: false)
        let snapshot = IdleSleepProtectionSnapshot(policy: .init(externalPower: true), isProtecting: true)
        owner.applyBackendSnapshot(snapshot)
        owner.setPolicy(.init(batteryPower: true))
        owner.setClosedLidPolicy(.init(batteryPower: true))
        _ = owner.beginDispatch()
        owner.setRunningConversationIDs(["mirrored"])
        #expect(owner.snapshot == snapshot)
        #expect(activities.active.isEmpty && activities.workChanges.isEmpty)
    }
}
