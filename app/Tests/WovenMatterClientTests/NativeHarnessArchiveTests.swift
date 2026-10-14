import Foundation
import CryptoKit
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct NativeHarnessArchiveTests {
    @Test func nativeMessageMetadataCannotBeOverwrittenBySiblingDetails() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"length\"},\"details\":{\"role\":\"user\",\"stopReason\":\"error\"}}".utf8).write(to: file)
        let metadata = try await PiNativeHistoryFrame.inspectObject(file)
        #expect(metadata.messageScalars["role"] == "assistant")
        #expect(metadata.messageScalars["stopReason"] == "length")
    }

    @Test(.timeLimit(.minutes(3)))
    func oversizedNativeRecordsRemainCompleteSearchableAndUseSanitizedOffsets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.json"), restored = directory.appendingPathComponent("archived.json")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let output = try FileHandle(forWritingTo: file)
        let endpoint = "/private/tmp/wmtools-" + String(repeating: "a", count: 32) + "/" + String(repeating: "b", count: 32) + ".sock"
        let prefix = "{\"note\":\"\(endpoint)\",\"data\":[{\"text\":\""
        try output.write(contentsOf: Data(prefix.utf8))
        let block = Data(repeating: 120, count: 64 * 1_024)
        for _ in 0..<1_072 { try output.write(contentsOf: block) }
        // Native identities after the huge string must still be observed.
        let suffix = "\\nneedle\\u00e9\\ud83e\\uddf5\",\"type\":\"assistant\",\"id\":\"message-large\"}],\"cursor\":{\"next\":\"message-large\"}}"
        try output.write(contentsOf: Data(suffix.utf8)); try output.close()
        let count = try #require((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue)
        #expect(count > 64 * 1_024 * 1_024)
        let capture = try NativeDiskCapture(file: restored)
        let recorder: WorkspaceWireRecorder = { _, data in try await capture.append(data) }
        let page = try await OpenCodeNativeArchive.page(file, byteCount: count, path: "/api/session/native-session/message",
            sourceID: "opencode:fixture", recorder: recorder)
        #expect(page["data"].array.first?["id"].text == "message-large")
        #expect(page["data"].array.first?["type"].text == "assistant")
        #expect(page["data"].array.first?["text"].isNull == true)
        #expect(page["cursor"]["next"].text == "message-large")
        try await capture.closeAndValidate()
        #expect(await capture.fidelity == "tool-endpoint-redacted")
        #expect(await capture.searchedEscapes)
        #expect(await capture.fragmentCount > 250)
        #expect(await capture.maximumPayloadBytes < 400_000)
        #expect(await capture.recordID == "message:message-large")
    }

    @Test func nativeHistoryScannerRejectsMalformedArrays() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\"data\":{\"entries\":[{\"id\":\"row\"},]}}".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await PiNativeHistoryFrame.inspect(file) }
    }

    @Test func openCodeSnapshotsKeepUnknownAndNonTextContentWithoutCapturingConfiguration() throws {
        let long = String(repeating: "unabridged exposed tool output ", count: 10_000)
        let row: OpenCodeValue = ["id": "message-1", "type": "assistant", "content": .array([
            ["type": "reasoning", "text": "exposed thought"],
            ["type": "tool", "result": .string(long)],
            ["type": "image", "url": "native://image", "future_field": "retained"]
        ])]
        let batch = try #require(try OpenCodeHTTPClient.nativeSnapshot(path: "/api/session/native-session/message",
            value: ["data": .array([row])], sourceID: "remote-workspace:fixture"))
        #expect(batch.records.first?.id == "message:message-1")
        #expect(batch.records.first?.payload.contains(long) == true)
        #expect(batch.records.first?.payload.contains("native://image") == true)
        #expect(batch.records.first?.text?.contains("exposed thought") == true)
        #expect(try OpenCodeHTTPClient.nativeSnapshot(path: "/api/config", value: ["token": "private"], sourceID: "fixture") == nil)
    }

    @Test func archivedHermesExportRetainsMetadata() throws {
        let identity = HermesSessionArchive.identity(home: "/remote-workspaces/11111111-1111-1111-1111-111111111111/home/.hermes", storedID: "native-session", imported: true)
        let message: HermesValue = ["id": .number(7), "role": "tool", "content": "full result", "tool_call_id": "call-1", "unknown_metadata": ["preserved": .bool(true)]]
        let snapshot: HermesValue = ["id": "native-session", "messages": .array([message]), "compression_parent": "older-session"]
        let batch = try HermesSessionImport(identity: identity, title: "Imported", createdAt: .now, messages: [message], nativeSnapshot: snapshot).nativeArchiveBatch()
        #expect(batch.records.contains { $0.id == "message:7" && $0.payload.contains("unknown_metadata") })
        #expect(batch.records.contains { $0.id == "session.export" && $0.payload.contains("compression_parent") })
    }
}

/// Tests large copies using a disk sink and bounded metadata, rather than
/// accidentally retaining every base64/native/search fragment in the fixture.
private actor NativeDiskCapture {
    let file: URL, output: FileHandle
    var fidelity = "", recordID = "", searchedEscapes = false
    var fragmentCount = 0, maximumPayloadBytes = 0
    private var reference: WorkspaceNativeRunRecord?
    private var byteCount = 0, hash = SHA256(), expectedHash = ""
    init(file: URL) throws {
        self.file = file
        FileManager.default.createFile(atPath: file.path, contents: nil)
        output = try FileHandle(forWritingTo: file)
    }
    func append(_ data: Data) throws {
        maximumPayloadBytes = max(maximumPayloadBytes, data.count)
        let batch = try JSONDecoder().decode(WorkspaceNativeRunRecordBatch.self, from: data)
        for row in batch.records {
            if row.kind == "native-file.chunk" {
                let value = try HermesValue.decode(Data(row.payload.utf8))
                let bytes = try #require(Data(base64Encoded: value["dataBase64"].text))
                #expect(NativeHarnessArchive.digest(bytes) == value["sha256"].text)
                try output.write(contentsOf: bytes); hash.update(data: bytes); byteCount += bytes.count
            } else if row.kind == "native-file.manifest" {
                let value = try HermesValue.decode(Data(row.payload.utf8))
                expectedHash = value["sha256"].text; fidelity = value["byteFidelity"].text
                #expect(value["totalBytes"].number == Double(byteCount))
            } else if row.completeness == "native-export-reference" {
                reference = row; recordID = row.id
            } else if row.kind == "native-text-fragment" {
                fragmentCount += 1
                #expect(row.id == recordID)
                #expect(row.revision?.hasPrefix("projection:") == true)
                if row.text?.contains("needleé🧵") == true { searchedEscapes = true }
            }
        }
    }
    func closeAndValidate() throws {
        try output.close()
        #expect(hash.finalize().map { String(format: "%02x", $0) }.joined() == expectedHash)
        let row = try #require(reference), value = try HermesValue.decode(Data(row.payload.utf8))
        let offset = try #require(value["byteOffset"].number), length = try #require(value["byteCount"].number)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(offset))
        var remaining = Int(length), recordHash = SHA256()
        while remaining > 0 {
            let bytes = try #require(try input.read(upToCount: min(64 * 1_024, remaining)))
            #expect(!bytes.isEmpty); remaining -= bytes.count; recordHash.update(data: bytes)
        }
        #expect(recordHash.finalize().map { String(format: "%02x", $0) }.joined() == value["recordSHA256"].text)
    }
}
