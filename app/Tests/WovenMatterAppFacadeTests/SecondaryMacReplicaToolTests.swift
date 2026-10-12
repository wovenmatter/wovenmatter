import CompanionClient
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct SecondaryMacReplicaToolTests {
    private func setup(_ fixture: FacadeFixture) async throws -> (MobileStore, SecondaryMacExecutionWorkspace, String, String) {
        let replica = try MobileStore(file: fixture.directory.appending(path: "replica/library.json"))
        let libraryID = UUID().uuidString.lowercased()
        try await replica.verifyWorkspace(libraryID)
        let owner = await replica.snapshot().deviceID
        let caller = try await fixture.database.createLocalACPSession(runtimeKind: .codex, title: "Native caller", ownerDeviceID: UUID())
        let workspace = try await SecondaryMacExecutionWorkspace(descriptor: .init(id: owner, libraryID: libraryID, ownerDeviceID: owner, kind: .mac, name: "Secondary Mac"), model: fixture.model, replica: replica, directory: fixture.directory)
        let phone = UUID().uuidString.lowercased()
        try await replica.journal.upsertWorkspace(.init(id: phone, libraryID: libraryID, ownerDeviceID: phone, kind: .ios, name: "Phone"), pending: false)
        return (replica, workspace, caller, phone)
    }
    @Test func cachedForeignHistoryIsReadableButNeverBecomesNativeExecution() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (replica, workspace, caller, phone) = try await setup(fixture)
        let foreign = UUID().uuidString.lowercased()
        _ = try await replica.journal.append(workspaceID: phone,
            conversation: .init(id: foreign, title: "Phone conversation", runtimeKind: "pi-durable", workspaceID: phone),
            transcript: .init(conversationID: foreign, messages: [.init(id: UUID().uuidString.lowercased(), conversationID: foreign, role: "assistant", content: "Offline phone result")]))
        let tools = try #require(fixture.model.agentTools)
        let history = await tools.handle(.init(arguments: ["history", "conversation", foreign]), callerID: caller)
        #expect(history.success, "\(history.error ?? "")")
        #expect(history.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["content"]?.stringValue == "Offline phone result")
        let sessions = await tools.handle(.init(arguments: ["sessions", "list", "--all-workspace"]), callerID: caller)
        let ids = sessions.result?.objectValue?["rows"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } ?? []
        #expect(ids.contains(caller) && ids.contains(foreign))
        #expect(try await fixture.database.companionSnapshot().conversations.contains { $0.id == foreign } == false)
        #expect(await workspace.origin.snapshot().conversations[foreign] == nil)
        let sent = await tools.handle(.init(arguments: ["sessions", "send", foreign, "--text", "Must not route remotely"]), callerID: caller)
        #expect(!sent.success)
        _ = try await fixture.database.setSessionToolEnabled(.history, enabled: false, sessionID: caller)
        let denied = await tools.handle(.init(arguments: ["history", "conversation", foreign]), callerID: caller)
        #expect(!denied.success)
        #expect(await fixture.recorder.deliveries.isEmpty)
    }
    @Test func artifactPagesCrossFromReplicaToNativeWithoutDuplicateOwnArtifacts() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (replica, workspace, caller, phone) = try await setup(fixture)
        let a = try await replica.artifacts.save(data: Data("a".utf8), workspaceID: phone, title: "Remote file", mediaType: "text/plain", id: "a")
        let b = try await replica.artifacts.save(data: Data("b".utf8), workspaceID: phone, title: "Remote image", mediaType: "image/png", id: "b")
        _ = try await replica.artifacts.save(data: Data("own".utf8), workspaceID: workspace.descriptor.id, title: "Own mirror", mediaType: "text/plain", id: "own")
        let run = try await fixture.database.beginLocalACPRun(conversationID: caller, content: "https://native.example/resource")
        try await fixture.database.completeLocalACPRun(runID: run.runID)
        _ = try await fixture.database.indexLibraryMessages()
        let native = try #require(try await fixture.database.libraryItems().first)
        let tools = try #require(fixture.model.agentTools)
        var ids: [String] = []
        for offset in 0..<3 {
            let page = await tools.handle(.init(arguments: ["library", "list", "--offset", String(offset), "--limit", "1"]), callerID: caller)
            #expect(page.success, "\(page.error ?? "")")
            let value = try #require(page.result?.objectValue)
            ids += value["items"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } ?? []
            #expect(value["nextOffset"] == .number(Double(offset + 1)))
            #expect(value["hasMore"] == .bool(offset < 2))
        }
        #expect(ids == [a.id, b.id, native.id])
        let files = await tools.handle(.init(arguments: ["library", "list", "--kind", "file"]), callerID: caller)
        #expect(files.result?.objectValue?["items"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } == [a.id])
        let read = await tools.handle(.init(arguments: ["library", "read", b.id]), callerID: caller)
        #expect(read.success && read.result?.objectValue?["downloaded"] == .bool(true))
    }
    @Test func usagePaginationReadsCachedOtherDeviceSamplesWithoutProvider() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (replica, workspace, caller, phone) = try await setup(fixture)
        defer { withExtendedLifetime(workspace) {} }
        let foreign = UUID().uuidString.lowercased()
        _ = try await replica.journal.append(workspaceID: phone, conversation: .init(id: foreign, title: "Usage", workspaceID: phone))
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "conversationId": 1, "model": (0..<3).map { index in
            ["role": "assistant", "provider": "fixture", "model": "fixture", "timestamp": 10_000 + index * 1_000,
             "usage": ["input": 10, "output": 2, "totalTokens": 12]] as [String: Any]
        }])
        _ = try await replica.journal.appendNativeRecord(workspaceID: phone, conversationID: foreign, recordID: "usage-fixture", format: "pi-durable.entry.v1", data: data)
        let usageStore = try await AsyncUsageStore(databaseURL: fixture.directory.appending(path: "usage.sqlite"))
        let nativeSample = UsageSample(id: "native-usage", provider: .codex,
            timestamp: Date(timeIntervalSince1970: 13), sessionID: caller, accountLabel: "fixture",
            model: "fixture", harness: "Codex", application: "fixture",
            tokens: UsageTokenCounts(inputTokens: 10, outputTokens: 2), costUSD: 0,
            sourceID: "native-fixture", sourceEventID: "native-usage")
        try await usageStore.replace(sourceID: "native-fixture", sourceName: "Native fixture", location: "fixture",
            provider: .codex, harness: "Codex", fingerprint: "fixture", samples: [nativeSample],
            importedAt: Date(timeIntervalSince1970: 14))
        let tools = try #require(fixture.model.agentTools)
        var ids = Set<String>()
        for offset in 0..<4 {
            let response = await tools.handle(.init(arguments: ["usage", "read", "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:00:20Z", "--offset", String(offset), "--limit", "1"]), callerID: caller)
            #expect(response.success, "\(response.error ?? "")")
            let result = try #require(response.result?.objectValue)
            let sample = try #require(result["samples"]?.arrayValue?.first?.objectValue)
            ids.insert(try #require(sample["id"]?.stringValue))
            if offset < 3 { #expect(sample["workspace"]?.stringValue == "Phone") }
            else { #expect(sample["id"]?.stringValue == "native-fixture:native-usage") }
            #expect(result["hasMore"] == .bool(offset < 3))
            #expect(result["nextOffset"] == .number(Double(offset + 1)))
        }
        #expect(ids.count == 4)
        #expect(await fixture.recorder.deliveries.isEmpty)
    }
}
