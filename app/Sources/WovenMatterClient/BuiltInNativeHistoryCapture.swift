import Foundation
import WovenMatterCore

/// A narrow boundary for the credential-bearing Built-in control connection.
/// Decoding and re-encoding the public record contract excludes transport and
/// configuration fields; explicit session fencing also applies to replay pages.
enum BuiltInNativeHistoryCapture {
    static func batchData(_ value: ACPJSONValue, sessionID: String,
                          sourcePrefix: String = "") throws -> Data {
        var batch = try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self,
            from: JSONEncoder().encode(value))
        guard batch.schemaVersion == 1, batch.nativeSessionID == sessionID,
              !sessionID.isEmpty, !batch.sourceID.isEmpty,
              batch.records.allSatisfy({
                  !$0.id.isEmpty && !$0.kind.isEmpty && ["event", "delta", "snapshot"].contains($0.contentMode)
              }) else {
            throw LocalACPClientError.invalidResponse("Invalid Built-in native archive identity")
        }
        batch.sourceID = sourcePrefix + batch.sourceID
        // Background tasks may commit while a later turn is active. Only the
        // native receipt can attribute a record to a Woven run; observation
        // timing is insufficient. Unmapped records remain session-linked.
        return try JSONEncoder().encode(batch)
    }
}
