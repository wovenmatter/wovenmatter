import Darwin
import Foundation
import Testing
@testable import WovenMatterClient

struct BackendRPCTests {
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

    @Test func authenticatedRoundTripAndReadiness() async throws {
        let url = endpoint()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = BackendRPCServer(socketURL: url)
        try server.start { BackendRPCResponse(id: $0.id, result: $0.payload) }
        defer { server.stop() }
        let client = BackendRPCClient(socketURL: url)
        let identity = try await client.ping()
        #expect(identity.processID == getpid())
        #expect(identity.protocolVersion == 1)
        let data = Data("private payload".utf8)
        #expect(try await client.call(method: "echo", payload: data) == data)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func readinessProbeUsesShortDeadlineWithoutChangingNormalRequests() async throws {
        let url = endpoint()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = BackendRPCServer(socketURL: url)
        try server.start { request in
            try? await Task.sleep(for: .milliseconds(200))
            return BackendRPCResponse(id: request.id, result: Data("ready".utf8))
        }
        defer { server.stop() }
        let client = BackendRPCClient(socketURL: url)
        do {
            _ = try await client.call(method: "application.readiness", timeout: 0.05)
            Issue.record("Expected bounded readiness probe timeout")
        } catch BackendRPCError.timedOut {}
        #expect(try await client.call(method: "application.readiness") == Data("ready".utf8))
    }

    @Test func concurrentRequestsAndRestartRemainIsolated() async throws {
        let url = endpoint()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = BackendRPCServer(socketURL: url)
        try server.start { BackendRPCResponse(id: $0.id, result: $0.payload) }
        defer { server.stop() }
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
        try server.start { BackendRPCResponse(id: $0.id, result: Data("restarted".utf8)) }
        #expect(try await BackendRPCClient(socketURL: url).call(method: "echo") == Data("restarted".utf8))
    }

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
