import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct BuiltInNativeHistoryCaptureTests {
    @Test func retainsNativeNonTextRecordsAndExcludesTransportConfiguration() throws {
        let raw = #"{"schemaVersion":1,"sourceID":"builtin-pi-durable:store-uuid","nativeSessionID":"session-uuid","credentials":{"apiKey":"transport-secret"},"records":[{"id":"entry:1","kind":"message","payload":"{\"role\":\"assistant\",\"content\":[{\"type\":\"image\",\"data\":\"exposed-image\"},{\"type\":\"toolCall\",\"arguments\":{\"token\":\"content-value\"}}]}","contentMode":"snapshot","unknownTransportField":"secret"}]}"#
        let value = try JSONDecoder().decode(ACPJSONValue.self, from: Data(raw.utf8))
        let result = try BuiltInNativeHistoryCapture.batchData(value, sessionID: "session-uuid")
        let text = String(decoding: result, as: UTF8.self)
        #expect(!text.contains("transport-secret"))
        #expect(!text.contains("unknownTransportField"))
        let batch = try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self, from: result)
        #expect(batch.records.first?.payload.contains("exposed-image") == true)
        #expect(batch.records.first?.payload.contains("content-value") == true)
    }

    @Test func refusesForeignOrInvalidArchiveRecords() throws {
        for batch in [
            WorkspaceNativeRunRecordBatch(sourceID: "store", nativeSessionID: "child", records: []),
            WorkspaceNativeRunRecordBatch(schemaVersion: 2, sourceID: "store", nativeSessionID: "parent", records: []),
            WorkspaceNativeRunRecordBatch(sourceID: "", nativeSessionID: "parent", records: []),
            WorkspaceNativeRunRecordBatch(sourceID: "store", nativeSessionID: "parent", records: [
                .init(id: "record", kind: "message", payload: "{}", contentMode: "replacement"),
            ]),
        ] {
            let value = try JSONDecoder().decode(ACPJSONValue.self, from: JSONEncoder().encode(batch))
            #expect(throws: (any Error).self) {
                try BuiltInNativeHistoryCapture.batchData(value, sessionID: "parent")
            }
        }
    }

    @Test func scopesStoreIdentityAndKeepsHistoricalRunAttribution() throws {
        let batch = WorkspaceNativeRunRecordBatch(sourceID: "store", nativeSessionID: "session", records: [
            .init(id: "old", runID: "old-run", kind: "message", payload: "{}"),
            .init(id: "live", kind: "message", payload: "{}"),
        ])
        let value = try JSONDecoder().decode(ACPJSONValue.self, from: JSONEncoder().encode(batch))
        let data = try BuiltInNativeHistoryCapture.batchData(value, sessionID: "session",
            sourcePrefix: "remote:workspace:")
        let captured = try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self, from: data)
        #expect(captured.sourceID == "remote:workspace:store")
        #expect(captured.records.map(\.runID) == ["old-run", nil])
        let replay = try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self,
            from: BuiltInNativeHistoryCapture.batchData(value, sessionID: "session"))
        #expect(replay.records[1].runID == nil)
    }
}
