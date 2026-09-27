import Foundation
import Testing
@testable import WovenMatterClient

@MainActor
struct ActiveWorkSleepPreventionTests {
    @MainActor
    private final class Activities {
        var starts = 0
        var ends = 0
        var options: ProcessInfo.ActivityOptions = []
        weak var token: NSObject?

        func makeOwner(ownsExecution: Bool = true) -> ActiveWorkSleepPrevention {
            ActiveWorkSleepPrevention(ownsExecution: ownsExecution, beginActivity: { options, reason in
                self.starts += 1
                self.options = options
                #expect(!reason.isEmpty)
                let token = NSObject()
                self.token = token
                return token
            }, endActivity: { token in
                #expect(token === self.token)
                self.ends += 1
            })
        }
    }

    @Test func concurrentDispatchesShareOneAssertionAndAllowDisplaySleep() {
        let activities = Activities()
        let owner = activities.makeOwner()
        owner.setRunningConversationIDs([])
        #expect(activities.starts == 0)
        let first = owner.beginDispatch()
        let second = owner.beginDispatch()
        #expect(activities.starts == 1)
        #expect(activities.options.contains(.userInitiated))
        #expect(activities.options.contains(.idleSystemSleepDisabled))
        #expect(!activities.options.contains(.idleDisplaySleepDisabled))
        owner.endDispatch(first)
        owner.endDispatch(first) // A repeated completion cannot release another run.
        #expect(activities.ends == 0)
        owner.endDispatch(second)
        #expect(activities.ends == 1)
        #expect(activities.token == nil)
    }

    @Test func acceptedSendHandsOffToRunningSessionsWithoutDroppingProtection() {
        let activities = Activities()
        let owner = activities.makeOwner()
        let dispatch = owner.beginDispatch()
        owner.setRunningConversationIDs(["first", "second"])
        owner.endDispatch(dispatch)
        owner.setRunningConversationIDs(["first", "second"])
        #expect(activities.starts == 1)
        #expect(activities.ends == 0)
        owner.setRunningConversationIDs(["second"])
        #expect(activities.ends == 0)
        owner.setRunningConversationIDs([])
        #expect(activities.ends == 1)
        owner.setRunningConversationIDs(["restored-session"])
        #expect(activities.starts == 2)
        owner.setRunningConversationIDs([])
        #expect(activities.ends == 2)
    }

    @Test func preparationReconciliationCannotReleaseAnInFlightDispatch() {
        let activities = Activities()
        let owner = activities.makeOwner()
        let dispatch = owner.beginDispatch()
        // A workspace refresh can still report no runs during session setup.
        owner.setRunningConversationIDs(["preparing"])
        owner.setRunningConversationIDs([])
        #expect(activities.ends == 0)
        // Acceptance must restore authoritative run state before ending dispatch.
        owner.setRunningConversationIDs(["accepted"])
        owner.endDispatch(dispatch)
        #expect(activities.starts == 1)
        #expect(activities.ends == 0)
        owner.setRunningConversationIDs([])
        #expect(activities.ends == 1)
    }

    @Test func runFinishingBeforeSendReturnsKeepsProtectionUntilDispatchCompletes() {
        let activities = Activities()
        let owner = activities.makeOwner()
        let dispatch = owner.beginDispatch()
        owner.setRunningConversationIDs(["fast-run"])
        owner.setRunningConversationIDs([])
        #expect(activities.ends == 0)
        owner.endDispatch(dispatch)
        #expect(activities.starts == 1)
        #expect(activities.ends == 1)
    }

    @Test func failureAndCancellationReleaseDispatchLeases() async {
        let activities = Activities()
        let owner = activities.makeOwner()
        func failingDispatch() async throws {
            let dispatch = owner.beginDispatch()
            defer { owner.endDispatch(dispatch) }
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) { try await failingDispatch() }
        #expect(activities.starts == 1)
        #expect(activities.ends == 1)

        let task = Task { @MainActor in
            let dispatch = owner.beginDispatch()
            defer { owner.endDispatch(dispatch) }
            try await Task.sleep(for: .seconds(60))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(activities.starts == 2)
        #expect(activities.ends == 2)
        #expect(activities.token == nil)
    }

    @Test func frontendNeverAcquiresAnAssertionFromMirroredState() {
        let activities = Activities()
        let owner = activities.makeOwner(ownsExecution: false)
        let dispatch = owner.beginDispatch()
        owner.setRunningConversationIDs(["backend-run"])
        owner.endDispatch(dispatch)
        owner.stop()
        #expect(activities.starts == 0)
        #expect(activities.ends == 0)
    }

    @Test func shutdownReleasesAndRejectsLateCallbacks() {
        let activities = Activities()
        let owner = activities.makeOwner()
        let dispatch = owner.beginDispatch()
        owner.setRunningConversationIDs(["running"])
        owner.stop()
        owner.stop()
        owner.setRunningConversationIDs(["late-callback"])
        owner.endDispatch(dispatch)
        owner.endDispatch(owner.beginDispatch())
        #expect(activities.starts == 1)
        #expect(activities.ends == 1)
        #expect(activities.token == nil)
    }

    @Test func workObserverCoversPreparationHandoffAndTerminalShutdown() {
        var changes: [Bool] = []
        let owner = ActiveWorkSleepPrevention(ownsExecution: true,
            beginActivity: { _, _ in NSObject() }, endActivity: { _ in },
            onWorkChanged: { changes.append($0) })
        let dispatch = owner.beginDispatch()
        owner.setRunningConversationIDs([])
        owner.setRunningConversationIDs(["accepted"])
        owner.endDispatch(dispatch)
        #expect(changes == [true])
        owner.setRunningConversationIDs([])
        #expect(changes == [true, false])
        _ = owner.beginDispatch()
        owner.stop()
        _ = owner.beginDispatch()
        #expect(changes == [true, false, true, false])
    }

    @Test func releasingOwnerReleasesFoundationActivityToken() {
        let activities = Activities()
        var owner: ActiveWorkSleepPrevention? = activities.makeOwner()
        _ = owner?.beginDispatch()
        #expect(activities.token != nil)
        owner = nil
        #expect(activities.token == nil)
    }
}
