import Darwin
import Foundation
import Testing
@testable import WovenMatterClient

struct BackendRPCTests {
    @Test func embeddedHTMLPageCanCrossTheBackendBoundary() async throws {
        let url = endpoint()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let server = BackendRPCServer(socketURL: url)
        try server.start { BackendRPCResponse(id: $0.id, result: $0.payload) }
        defer { server.stop() }
        let payload = Data(repeating: 65, count: 25 * 1024 * 1024)
        #expect(try await BackendRPCClient(socketURL: url).call(method: "html-fixture", payload: payload) == payload)
    }

    private func endpoint() -> URL {
        URL(fileURLWithPath: "/private/tmp/wm-rpc-" + UUID().uuidString.prefix(8)).appending(path: "control.sock")
    }

}
