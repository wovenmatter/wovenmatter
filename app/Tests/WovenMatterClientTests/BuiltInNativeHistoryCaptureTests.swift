import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct BuiltInNativeHistoryCaptureTests {
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

}
