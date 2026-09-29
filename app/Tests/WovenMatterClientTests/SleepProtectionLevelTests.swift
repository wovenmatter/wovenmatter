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

    @Test func normalDefaultsPreserveExistingBehaviorAndExplicitOffPersists() {
        let name = "wovenmatter.sleep-levels.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ActiveWorkSleepPrevention.savedPolicy(defaults: defaults) == .displaySleepDefault)
        let activities = Activities()
        let owner = activities.owner(policy: .displaySleepDefault, source: { .external }, defaults: defaults)
        owner.setPolicy(.init(batteryPower: true))
        #expect(ActiveWorkSleepPrevention.savedPolicy(defaults: defaults) == .init(batteryPower: true))
        owner.setPolicy(.init())
        #expect(!ActiveWorkSleepPrevention.savedPolicy(defaults: defaults).isEnabled)
        #expect(activities.active.isEmpty) // Changing idle preferences never acquires activity.
    }

    @Test func externalPowerOnlyRespondsToPowerChangesDuringTheSameRun() {
        var source = WorkPowerSource.external
        let activities = Activities()
        let owner = activities.owner(policy: .init(externalPower: true), source: { source })
        let dispatch = owner.beginDispatch()
        #expect(activities.preventsIdleSleep && !activities.preventsDisplaySleep)
        source = .battery
        owner.powerSourceChanged()
        #expect(!activities.preventsIdleSleep && activities.active.count == 1)
        #expect(!owner.snapshot.isProtecting)
        #expect(activities.workChanges == [true])
        source = .external
        owner.powerSourceChanged()
        #expect(activities.preventsIdleSleep && activities.active.count == 1)
        owner.setRunningConversationIDs(["accepted"])
        owner.endDispatch(dispatch)
        #expect(activities.preventsIdleSleep)
        owner.setRunningConversationIDs([])
        #expect(activities.active.isEmpty && activities.workChanges == [true, false])
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

    @Test func liveToggleChangesKeepTrackingWorkWithoutBlockingSystemSleepWhenOff() {
        let activities = Activities()
        let owner = activities.owner(policy: .displaySleepDefault, source: { .battery })
        let first = owner.beginDispatch()
        let second = owner.beginDispatch()
        owner.setPolicy(.init())
        #expect(!activities.preventsIdleSleep && !activities.preventsDisplaySleep)
        #expect(activities.workChanges == [true])
        owner.endDispatch(first)
        owner.setPolicy(.init(batteryPower: true))
        #expect(activities.preventsIdleSleep && activities.active.count == 1)
        owner.endDispatch(second)
        #expect(activities.active.isEmpty && activities.workChanges == [true, false])
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
