import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct RemoteBrowserAutomationTests {
    @Test func remoteBrowserHonorsCurrentPolicyReplaysAndJoinsCallerCancellation() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let caller = try await fixture.createConversation(), other = try await fixture.createConversation()
        try await fixture.database.setSessionTools(.init(enabled: [.browser]), sessionID: caller)
        var calls = 0, started = false, cancelled: [String] = []
        let host = WovenAutomationHost(assets: WorkspaceAssetSession(), database: fixture.database,
            allowsLocalSurfaces: false, remoteBrowser: { id in
                #expect(id == caller)
                return .init(perform: { input, requestID in
                    calls += 1
                    if input.objectValue?["action"] == .string("click") {
                        started = true
                        try await Task.sleep(for: .seconds(60))
                    }
                    return .init(result: .object(["content": .array([.object(["type": .string("image"), "mimeType": .string("image/jpeg"), "data": .string("anBlZw==")])])]), requestID: requestID)
                }, cancel: { cancelled.append($0) })
            })
        fixture.model.automationHost = host
        defer { host.stop(); fixture.model.automationHost = nil }
        let snapshot = WovenMatterToolRequest(arguments: ["browser", "call", "--json", #"{"action":"screenshot","tabId":"tab"}"#])
        let admitted = try await fixture.database.reserveAutomationRequest(callerID: caller, request: snapshot)
        let result = await host.handle(.init(callerID: caller, request: snapshot, admitted: admitted))
        #expect(result.success && result.result?.objectValue?["content"]?.arrayValue?.first?.objectValue?["type"] == .string("image"))
        #expect(await host.handle(.init(callerID: caller, request: snapshot, admitted: false)) == result)
        #expect(calls == 1)
        _ = try await fixture.database.setSessionToolEnabled(.browser, enabled: false, sessionID: caller)
        #expect(await host.handle(.init(callerID: caller, request: snapshot, admitted: false)).success == false)
        #expect(calls == 1)
        _ = try await fixture.database.setSessionToolEnabled(.browser, enabled: true, sessionID: caller)
        let click = WovenMatterToolRequest(arguments: ["browser", "call", "--json", ##"{"action":"click","tabId":"tab","selector":"#pending"}"##])
        let clickAdmitted = try await fixture.database.reserveAutomationRequest(callerID: caller, request: click)
        let pending = Task { await host.handle(.init(callerID: caller, request: click, admitted: clickAdmitted)) }
        let deadline = Date().addingTimeInterval(5)
        while !started, Date() < deadline { await Task.yield() }
        guard started else { pending.cancel(); _ = await pending.value; Issue.record("Remote browser request did not start"); return }
        await host.cancel(callerID: other)
        #expect(cancelled.isEmpty)
        let tools = try #require(fixture.model.agentTools)
        try await tools.setEnabled(.browser, enabled: false, sessionID: caller)
        #expect(cancelled == [click.requestID])
        #expect(await pending.value.success == false)
    }
}
