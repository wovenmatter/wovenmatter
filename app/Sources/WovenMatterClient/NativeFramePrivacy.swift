import CryptoKit
import Darwin
import Foundation

/// Redact only Woven's generated bearer endpoint paths. The matcher operates
/// on bytes, including JSON's arbitrarily escaped slashes, without parsing or
/// materializing native records. Ordinary content and UTF-8 bytes stay intact.
enum NativeFramePrivacy {
    struct Copy: Sendable {
        let file: URL
        let byteCount: Int
        let sha256: String
        let redacted: Bool
    }

    static func prepare(_ file: URL, expectedSHA256: String, byteCount: Int,
                        readChunkBytes: Int = 64 * 1_024,
                        temporaryDirectory: URL = FileManager.default.temporaryDirectory) async throws -> Copy {
        guard byteCount >= 0, (1...64 * 1_024).contains(readChunkBytes) else {
            throw PiNativeHistoryFrame.Failure.malformed
        }
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var output: FileHandle?, temporary: URL?, preserveTemporary = false
        defer {
            try? output?.close()
            if let temporary, !preserveTemporary { try? FileManager.default.removeItem(at: temporary) }
        }
        var matcher = NativeEndpointMatcher(), sourceHash = SHA256()
        var sourceOffset = 0, outputOffset = 0, lengthDelta = 0
        let replacement = Data("[Woven Matter session tool endpoint]".utf8)
        while let bytes = try input.read(upToCount: readChunkBytes), !bytes.isEmpty {
            try Task.checkCancellation()
            guard sourceOffset <= byteCount, bytes.count <= byteCount - sourceOffset else {
                throw PiNativeHistoryFrame.Failure.malformed
            }
            sourceHash.update(data: bytes)
            var matches: [Range<Int>] = []
            matches.reserveCapacity(8)
            for (index, byte) in bytes.enumerated() {
                if let match = matcher.consume(byte, at: sourceOffset + index) { matches.append(match) }
            }
            var unwritten = sourceOffset
            for match in matches {
                try Task.checkCancellation()
                if output == nil {
                    let url = temporaryDirectory.appendingPathComponent("woven-native-safe-" + UUID().uuidString)
                    let descriptor = url.path.withCString {
                        Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
                    }
                    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    temporary = url; output = writer
                    // The source prefix may be much larger than memory. It is
                    // copied only after the first actual endpoint is identified.
                    try await copyPrefix(file, count: match.lowerBound, to: writer, chunkBytes: readChunkBytes)
                    outputOffset = match.lowerBound
                } else if match.lowerBound < unwritten {
                    // A slash escape run can extend over arbitrarily many
                    // chunks. Rewind the private output rather than buffering it.
                    let rewind = match.lowerBound + lengthDelta
                    guard rewind >= 0, rewind <= outputOffset else { throw PiNativeHistoryFrame.Failure.malformed }
                    try output!.truncate(atOffset: UInt64(rewind))
                    try output!.seek(toOffset: UInt64(rewind))
                    outputOffset = rewind
                } else {
                    let start = unwritten - sourceOffset, end = match.lowerBound - sourceOffset
                    if start < end {
                        try output!.write(contentsOf: bytes.subdata(in: start..<end))
                        outputOffset += end - start
                    }
                }
                try output!.write(contentsOf: replacement)
                outputOffset += replacement.count
                lengthDelta += replacement.count - match.count
                unwritten = match.upperBound
            }
            if let output {
                let start = unwritten - sourceOffset
                if start < bytes.count {
                    try output.write(contentsOf: bytes.subdata(in: start..<bytes.count))
                    outputOffset += bytes.count - start
                }
            }
            sourceOffset += bytes.count
            await Task.yield()
        }
        let actualSourceHash = digest(sourceHash.finalize())
        guard sourceOffset == byteCount, actualSourceHash == expectedSHA256 else {
            throw PiNativeHistoryFrame.Failure.malformed
        }
        try Task.checkCancellation()
        guard let output, let temporary else {
            return Copy(file: file, byteCount: byteCount, sha256: actualSourceHash, redacted: false)
        }
        try output.synchronize()
        try output.close()
        let sanitizedHash = try await hashFile(temporary, expectedBytes: outputOffset, chunkBytes: readChunkBytes)
        try Task.checkCancellation()
        preserveTemporary = true
        return Copy(file: temporary, byteCount: outputOffset, sha256: sanitizedHash, redacted: true)
    }

    private static func copyPrefix(_ file: URL, count: Int, to output: FileHandle, chunkBytes: Int) async throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: min(remaining, chunkBytes)), !bytes.isEmpty else {
                throw PiNativeHistoryFrame.Failure.malformed
            }
            try output.write(contentsOf: bytes)
            remaining -= bytes.count
            await Task.yield()
        }
    }

    private static func hashFile(_ file: URL, expectedBytes: Int, chunkBytes: Int) async throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256(), count = 0
        while let bytes = try input.read(upToCount: chunkBytes), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes); count += bytes.count
            await Task.yield()
        }
        guard count == expectedBytes else { throw PiNativeHistoryFrame.Failure.malformed }
        return digest(hash.finalize())
    }

    private static func digest(_ value: SHA256.Digest) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }
}

/// The same byte grammar as WorkspaceHistoryPrivacy.redactingToolEndpoints:
/// slash = backslash* '/', followed by the exact local or remote endpoint path.
/// Only offsets and constant-sized pattern state are retained between chunks.
private struct NativeEndpointMatcher {
    private enum Token {
        case literal([UInt8]), slash, hex32, remoteTail
    }
    private enum Stage { case seeking, prefix, matching }
    private static let local: [Token] = [
        .literal(Array("private".utf8)), .slash, .literal(Array("tmp".utf8)), .slash,
        .literal(Array("wmtools-".utf8)), .hex32, .slash, .hex32, .literal(Array(".sock".utf8)),
    ]
    private static let remote: [Token] = [
        .literal(Array("home".utf8)), .slash, .literal(Array(".wmt".utf8)), .slash,
        .hex32, .slash, .hex32, .slash, .remoteTail,
    ]
    private static let woven = Array("wovenmatter".utf8), rpc = Array("rpc.sock".utf8)
    private var stage = Stage.seeking
    private var escapeRunStart: Int?
    private var matchStart = 0, tokenIndex = 0, literalIndex = 0
    private var tokens: [Token] = [], tail: [UInt8] = []

    mutating func consume(_ byte: UInt8, at offset: Int) -> Range<Int>? {
        switch stage {
        case .seeking:
            seek(byte, at: offset)
        case .prefix:
            if byte == 112 { tokens = Self.local; stage = .matching; literalIndex = 1 }
            else if byte == 104 { tokens = Self.remote; stage = .matching; literalIndex = 1 }
            else { reset(); seek(byte, at: offset) }
        case .matching:
            switch tokens[tokenIndex] {
            case .slash:
                if byte == 47 { return advance(through: offset) }
                if byte != 92 { reset(); seek(byte, at: offset) }
            case .hex32:
                if (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) {
                    literalIndex += 1
                    if literalIndex == 32 { return advance(through: offset) }
                } else { reset(); seek(byte, at: offset) }
            case .literal(let literal):
                if byte == literal[literalIndex] {
                    literalIndex += 1
                    if literalIndex == literal.count { return advance(through: offset) }
                } else { reset(); seek(byte, at: offset) }
            case .remoteTail:
                if tail.isEmpty {
                    if byte == 119 { tail = Self.woven }
                    else if byte == 114 { tail = Self.rpc }
                    else { reset(); seek(byte, at: offset); return nil }
                }
                if byte == tail[literalIndex] {
                    literalIndex += 1
                    if literalIndex == tail.count { return advance(through: offset) }
                } else { reset(); seek(byte, at: offset) }
            }
        }
        return nil
    }

    private mutating func advance(through offset: Int) -> Range<Int>? {
        tokenIndex += 1; literalIndex = 0
        if tokenIndex == tokens.count {
            let match = matchStart..<(offset + 1)
            reset()
            return match
        }
        return nil
    }

    private mutating func reset() {
        stage = .seeking; escapeRunStart = nil; tokenIndex = 0; literalIndex = 0; tail = []
    }

    private mutating func seek(_ byte: UInt8, at offset: Int) {
        if byte == 92 { if escapeRunStart == nil { escapeRunStart = offset } }
        else if byte == 47 {
            matchStart = escapeRunStart ?? offset; escapeRunStart = nil
            stage = .prefix; tokenIndex = 0; literalIndex = 0
        } else { escapeRunStart = nil }
    }
}
