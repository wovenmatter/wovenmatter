import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct LocalACPSessionMetadataTaskIdentityTests {
    @Test(arguments: AgentRuntimeKind.allCases.filter { $0 != .opencode })
    func nativeTaskIdentityChangesOnceForReadinessTransition(runtime: AgentRuntimeKind) throws {
        // This is the key consumed by DashboardConversation.task(id:). Both local
        // startup and remote readiness supply the same observed availability value.
        // A restored Built-in chat previously retained one key across this sequence.
        var transitions: [LocalACPSessionMetadataTaskIdentity] = []
        for ready in [false, false, true, true] {
            let key = try #require(LocalACPSessionMetadataTaskIdentity(
                conversationID: "restored-chat", runtimeKind: runtime,
                launchAvailable: ready))
            if transitions.last != key { transitions.append(key) }
        }
        #expect(transitions.count == 2)
        #expect(Set(transitions).count == 2)
    }

    @Test func openCodeDoesNotObserveNativeLaunchReadiness() throws {
        var reads = 0
        func readiness(_ value: Bool) -> Bool { reads += 1; return value }
        let waiting = LocalACPSessionMetadataTaskIdentity(
            conversationID: "managed-chat", runtimeKind: .opencode,
            launchAvailable: readiness(false))
        let ready = LocalACPSessionMetadataTaskIdentity(
            conversationID: "managed-chat", runtimeKind: .opencode,
            launchAvailable: readiness(true))
        #expect(waiting != nil && ready != nil)
        #expect(waiting == ready)
        #expect(reads == 0)
    }

    @Test func conversationAndRuntimeRetainDistinctTaskOwnership() throws {
        func key(_ id: String, _ runtime: AgentRuntimeKind) throws -> LocalACPSessionMetadataTaskIdentity {
            try #require(LocalACPSessionMetadataTaskIdentity(conversationID: id,
                runtimeKind: runtime, launchAvailable: true))
        }
        #expect(try key("first", .defaultAgent) != key("second", .defaultAgent))
        #expect(try key("first", .defaultAgent) != key("first", .claudeCode))
    }

    @Test(arguments: [AgentRuntimeKind.openclaw, .hermes, .cursor, .pi])
    func archivedRuntimeDoesNotRefreshOrReadLaunchState(runtime: AgentRuntimeKind) {
        var reads = 0
        func readiness() -> Bool { reads += 1; return true }
        let key = LocalACPSessionMetadataTaskIdentity(conversationID: "archived", runtimeKind: runtime,
            launchAvailable: readiness())
        #expect(key == nil)
        #expect(reads == 0)
    }

    @Test func nonNativeConversationHasNoTaskAndDoesNotReadLaunchState() {
        var reads = 0
        func readiness() -> Bool { reads += 1; return true }
        let key = LocalACPSessionMetadataTaskIdentity(conversationID: "non-native",
            runtimeKind: nil, launchAvailable: readiness())
        #expect(key == nil)
        #expect(reads == 0)
    }
}
