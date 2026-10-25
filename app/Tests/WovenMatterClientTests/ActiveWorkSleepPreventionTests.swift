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

    @Test func concurrentDispatchesAndShutdownReleaseAssertionsWithoutBlockingDisplaySleep() {
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
        let shutdownDispatch = owner.beginDispatch()
        owner.setRunningConversationIDs(["running"])
        owner.stop()
        owner.stop()
        owner.setRunningConversationIDs(["late-callback"])
        owner.endDispatch(shutdownDispatch)
        owner.endDispatch(owner.beginDispatch())
        #expect(activities.starts == 2 && activities.ends == 2)
        #expect(activities.token == nil)
    }

}
