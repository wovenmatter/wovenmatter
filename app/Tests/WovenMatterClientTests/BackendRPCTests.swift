#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import Testing
@testable import WovenMatterClient

struct BackendRPCTests {
    @Test func aNeverStartedEndpointIsUnavailable() async throws {
        do {
            _ = try await BackendRPCClient(socketURL: endpoint()).ping()
            Issue.record("A missing service answered")
        } catch BackendRPCError.unavailable { }
    }

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

    /// A caller waits a bounded time; a slow handler's late reply is dropped without
    /// holding the server, which keeps answering.
    @Test func aCallerThatStopsWaitingLeavesTheServerServing() async throws {
        let url = endpoint(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = BackendRPCServer(socketURL: url)
        try server.start { request in
            if request.method == "slow" { try? await Task.sleep(for: .milliseconds(600)) }
            return BackendRPCResponse(id: request.id, result: Data(request.method.utf8))
        }
        defer { server.stop() }
        let client = BackendRPCClient(socketURL: url)
        await #expect(throws: BackendRPCError.self) { try await client.call(method: "slow", timeout: 0.2) }
        // A handler that finishes inside the caller's wait is answered, however long it took.
        #expect(try await client.call(method: "slow", timeout: 5) == Data("slow".utf8))
        try await Task.sleep(for: .milliseconds(700))
        #expect(try await client.call(method: "fast") == Data("fast".utf8))
        #expect(BackendRPCClient.maximumWait == 30)
    }

    private func endpoint() -> URL {
        // /tmp is a symlink on macOS, which the endpoint refuses; Linux has no /private.
        #if os(macOS)
        let base = "/private/tmp/wm-rpc-"
        #else
        let base = "/tmp/wm-rpc-"
        #endif
        return URL(fileURLWithPath: base + UUID().uuidString.prefix(8)).appending(path: "control.sock")
    }

}
