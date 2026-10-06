import Foundation
import WovenMatterCore

/// The native export is unpaged. Download to disk, preserve its exact bytes,
/// and import one exposed message at a time with archive-write backpressure.
extension HermesSessionHistory {
    static func archive(connection: HermesGatewayConnection, sessionID: String,
                        recorder: @escaping WorkspaceWireRecorder, afterMessageID: Int64?, runID: String?) async throws -> Int64 {
        guard !sessionID.isEmpty, (1...65535).contains(connection.port),
              let segment = sessionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "http://127.0.0.1:\(connection.port)" + connection.apiPrefix + "/api/sessions/" + segment + "/export") else {
            throw HermesGatewayError.message("Invalid Hermes native history request.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 45
        do {
            return try await NativeHarnessArchive.download(request) { file, bytes, status in
                guard (200...299).contains(status) else {
                    throw HermesGatewayError.message("Hermes could not export the requested native session.")
                }
                return try await archiveFile(file, byteCount: bytes, sessionID: sessionID,
                    identityHome: connection.identityHome, recorder: recorder, afterMessageID: afterMessageID, runID: runID)
            }
        } catch {
            throw HermesGatewayError.message("Hermes native archive synchronization failed: " + error.localizedDescription
                + " Its native session remains available; retry synchronization.")
        }
    }

    /// Also exercised with provider-free native exports, independent of HTTP.
    static func archiveFile(_ file: URL, byteCount: Int, sessionID: String, identityHome: String,
                            recorder: @escaping WorkspaceWireRecorder, afterMessageID: Int64?, runID: String?) async throws -> Int64 {
        let metadata = try await PiNativeHistoryFrame.inspect(file, arrayDepth: 1)
        let envelope = try HermesValue.decode(metadata.envelope)
        guard metadata.arrayKey == "messages", envelope["id"].text == sessionID else {
            throw HermesGatewayError.message("Hermes returned a different or incomplete native session export.")
        }
        let sourceID = "hermes:" + identityHome
        let collector = HermesNativeMessageCollector(sourceID: sourceID, sessionID: sessionID,
            recorder: recorder, afterMessageID: afterMessageID, runID: runID)
        try await NativeHarnessArchive.captureFile(file, byteCount: byteCount, expectedSHA256: metadata.sha256,
            sourceID: sourceID, sessionID: sessionID, recorder: recorder) { safeFile, reference in
            let safeMetadata = try await PiNativeHistoryFrame.inspect(safeFile, arrayDepth: 1)
            try await PiNativeHistoryFrame.records(safeFile, expected: safeMetadata, arrayDepth: 1) { record, ordinal in
                try await collector.record(record, ordinal: ordinal, file: safeFile, reference: reference)
            }
        }
        // This metadata envelope retains every top-level field; messages are
        // available as individual records and in the reconstructible raw copy.
        try await NativeHarnessArchive.capture(sourceID: sourceID, sessionID: sessionID,
            records: [NativeHarnessArchive.record(id: "session.export.metadata", kind: "session",
                data: metadata.envelope, completeness: "native-export-metadata")], recorder: recorder)
        return await collector.maximumMessageID
    }
}

private actor HermesNativeMessageCollector {
    let sourceID: String, sessionID: String
    let recorder: WorkspaceWireRecorder
    let afterMessageID: Int64?, runID: String?
    var maximumMessageID: Int64 = 0
    init(sourceID: String, sessionID: String, recorder: @escaping WorkspaceWireRecorder, afterMessageID: Int64?, runID: String?) {
        self.sourceID = sourceID; self.sessionID = sessionID; self.recorder = recorder
        self.afterMessageID = afterMessageID; self.runID = runID
    }
    func record(_ record: PiNativeHistoryFrame.Record, ordinal: Int, file: URL, reference: NativeHarnessArchive.FileReference) async throws {
        if case .reference(let offset, let count, let sha, _, let nativeID, _) = record {
            let id = nativeID.flatMap(Int64.init)
            let key = nativeID ?? "exposed:" + String(ordinal) + ":" + sha
            try await NativeHarnessArchive.captureRecordReference(file: file, reference: reference,
                id: "message:" + key, kind: "message", runID: id.flatMap { id in afterMessageID.map { id > $0 } } == true ? runID : nil,
                byteOffset: offset, byteCount: count, sha256: sha, sourceID: sourceID, sessionID: sessionID, recorder: recorder)
            if let id { maximumMessageID = max(maximumMessageID, id) }
            return
        }
        guard case .inline(let data) = record else { return }
        let row = try HermesValue.decode(data)
        guard let numeric = row["id"].number, numeric >= 1, numeric <= 9_007_199_254_740_991,
              let id = Int64(exactly: numeric) else {
            throw HermesGatewayError.message("Hermes export is missing a stable native message identity.")
        }
        let record = NativeHarnessArchive.record(id: "message:" + String(id),
            runID: afterMessageID.map { id > $0 } == true ? runID : nil,
            kind: "message", data: try NativeHarnessArchive.encode(row), completeness: "native-export")
        try await NativeHarnessArchive.capture(sourceID: sourceID, sessionID: sessionID,
            records: [record], recorder: recorder)
        maximumMessageID = max(maximumMessageID, id)
    }
}
