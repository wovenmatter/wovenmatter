import Darwin
import Foundation
import Testing
@testable import WovenMatterClient

struct BackendRPCTests {
    @Test func endpointRejectsSharedAndSymlinkedDirectories() async throws {
        let url = endpoint(), alias = endpoint()
        defer {
            try? FileManager.default.removeItem(at: alias.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let server = BackendRPCServer(socketURL: url)
        try server.start { BackendRPCResponse(id: $0.id, result: Data()) }
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.createSymbolicLink(at: alias.deletingLastPathComponent(),
            withDestinationURL: url.deletingLastPathComponent())
        await #expect(throws: BackendRPCError.self) {
            try await BackendRPCClient(socketURL: alias).call(method: "backend.ping")
        }
        #expect(throws: BackendRPCError.self) {
            try BackendRPCServer(socketURL: alias).start { BackendRPCResponse(id: $0.id, result: Data()) }
        }
        #expect(chmod(url.deletingLastPathComponent().path, 0o755) == 0)
        await #expect(throws: BackendRPCError.self) {
            try await BackendRPCClient(socketURL: url).call(method: "backend.ping")
        }
        #expect(chmod(url.deletingLastPathComponent().path, 0o700) == 0)
        #expect(try await BackendRPCClient(socketURL: url).ping().processID == getpid())
    }

    private func endpoint() -> URL {
        URL(fileURLWithPath: "/private/tmp/wm-rpc-" + UUID().uuidString.prefix(8)).appending(path: "control.sock")
    }

}
