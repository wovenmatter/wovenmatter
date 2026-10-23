import Darwin
import Foundation
import Testing
@testable import WovenMatterClient

struct BackendRPCTests {

    @Test func rejectsPublicDirectoryAndExistingSocket() async throws {
        let url = endpoint()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        chmod(url.deletingLastPathComponent().path, 0o755)
        let server = BackendRPCServer(socketURL: url)
        #expect(throws: BackendRPCError.self) { try server.start { BackendRPCResponse(id: $0.id) } }
        chmod(url.deletingLastPathComponent().path, 0o700)
        try server.start { BackendRPCResponse(id: $0.id) }
        defer { server.stop() }
        let second = BackendRPCServer(socketURL: url)
        #expect(throws: BackendRPCError.self) { try second.start { BackendRPCResponse(id: $0.id) } }
        #expect(try await BackendRPCClient(socketURL: url).ping().processID == getpid())
    }

    private func endpoint() -> URL {
        URL(fileURLWithPath: "/private/tmp/wm-rpc-" + UUID().uuidString.prefix(8)).appending(path: "control.sock")
    }

    @Test func retryIdentityBindsMethodAndPayloadWithoutRequestID() {
        let first = BackendRPCRequest(id: "same", method: "application.command", payload: Data("note".utf8))
        let sameCommand = BackendRPCRequest(id: "other", method: first.method, payload: first.payload)
        let otherMethod = BackendRPCRequest(id: first.id, method: "remoteWorkspaces.command", payload: first.payload)
        let otherContent = BackendRPCRequest(id: first.id, method: first.method, payload: Data("changed note".utf8))
        #expect(BackendRPCCommandIdentity(first) == BackendRPCCommandIdentity(sameCommand))
        #expect(BackendRPCCommandIdentity(first) != BackendRPCCommandIdentity(otherMethod))
        #expect(BackendRPCCommandIdentity(first) != BackendRPCCommandIdentity(otherContent))
    }

    @Test func authenticatedConcurrentRequestsAndRestartRemainIsolated() async throws {
        let url = endpoint()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = BackendRPCServer(socketURL: url)
        try server.start { BackendRPCResponse(id: $0.id, result: $0.payload) }
        defer { server.stop() }
        let identity = try await BackendRPCClient(socketURL: url).ping()
        #expect(identity.processID == getpid())
        #expect(identity.protocolVersion == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let payload = Data("request-\(index)".utf8)
                    let response = try await BackendRPCClient(socketURL: url).call(method: "echo", payload: payload)
                    #expect(response == payload)
                }
            }
            try await group.waitForAll()
        }
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try server.start { BackendRPCResponse(id: $0.id, result: Data("restarted".utf8)) }
        #expect(try await BackendRPCClient(socketURL: url).call(method: "echo") == Data("restarted".utf8))
    }

    @Test func remoteErrorsAndOversizedFramesFailClosed() async throws {
        let url = endpoint()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = BackendRPCServer(socketURL: url)
        try server.start { BackendRPCResponse(id: $0.id, error: "Unavailable command") }
        defer { server.stop() }
        let client = BackendRPCClient(socketURL: url)
        await #expect(throws: BackendRPCError.self) { try await client.call(method: "unknown") }
        await #expect(throws: BackendRPCError.self) {
            try await client.call(method: "oversized", payload: Data(repeating: 0, count: 8 * 1024 * 1024))
        }
    }
}
