import CryptoKit
import Foundation

/// Pi's public history commands return one unpaged JSONL response. Scan the
/// spooled frame without constructing that entire array in memory; each native
/// entry is validated and handed off separately with storage backpressure.
enum PiNativeHistoryFrame {
    static let maximumEntryBytes = 64 * 1_024 * 1_024
    static let maximumInlineEntryBytes = 8 * 1_024 * 1_024
    static let maximumEnvelopeBytes = 1 * 1_024 * 1_024

    struct Metadata: Sendable {
        let envelope: Data
        let arrayKey: String
        let count: Int
        let sha256: String
    }
    struct ObjectMetadata: Sendable {
        let sha256: String
        let byteCount: Int
        let scalars: [String: String]
        let messageScalars: [String: String]
    }

    enum Record: Sendable {
        case inline(Data)
        case reference(byteOffset: Int, byteCount: Int, sha256: String, scalars: [String: String], nativeID: String?, kind: String?)
    }

    enum Failure: LocalizedError {
        case unsupportedEnvelope
        case malformed
        case entryTooLarge
        var errorDescription: String? {
            switch self {
            case .unsupportedEnvelope: "The harness returned a native history envelope larger than 1 MiB before or after its entries."
            case .malformed: "The harness returned malformed native history."
            case .entryTooLarge: "A native history control record exceeds its in-memory limit."
            }
        }
    }

    static func inspect(_ file: URL, arrayDepth: Int = 2) async throws -> Metadata {
        try await scan(file, arrayDepth: arrayDepth, collectEntries: false, consume: { _, _ in })
    }

    /// Read bounded event metadata without materializing a large native JSON
    /// object. Identities following huge strings remain observable.
    static func inspectObject(_ file: URL) async throws -> ObjectMetadata {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256(), count = 0, depth = 0, inString = false, escaped = false, started = false
        var root = RootFields(), message = RootFields(), insideMessage = false
        while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation(); hash.update(data: chunk)
            for byte in chunk {
                count += 1
                if !started {
                    if isWhitespace(byte) { continue }
                    guard byte == 123 else { throw Failure.malformed }; started = true
                } else if depth == 0 {
                    guard isWhitespace(byte) else { throw Failure.malformed }; continue
                }
                if !inString, byte == 123, depth == 1, root.scalarKey == "message" {
                    insideMessage = true; message = RootFields()
                }
                root.consume(byte, depth: depth, inString: inString, escaped: escaped)
                if insideMessage { message.consume(byte, depth: depth, inString: inString, escaped: escaped, observedDepth: 2) }
                if inString {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { inString = false }
                } else if byte == 34 { inString = true }
                else if byte == 123 || byte == 91 { depth += 1 }
                else if byte == 125 || byte == 93 { depth -= 1 }
                if insideMessage, !inString, depth < 2 { insideMessage = false }
                guard depth >= 0 else { throw Failure.malformed }
            }
            await Task.yield()
        }
        guard started, depth == 0, !inString, !escaped else { throw Failure.malformed }
        return ObjectMetadata(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: count,
            scalars: root.values, messageScalars: message.values)
    }

    static func records(_ file: URL, expected: Metadata, arrayDepth: Int = 2,
                        consume: @escaping @Sendable (Record, Int) async throws -> Void) async throws {
        let actual = try await scan(file, arrayDepth: arrayDepth, collectEntries: true, consume: consume)
        guard actual.sha256 == expected.sha256, actual.envelope == expected.envelope,
              actual.count == expected.count else { throw Failure.malformed }
    }

    private enum Stage: Equatable { case prefix, entries, suffix }

    private static func scan(_ file: URL, arrayDepth: Int, collectEntries: Bool,
                             consume: @escaping @Sendable (Record, Int) async throws -> Void) async throws -> Metadata {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var stage = Stage.prefix
        var prefix = Data(), suffix = Data(), entry = Data(), keyToken = Data()
        var depth = 0, entryDepth = 0, count = 0, entryBytes = 0
        var inString = false, escaped = false, entryStarted = false, needsEntry = false
        var candidateKey: String?, arrayKey: String?, awaitingArray = false
        var hash = SHA256(), entryHash = SHA256()
        var position = 0, entryOffset = 0, hashChunk = Data()
        var oversized = false, fields = RootFields()
        while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
            for byte in chunk {
                let byteOffset = position; position += 1
                switch stage {
                case .prefix:
                    guard prefix.count < maximumEnvelopeBytes else { throw Failure.unsupportedEnvelope }
                    prefix.append(byte)
                    if inString {
                        if keyToken.count < 128 { keyToken.append(byte) }
                        if escaped { escaped = false }
                        else if byte == 92 { escaped = true }
                        else if byte == 34 {
                            inString = false
                            if depth == arrayDepth, keyToken.last == 34,
                               let value = try? JSONSerialization.jsonObject(with: keyToken, options: [.fragmentsAllowed]) as? String {
                                candidateKey = ["entries", "messages", "data"].contains(value) ? value : nil
                            }
                            keyToken.removeAll(keepingCapacity: true)
                        }
                        continue
                    }
                    if byte == 34 {
                        inString = true; keyToken = Data([34]); candidateKey = nil
                    } else if byte == 58, depth == arrayDepth {
                        awaitingArray = candidateKey != nil
                    } else if byte == 91, depth == arrayDepth, awaitingArray {
                        arrayKey = candidateKey
                        prefix.removeLast()
                        stage = .entries; inString = false; escaped = false
                        candidateKey = nil; awaitingArray = false
                    } else if !isWhitespace(byte) {
                        awaitingArray = false; candidateKey = nil
                        if byte == 123 || byte == 91 { depth += 1 }
                        else if byte == 125 || byte == 93 { depth -= 1 }
                        guard depth >= 0 else { throw Failure.malformed }
                    }
                case .entries:
                    if !inString, entryDepth == 0, byte == 44 || byte == 93 {
                        if entryStarted {
                            if collectEntries {
                                if oversized {
                                    if !hashChunk.isEmpty { entryHash.update(data: hashChunk) }
                                    let sha = entryHash.finalize().map { String(format: "%02x", $0) }.joined()
                                    try await consume(.reference(byteOffset: entryOffset, byteCount: entryBytes,
                                        sha256: sha, scalars: fields.values, nativeID: fields.id, kind: fields.kind), count)
                                } else {
                                    guard (try JSONSerialization.jsonObject(with: entry, options: [.fragmentsAllowed])) is [String: Any] else { throw Failure.malformed }
                                    try await consume(.inline(entry), count)
                                }
                            }
                            count += 1
                            entry.removeAll(keepingCapacity: false)
                            entryBytes = 0; entryStarted = false; needsEntry = false
                            hashChunk.removeAll(keepingCapacity: true)
                            oversized = false; entryHash = SHA256(); fields = RootFields()
                        } else if byte == 44 || needsEntry { throw Failure.malformed }
                        if byte == 93 { stage = .suffix }
                        else { needsEntry = true }
                        continue
                    }
                    if !entryStarted, isWhitespace(byte) { continue }
                    if !entryStarted { entryOffset = byteOffset }
                    entryStarted = true
                    entryBytes += 1
                    if collectEntries {
                        fields.consume(byte, depth: entryDepth, inString: inString, escaped: escaped)
                        if !oversized, entryBytes > maximumInlineEntryBytes {
                            entryHash.update(data: entry); entry.removeAll(keepingCapacity: false); oversized = true
                        }
                        if oversized {
                            hashChunk.append(byte)
                            if hashChunk.count == 64 * 1_024 { entryHash.update(data: hashChunk); hashChunk.removeAll(keepingCapacity: true) }
                        } else { entry.append(byte) }
                    }
                    if inString {
                        if escaped { escaped = false }
                        else if byte == 92 { escaped = true }
                        else if byte == 34 { inString = false }
                    } else if byte == 34 { inString = true }
                    else if byte == 123 || byte == 91 { entryDepth += 1 }
                    else if byte == 125 || byte == 93 { entryDepth -= 1 }
                    guard entryDepth >= 0 else { throw Failure.malformed }
                case .suffix:
                    guard suffix.count < maximumEnvelopeBytes else { throw Failure.unsupportedEnvelope }
                    suffix.append(byte)
                }
            }
            // Disk I/O and large single-record scanning never monopolize an
            // executor while other conversations or the UI need to progress.
            await Task.yield()
        }
        guard stage == .suffix, let arrayKey else { throw Failure.unsupportedEnvelope }
        var envelope = prefix
        envelope.append(contentsOf: [91, 93]); envelope.append(suffix)
        guard let object = try JSONSerialization.jsonObject(with: envelope) as? [String: Any] else { throw Failure.malformed }
        let container = arrayDepth == 1 ? object : object["data"] as? [String: Any]
        guard container?[arrayKey] is [Any] else { throw Failure.malformed }
        return Metadata(envelope: envelope, arrayKey: arrayKey, count: count,
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Observe bounded root scalar identities even when they follow a huge
    /// field. Never deserialize the oversized record or invent a native ID.
    private struct RootFields {
        var id: String?, kind: String?
        private var expectingKey = true, capturing = false
        var values: [String: String] = [:]
        private var pendingKey: String?, token = Data(), numeric = Data()
        var scalarKey: String? { expectingKey ? nil : pendingKey }
        mutating func consume(_ byte: UInt8, depth: Int, inString: Bool, escaped: Bool, observedDepth: Int = 1) {
            if inString {
                if capturing, token.count < 16 * 1_024 { token.append(byte) }
                if byte == 34, !escaped, depth == observedDepth {
                    if capturing, let value = try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String {
                        if expectingKey { pendingKey = ["id", "type", "role", "command", "toolCallId", "toolName", "stopReason", "errorMessage", "isError", "message"].contains(value) ? value : nil }
                        else if let pendingKey {
                            values[pendingKey] = value
                            if pendingKey == "id" { id = value }
                            if pendingKey == "type" { kind = value }
                        }
                    }
                    capturing = false; token.removeAll(keepingCapacity: true)
                }
                return
            }
            guard depth == observedDepth else { return }
            if byte == 34 {
                capturing = expectingKey || pendingKey != nil
                token = capturing ? Data([34]) : Data()
            } else if byte == 58 { expectingKey = false }
            else if byte == 44 || byte == 125 {
                if pendingKey == "id", !numeric.isEmpty,
                   let text = String(data: numeric, encoding: .utf8), let number = Double(text),
                   number >= 1, number <= 9_007_199_254_740_991, let integer = Int64(exactly: number) { id = String(integer) }
                if let pendingKey, !numeric.isEmpty { values[pendingKey] = String(decoding: numeric, as: UTF8.self) }
                numeric.removeAll(keepingCapacity: true); pendingKey = nil; expectingKey = true
            } else if pendingKey != nil, !expectingKey, numeric.count < 128, !isWhitespace(byte) { numeric.append(byte) }
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
}
