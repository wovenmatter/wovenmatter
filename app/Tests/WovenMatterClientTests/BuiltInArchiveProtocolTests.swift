import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite(.timeLimit(.minutes(1)))
struct BuiltInArchiveProtocolTests {
    @Test @MainActor func reconnectPagesNativeHistoryWithoutCapturingCredentialWire() async throws {
        let first = WorkspaceNativeRunRecordBatch(sourceID: "store", nativeSessionID: "parent", records: [
            .init(id: "entry:1", runID: "old-run", kind: "assistant", payload: #"{"content":"retained first"}"#),
        ])
        let second = WorkspaceNativeRunRecordBatch(sourceID: "store", nativeSessionID: "parent", records: [
            .init(id: "entry:2", kind: "compaction", payload: #"{"summary":"retained context"}"#),
        ])
        let firstJSON = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        let secondJSON = String(decoding: try JSONEncoder().encode(second), as: UTF8.self)
        let fixture = try SessionRoutingFixture(firstPage: #"{"recordBatch":\#(firstJSON),"nextAfter":1,"hasMore":true}"#,
            secondPage: #"{"recordBatch":\#(secondJSON),"nextAfter":2,"hasMore":false}"#,
            nativeUpdate: #"{"sessionUpdate":"woven_native_record","recordBatch":\#(firstJSON)}"#)
        defer { fixture.remove() }
        let archive = NativeBatchCapture()
        let accounts = archiveFixtureAccounts()
        let client = try fixture.client(recorder: { direction, data in
            #expect(direction == "native")
            #expect(!String(decoding: data, as: UTF8.self).contains("fixture-secret"))
            try await archive.append(data)
        }, accounts: accounts)
        do {
            let loaded = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: "parent", title: nil)
            #expect(loaded.loadedExistingSession)
            let records = await archive.values
            #expect(records.count == 3)
            #expect(records.allSatisfy { $0.sourceID == "local:store" })
            #expect(records.flatMap(\.records).map(\.id) == ["entry:1", "entry:1", "entry:2"])
            #expect(records.flatMap(\.records).last?.runID == nil)
            #expect(try fixture.historyRequests() == 2)
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }

    @Test @MainActor func nonAdvancingHistoryCursorFailsWithoutLooping() async throws {
        let batch = WorkspaceNativeRunRecordBatch(sourceID: "store", nativeSessionID: "parent", records: [])
        let json = String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)
        let fixture = try SessionRoutingFixture(firstPage: #"{"recordBatch":\#(json),"nextAfter":0,"hasMore":true}"#,
            secondPage: "{}", nativeUpdate: nil)
        defer { fixture.remove() }
        let client = try fixture.client(recorder: { _, _ in }, accounts: archiveFixtureAccounts())
        do {
            _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: "parent", title: nil)
            Issue.record("A nonadvancing native cursor was accepted")
        } catch LocalACPClientError.invalidResponse { }
        catch { await client.shutdown(); throw error }
        #expect(try fixture.historyRequests() == 1)
        await client.shutdown()
    }

    @Test @MainActor func reconnectStreamsOversizedRecordSubcursorWithoutAssembly() async throws {
        let batch = WorkspaceNativeRunRecordBatch(sourceID: "store", nativeSessionID: "parent", records: [
            .init(id: "chunk:sha", kind: "native-file.chunk", payload: #"{"encoding":"base64","dataBase64":"cmF3"}"#),
        ])
        let json = String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)
        let fixture = try SessionRoutingFixture(firstPage: #"{"recordBatch":\#(json),"nextAfter":{"record":0,"byteOffset":262144},"hasMore":true}"#,
            secondPage: #"{"recordBatch":\#(json),"nextAfter":1,"hasMore":false}"#, nativeUpdate: nil)
        defer { fixture.remove() }
        let archive = NativeBatchCapture()
        let client = try fixture.client(recorder: { direction, data in #expect(direction == "native"); try await archive.append(data) }, accounts: archiveFixtureAccounts())
        do {
            _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: "parent", title: nil)
            #expect(await archive.values.count == 2)
            #expect(try fixture.historyRequests() == 2)
            let requests = try String(contentsOf: fixture.logURL, encoding: .utf8)
            #expect(requests.contains("byteOffset") && requests.contains("262144"))
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }

    @Test(arguments: [true, false]) @MainActor func idleRetirementWaitsForArchivedBackgroundRecords(confirmed: Bool) async throws {
        let empty = WorkspaceNativeRunRecordBatch(sourceID: "store", nativeSessionID: "parent", records: [])
        let background = WorkspaceNativeRunRecordBatch(sourceID: "store", nativeSessionID: "parent", records: [
            .init(id: "background:1", kind: "compaction", payload: #"{"summary":"background completed"}"#),
        ])
        let first = String(decoding: try JSONEncoder().encode(empty), as: UTF8.self)
        let last = String(decoding: try JSONEncoder().encode(background), as: UTF8.self)
        let fixture = try SessionRoutingFixture(firstPage: #"{"recordBatch":\#(first),"nextAfter":0,"hasMore":false}"#,
            secondPage: #"{"recordBatch":\#(last),"nextAfter":1,"hasMore":false}"#, nativeUpdate: nil,
            idleUpdate: #"{"sessionUpdate":"woven_native_record","recordBatch":\#(last)}"#,
            idleResult: confirmed ? #"{"idle":true}"# : #"{"idle":false}"#)
        defer { fixture.remove() }
        let archive = NativeBatchCapture()
        let client = try fixture.client(recorder: { direction, data in #expect(direction == "native"); try await archive.append(data) }, accounts: archiveFixtureAccounts())
        do {
            _ = try await client.initializeSession(workingDirectory: fixture.root, existingSessionID: "parent", title: nil)
            if confirmed { try await client.awaitIdle() }
            else {
                await #expect(throws: LocalACPClientError.self) { try await client.awaitIdle() }
            }
            let batches = await archive.values
            #expect(batches.last?.records.first?.payload.contains("background completed") == true)
            #expect(batches.last?.records.first?.runID == nil)
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }
}

@MainActor private func archiveFixtureAccounts() -> ProviderAccountCoordinator {
    ProviderAccountCoordinator(refresh: { scopes in
        Dictionary(uniqueKeysWithValues: scopes.map {
            ($0, DefaultAgentPayload(config: .init(), credentials: ["fixture": .init(type: "api_key", key: "fixture-secret")], workspace: $0))
        })
    }, version: { 0 }, configurationVersion: { 0 }, scopeVersion: { 0 }, reconfigure: { $0 })
}

private extension SessionRoutingFixture {
    init(firstPage: String, secondPage: String, nativeUpdate: String?, idleUpdate: String? = nil,
         idleResult: String? = nil) throws {
        func frames(_ update: String?) throws -> [[String: Any]] {
            guard let update else { return [] }
            return [["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "parent",
                "update": try JSONSerialization.jsonObject(with: Data(update.utf8))]]]
        }
        try self.init(bootstrapFrames: frames(nativeUpdate),
            historyPages: [firstPage, secondPage], idleFrames: frames(idleUpdate), idleResult: idleResult)
    }
    func client(recorder: @escaping WorkspaceWireRecorder, accounts: ProviderAccountCoordinator) throws -> LocalACPClient {
        try client(runtimeKind: .defaultAgent, accountCoordinator: accounts, historyRecorder: recorder)
    }
    func historyRequests() throws -> Int {
        try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").filter { $0.contains("woven") && $0.contains("history") }.count
    }
}
