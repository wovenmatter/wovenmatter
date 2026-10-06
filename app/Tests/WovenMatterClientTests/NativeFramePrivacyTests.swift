import CryptoKit
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

@Suite(.timeLimit(.minutes(2)))
struct NativeFramePrivacyTests {
    @Test(arguments: [1, 2, 7, 127, 64 * 1_024])
    func matchesCoreRedactionAcrossEverySmallDiskBoundary(chunkBytes: Int) async throws {
        let fixture = try NativePrivacyFixture()
        defer { fixture.remove() }
        let hex = String(repeating: "a1", count: 16), other = String(repeating: "F0", count: 16)
        let local = "/private/tmp/wmtools-" + hex + "/" + other + ".sock"
        let remote = "/home/.wmt/" + other + "/" + hex + "/rpc.sock"
        let rpc = remote.replacingOccurrences(of: "rpc.sock", with: "wovenmatter")
        let slashes = ["/", "\\/", "\\\\\\\\/", String(repeating: "\\", count: 258) + "/"]
        let text = "🧵日本語 {\"token\":\"ordinary native content\",\"headers\":{\"Authorization\":\"native tool output\"}}\n"
            + slashes.flatMap { slash in [local, remote, rpc].map { $0.replacingOccurrences(of: "/", with: slash) } }.joined(separator: " 🌈 ")
            + "\n" + local + "-suffix " + local.replacingOccurrences(of: hex, with: hex + "a")
            + " /private/tmp/wmtools-" + hex + "/short.sock /home/.wmt/" + hex + "/" + other + "/different"
        let bytes = Data(text.utf8)
        try bytes.write(to: fixture.input)
        let copy = try await NativeFramePrivacy.prepare(fixture.input, expectedSHA256: NativeHarnessArchive.digest(bytes),
            byteCount: bytes.count, readChunkBytes: chunkBytes, temporaryDirectory: fixture.output)
        defer { if copy.redacted { try? FileManager.default.removeItem(at: copy.file) } }
        #expect(copy.redacted)
        let saved = try Data(contentsOf: copy.file)
        #expect(saved == Data(WorkspaceHistoryPrivacy.redactingToolEndpoints(text).utf8))
        #expect(copy.sha256 == NativeHarnessArchive.digest(saved))
        #expect(copy.byteCount == saved.count)
        #expect(try Data(contentsOf: fixture.input) == bytes)
        #expect(String(decoding: saved, as: UTF8.self).contains("ordinary native content"))
        #expect(String(decoding: saved, as: UTF8.self).contains("native tool output"))
        #expect((try FileManager.default.attributesOfItem(atPath: copy.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func unchangedBytesKeepOriginalFileWithoutCreatingSpool() async throws {
        let fixture = try NativePrivacyFixture()
        defer { fixture.remove() }
        let bytes = Data("  { \"token\": \"unchanged🧵\", \"content\": [\"/private/tmp/plain.sock\", \"\\\\/path\", \"é日本語\"] }\r\n".utf8)
        try bytes.write(to: fixture.input)
        let copy = try await NativeFramePrivacy.prepare(fixture.input, expectedSHA256: NativeHarnessArchive.digest(bytes),
            byteCount: bytes.count, readChunkBytes: 7, temporaryDirectory: fixture.output)
        #expect(!copy.redacted && copy.file == fixture.input)
        #expect(copy.byteCount == bytes.count && copy.sha256 == NativeHarnessArchive.digest(bytes))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
        #expect(try Data(contentsOf: fixture.input) == bytes)
    }

    @Test func escapeRunsCanSpanManyChunksWithoutHoldingTheirBytes() async throws {
        let fixture = try NativePrivacyFixture()
        defer { fixture.remove() }
        let hex = String(repeating: "a", count: 32)
        let text = "prefix🧵" + String(repeating: "\\", count: 256 * 1_024)
            + "/private/tmp/wmtools-" + hex + "/" + hex + ".sock suffixé"
        let bytes = Data(text.utf8)
        try bytes.write(to: fixture.input)
        let copy = try await NativeFramePrivacy.prepare(fixture.input, expectedSHA256: NativeHarnessArchive.digest(bytes),
            byteCount: bytes.count, readChunkBytes: 127, temporaryDirectory: fixture.output)
        defer { try? FileManager.default.removeItem(at: copy.file) }
        #expect(try Data(contentsOf: copy.file) == Data(WorkspaceHistoryPrivacy.redactingToolEndpoints(text).utf8))
        #expect(copy.byteCount < 100)
    }

    @Test func failedSourceVerificationRemovesPrivateCopy() async throws {
        let fixture = try NativePrivacyFixture()
        defer { fixture.remove() }
        let hex = String(repeating: "a", count: 32)
        let bytes = Data(("/home/.wmt/" + hex + "/" + hex + "/wovenmatter").utf8)
        try bytes.write(to: fixture.input)
        await #expect(throws: (any Error).self) {
            try await NativeFramePrivacy.prepare(fixture.input, expectedSHA256: String(repeating: "0", count: 64),
                byteCount: bytes.count, readChunkBytes: 7, temporaryDirectory: fixture.output)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
        #expect(try Data(contentsOf: fixture.input) == bytes)
    }

    @Test func cancellationRemovesCopyWhileOriginalRemains() async throws {
        let fixture = try NativePrivacyFixture()
        defer { fixture.remove() }
        let hex = String(repeating: "a", count: 32)
        let prefix = Data(("/home/.wmt/" + hex + "/" + hex + "/rpc.sock").utf8)
        let source = try writeLargeNativePrivacyInput(fixture.input, prefix: prefix, suffix: Data())
        let operation = Task {
            try await NativeFramePrivacy.prepare(fixture.input, expectedSHA256: source.sha256,
                byteCount: source.count, readChunkBytes: 4 * 1_024, temporaryDirectory: fixture.output)
        }
        var observedCopy = false
        for _ in 0..<1_000 {
            if !(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path)).isEmpty {
                observedCopy = true; break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(observedCopy)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
        #expect(try hashNativePrivacyFile(fixture.input).sha256 == source.sha256)
    }
}

private struct NativePrivacyFixture: Sendable {
    let root: URL, input: URL, output: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("woven-native-privacy-test-" + UUID().uuidString)
        input = root.appendingPathComponent("native.json")
        output = root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func writeLargeNativePrivacyInput(_ file: URL, prefix: Data, suffix: Data) throws -> (count: Int, sha256: String) {
    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let writer = try FileHandle(forWritingTo: file)
    defer { try? writer.close() }
    let chunk = Data(repeating: 97, count: 64 * 1_024)
    var hash = SHA256(), count = 0
    func write(_ bytes: Data) throws { try writer.write(contentsOf: bytes); hash.update(data: bytes); count += bytes.count }
    try write(prefix)
    for _ in 0..<1_025 { try write(chunk) }
    try write(suffix)
    return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
}

private func hashNativePrivacyFile(_ file: URL) throws -> (count: Int, sha256: String) {
    let reader = try FileHandle(forReadingFrom: file)
    defer { try? reader.close() }
    var hash = SHA256(), count = 0
    while let bytes = try reader.read(upToCount: 64 * 1_024), !bytes.isEmpty {
        hash.update(data: bytes); count += bytes.count
    }
    return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
}
