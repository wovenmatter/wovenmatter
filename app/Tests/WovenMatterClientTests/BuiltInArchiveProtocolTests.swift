import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

private actor NativeBatchCapture {
    var values: [WorkspaceNativeRunRecordBatch] = []
    func append(_ data: Data) throws {
        values.append(try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self, from: data))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct BuiltInArchiveProtocolTests {
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
