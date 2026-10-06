import CryptoKit
import Foundation
import WovenMatterCore

/// Native transcript copies are independent of the UI's mutable projection.
/// Callers select run/history interfaces; authentication/configuration replies
/// must never be passed here. Unknown fields and attachment blocks stay intact.
enum NativeHarnessArchive {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func record(id: String, runID: String? = nil, kind: String, data: Data, contentMode: String = "snapshot",
                       completeness: String = "observed") -> WorkspaceNativeRunRecord {
        WorkspaceNativeRunRecord(id: id, runID: runID, kind: kind, payload: String(decoding: data, as: UTF8.self),
            contentMode: contentMode, text: searchableText(data), completeness: completeness)
    }

    static func capture(sourceID: String, sessionID: String, records: [WorkspaceNativeRunRecord],
                        recorder: WorkspaceWireRecorder?) async throws {
        guard let recorder, !sessionID.isEmpty, !records.isEmpty else { return }
        try await recorder("native", encode(WorkspaceNativeRunRecordBatch(
            sourceID: sourceID, nativeSessionID: sessionID, records: records)))
    }

    static func download<T: Sendable>(_ request: URLRequest,
        consume: @escaping @Sendable (URL, Int, Int) async throws -> T) async throws -> T {
        let delegate = NativeArchiveDownloadDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("woven-native-download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let (temporary, response) = try await session.download(for: request)
            let file = directory.appendingPathComponent("native.json")
            try FileManager.default.moveItem(at: temporary, to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let count = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            guard count <= NativeArchiveDownloadDelegate.maximumBytes else { throw NativeArchiveDownloadDelegate.limitError }
            return try await consume(file, count, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            if delegate.exceededLimit { throw NativeArchiveDownloadDelegate.limitError }
            throw error
        }
    }

    struct FileReference: Encodable, Sendable {
        let manifestID: String
        let sha256: String
        let totalBytes: Int
        let byteFidelity: String
    }

    private struct FileChunk: Encodable {
        let format = "woven-native-file-chunk/v1"
        let encoding = "base64"
        let sha256: String
        let dataBase64: String
    }
    private struct FilePart: Encodable { let byteOffset: Int; let byteCount: Int; let chunkID: String }
    private struct FileManifest: Encodable {
        let format = "woven-native-file-manifest/v1"
        let sha256: String
        let byteFidelity: String
        let totalBytes: Int
        let parts: [FilePart]
    }
    private struct RecordReference: Encodable {
        let format = "woven-native-record-reference/v1"
        let manifestID: String
        let frameSHA256: String
        let recordSHA256: String
        let byteOffset: Int
        let byteCount: Int
        let nativeRecordID: String
    }
    private struct TextFragment: Encodable {
        let format = "woven-native-text-fragment/v1"
        let nativeRecordID: String
        let byteOffsetWithinRecord: Int
        let byteCount: Int
        let fragmentSHA256: String
    }

    /// Content-addressed chunks preserve exact native encoding while unchanged
    /// portions of repeated exports deduplicate. At the 1 GiB disk-frame limit
    /// this bounded manifest contains at most 4,096 references.
    @discardableResult
    static func captureFile(_ file: URL, byteCount: Int, expectedSHA256: String,
                            sourceID: String, sessionID: String, recorder: @escaping WorkspaceWireRecorder,
                            consume: @escaping @Sendable (URL, FileReference) async throws -> Void = { _, _ in }) async throws -> FileReference {
        let safe = try await NativeFramePrivacy.prepare(file, expectedSHA256: expectedSHA256, byteCount: byteCount)
        defer { if safe.redacted { try? FileManager.default.removeItem(at: safe.file) } }
        let input = try FileHandle(forReadingFrom: safe.file)
        defer { try? input.close() }
        var offset = 0, hash = SHA256(), parts: [FilePart] = []
        while let bytes = try input.read(upToCount: 256 * 1_024), !bytes.isEmpty {
            try Task.checkCancellation()
            guard parts.count < 4_096 else { throw PiNativeHistoryFrame.Failure.entryTooLarge }
            hash.update(data: bytes)
            let digest = digest(bytes), chunkID = "native-file.chunk:" + digest
            let chunk = FileChunk(sha256: digest, dataBase64: bytes.base64EncodedString())
            try await capture(sourceID: sourceID, sessionID: sessionID,
                records: [record(id: chunkID, kind: "native-file.chunk", data: try encode(chunk),
                    contentMode: "event", completeness: "native-file-chunk")], recorder: recorder)
            parts.append(FilePart(byteOffset: offset, byteCount: bytes.count, chunkID: chunkID))
            offset += bytes.count
        }
        let actualHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard offset == safe.byteCount, actualHash == safe.sha256 else { throw PiNativeHistoryFrame.Failure.malformed }
        let manifest = FileManifest(sha256: safe.sha256, byteFidelity: safe.redacted ? "tool-endpoint-redacted" : "exact-native-bytes", totalBytes: safe.byteCount, parts: parts)
        try await capture(sourceID: sourceID, sessionID: sessionID,
            records: [record(id: "native-file.manifest:" + safe.sha256, kind: "native-file.manifest", data: try encode(manifest),
                contentMode: "event", completeness: "native-export")], recorder: recorder)
        let reference = FileReference(manifestID: "native-file.manifest:" + safe.sha256, sha256: safe.sha256,
            totalBytes: safe.byteCount, byteFidelity: manifest.byteFidelity)
        try await consume(safe.file, reference)
        return reference
    }

    /// A large source record stays fully retrievable through its raw manifest.
    /// Index bounded UTF-8 projections with stable fragment identities instead
    /// of decoding or writing its entire JSON value in one in-memory operation.
    static func captureRecordReference(file: URL, reference: FileReference, id: String, kind: String, runID: String?,
                                       byteOffset: Int, byteCount: Int, sha256: String, sourceID: String,
                                       sessionID: String, recorder: @escaping WorkspaceWireRecorder) async throws {
        guard byteOffset >= 0, byteCount >= 0, byteOffset <= reference.totalBytes,
              byteCount <= reference.totalBytes - byteOffset else { throw PiNativeHistoryFrame.Failure.malformed }
        let raw = RecordReference(manifestID: reference.manifestID, frameSHA256: reference.sha256,
            recordSHA256: sha256, byteOffset: byteOffset, byteCount: byteCount, nativeRecordID: id)
        try await capture(sourceID: sourceID, sessionID: sessionID,
            records: [record(id: id, runID: runID, kind: kind, data: try encode(raw), completeness: "native-export-reference")], recorder: recorder)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(byteOffset))
        var offset = 0, tail = Data(), hash = SHA256(), projector = NativeJSONSearchProjection()
        while offset < byteCount {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: min(256 * 1_024, byteCount - offset)), !bytes.isEmpty else {
                throw PiNativeHistoryFrame.Failure.malformed
            }
            hash.update(data: bytes)
            let fragment = TextFragment(nativeRecordID: id, byteOffsetWithinRecord: offset,
                byteCount: bytes.count, fragmentSHA256: digest(bytes))
            var row = record(id: id, runID: runID, kind: "native-text-fragment",
                data: try encode(fragment), completeness: "native-text-fragment")
            row.revision = "projection:" + String(offset) + ":" + fragment.fragmentSHA256
            // An overlap keeps words and UTF-8 scalars crossing disk chunk
            // boundaries searchable. The raw manifest retains exact bytes.
            let decoded = try projector.consume(bytes)
            var textBytes = tail; textBytes.append(decoded)
            row.text = boundedUTF8(textBytes)
            try await capture(sourceID: sourceID, sessionID: sessionID, records: [row], recorder: recorder)
            tail = Data(decoded.suffix(512)); offset += bytes.count
        }
        try projector.finish()
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw PiNativeHistoryFrame.Failure.malformed
        }
    }

    private static func boundedUTF8(_ bytes: Data) -> String? {
        // Valid native JSON may split a code point at either end of a chunk.
        // Trim at most those boundary bytes; do not fabricate replacement text.
        for leading in 0...3 where leading <= bytes.count {
            for trailing in 0...3 where leading + trailing <= bytes.count {
                if let text = String(data: bytes.dropFirst(leading).dropLast(trailing), encoding: .utf8) { return text }
            }
        }
        return nil
    }

    /// Search is a projection of exposed text. The original JSON retains all
    /// native fields, including non-text content, IDs and attachment references.
    static func searchableText(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let text = text(in: object)
        return text.isEmpty ? nil : text
    }

    private static func text(in value: Any) -> String {
        if let string = value as? String { return string }
        if let array = value as? [Any] { return array.map(text).filter { !$0.isEmpty }.joined(separator: "\n") }
        guard let object = value as? [String: Any] else { return "" }
        let keys = ["message", "content", "text", "thinking", "reasoning", "summary", "output", "result", "result_text", "payload", "assistantMessageEvent", "delta", "arguments", "args", "input"]
        return keys.compactMap { object[$0] }.map(text).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Archive downloads and ordinary Hermes HTTP requests reject redirects, so
/// authentication never travels to a different endpoint. Large downloads are
/// bounded on disk; ordinary responses retain their existing in-memory limits.
final class NativeArchiveDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let maximumBytes = 1 * 1_024 * 1_024 * 1_024
    static var limitError: LocalACPClientError {
        .invalidResponse("Native history exceeds the 1 GiB disk archive limit. Its native session remains available; retry synchronization.")
    }
    private let lock = NSLock()
    private var exceeded = false
    var exceededLimit: Bool { lock.withLock { exceeded } }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maximumBytes || totalBytesExpectedToWrite > Self.maximumBytes {
            lock.withLock { exceeded = true }; downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
