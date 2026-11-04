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
