import Foundation
import WovenMatterCore

/// A supported HTTP history page can contain one very large tool result. Keep
/// its complete native bytes while the UI only holds exposed scalar metadata.
enum OpenCodeNativeArchive {
    static func page(_ file: URL, byteCount: Int, path: String, sourceID: String,
                     recorder: @escaping WorkspaceWireRecorder) async throws -> OpenCodeValue {
        guard let sessionID = OpenCodeHTTPClient.nativeSessionID(path: path), path.hasSuffix("/message") else {
            throw OpenCodeError.message("Invalid OpenCode native history path.")
        }
        let metadata = try await PiNativeHistoryFrame.inspect(file, arrayDepth: 1)
        guard metadata.arrayKey == "data", metadata.count <= 1 else {
            throw OpenCodeError.message("OpenCode did not respect the single-message archive page limit. Native history remains available; retry synchronization.")
        }
        let collector = OpenCodeNativePageCollector(sourceID: sourceID, sessionID: sessionID, recorder: recorder)
        var page = try OpenCodeValue.decode(metadata.envelope)
        try await NativeHarnessArchive.captureFile(file, byteCount: byteCount, expectedSHA256: metadata.sha256,
            sourceID: sourceID, sessionID: sessionID, recorder: recorder) { safeFile, reference in
            let safeMetadata = try await PiNativeHistoryFrame.inspect(safeFile, arrayDepth: 1)
            try await PiNativeHistoryFrame.records(safeFile, expected: safeMetadata, arrayDepth: 1) { record, _ in
                try await collector.record(record, file: safeFile, reference: reference)
            }
        }
        page["data"] = .array(await collector.messages)
        return page
    }
}

private actor OpenCodeNativePageCollector {
    let sourceID: String, sessionID: String
    let recorder: WorkspaceWireRecorder
    var messages: [OpenCodeValue] = []
    init(sourceID: String, sessionID: String, recorder: @escaping WorkspaceWireRecorder) {
        self.sourceID = sourceID; self.sessionID = sessionID; self.recorder = recorder
    }
    func record(_ record: PiNativeHistoryFrame.Record, file: URL, reference: NativeHarnessArchive.FileReference) async throws {
        switch record {
        case .inline(let bytes):
            let message = try OpenCodeValue.decode(bytes)
            guard !message["id"].text.isEmpty else { throw OpenCodeError.message("OpenCode returned a message without native identity.") }
            try await NativeHarnessArchive.capture(sourceID: sourceID, sessionID: sessionID,
                records: [NativeHarnessArchive.record(id: "message:" + message["id"].text, kind: "message",
                    data: try NativeHarnessArchive.encode(message), completeness: "native-export")], recorder: recorder)
            messages.append(message)
        case .reference(let offset, let count, let sha, let scalars, let nativeID, _):
            guard let nativeID, !nativeID.isEmpty else { throw OpenCodeError.message("OpenCode returned a message without native identity.") }
            try await NativeHarnessArchive.captureRecordReference(file: file, reference: reference,
                id: "message:" + nativeID, kind: "message", runID: nil, byteOffset: offset, byteCount: count,
                sha256: sha, sourceID: sourceID, sessionID: sessionID, recorder: recorder)
            var projection = OpenCodeValue.object(scalars.mapValues(OpenCodeValue.string))
            projection["id"] = .string(nativeID)
            projection["_wovenNativeArchive"] = ["manifestID": .string(reference.manifestID),
                "byteOffset": .number(Double(offset)), "byteCount": .number(Double(count))]
            messages.append(projection)
        }
    }
}
