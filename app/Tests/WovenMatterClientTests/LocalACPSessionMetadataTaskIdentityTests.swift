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
                usesOpenClawGateway: false, launchAvailable: ready))
            if transitions.last != key { transitions.append(key) }
        }
        #expect(transitions.count == 2)
        #expect(Set(transitions).count == 2)
    }

    @Test func gatewayAndOpenCodeDoNotObserveNativeLaunchReadiness() throws {
        for (runtime, gateway) in [(AgentRuntimeKind.openclaw, true), (.opencode, false)] {
            var reads = 0
            func readiness(_ value: Bool) -> Bool { reads += 1; return value }
            // Evaluate outside the assertion macro: its diagnostic argument
            // capture would eagerly call the readiness expression itself.
            let waiting = LocalACPSessionMetadataTaskIdentity(
                conversationID: "managed-chat", runtimeKind: runtime,
                usesOpenClawGateway: gateway, launchAvailable: readiness(false))
            let ready = LocalACPSessionMetadataTaskIdentity(
                conversationID: "managed-chat", runtimeKind: runtime,
                usesOpenClawGateway: gateway, launchAvailable: readiness(true))
            #expect(waiting != nil && ready != nil)
            #expect(waiting == ready)
            #expect(reads == 0)
        }
    }

    @Test func conversationRuntimeAndGatewayRouteRetainDistinctTaskOwnership() throws {
        func key(_ id: String, _ runtime: AgentRuntimeKind, gateway: Bool = false) throws -> LocalACPSessionMetadataTaskIdentity {
            try #require(LocalACPSessionMetadataTaskIdentity(conversationID: id,
                runtimeKind: runtime, usesOpenClawGateway: gateway, launchAvailable: true))
        }
        #expect(try key("first", .defaultAgent) != key("second", .defaultAgent))
        #expect(try key("first", .defaultAgent) != key("first", .claudeCode))
        #expect(try key("first", .openclaw) != key("first", .openclaw, gateway: true))
    }

    @Test func nonNativeConversationHasNoTaskAndDoesNotReadLaunchState() {
        var reads = 0
        func readiness() -> Bool { reads += 1; return true }
        let key = LocalACPSessionMetadataTaskIdentity(conversationID: "non-native",
            runtimeKind: nil, usesOpenClawGateway: false, launchAvailable: readiness())
        #expect(key == nil)
        #expect(reads == 0)
    }
}
