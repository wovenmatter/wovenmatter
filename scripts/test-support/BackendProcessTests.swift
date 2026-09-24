import Darwin
import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

// A provider-free host for the production IPC, invalidation and database boundary.
// This deliberately does not substitute for native ApplicationModel routing tests.
private actor FixtureOwner {
    let database: WorkspaceDatabase
    let journal = BackendInvalidationJournal()
    var shouldStop = false
    init(root: URL) throws { database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite")) }
    func handle(_ request: BackendRPCRequest) async -> BackendRPCResponse {
        do {
            switch request.method {
            case "admit":
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    do {
                        _ = try self.database.createFolder(name: "Completed after frontend exit")
                        await self.journal.publish(scopes: [.workspace])
                    } catch { fatalError("Fixture write failed: \(error)") }
                }
                return .init(id: request.id)
            case "changes":
                let cursor = try JSONDecoder().decode(BackendInvalidationCursor?.self, from: request.payload)
                return .init(id: request.id, result: try JSONEncoder().encode(await journal.waitForChanges(after: cursor, timeoutSeconds: 1)))
            case "stop":
                Task { try? await Task.sleep(for: .milliseconds(100)); self.shouldStop = true }
                return .init(id: request.id)
            default: return .init(id: request.id, error: "Unknown fixture command")
            }
        } catch { return .init(id: request.id, error: error.localizedDescription) }
    }
}

@main private struct BackendProcessTests {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "BackendProcessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func child(_ mode: String, root: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [mode, root.path]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }
    static func wait(_ process: Process) async throws {
        for _ in 0..<100 {
            if !process.isRunning { try require(process.terminationStatus == 0, "Child exited unsuccessfully"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        throw NSError(domain: "BackendProcessTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Child did not exit"])
    }
    static func ready(_ client: BackendRPCClient, process: Process) async throws {
        for _ in 0..<100 {
            if let identity = try? await client.ping() {
                try require(identity.processID == process.processIdentifier && identity.processID != getpid(), "RPC did not reach the separate backend")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw BackendRPCError.unavailable
    }
    static func main() async throws {
        if CommandLine.arguments.count == 3 {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let endpoint = root.appending(path: "control.sock")
            if CommandLine.arguments[1] == "backend" {
                let owner = try FixtureOwner(root: root)
                let server = BackendRPCServer(socketURL: endpoint)
                try server.start { await owner.handle($0) }
                while !(await owner.shouldStop) { try await Task.sleep(for: .milliseconds(25)) }
                server.stop()
                return
            }
            if CommandLine.arguments[1] == "frontend" {
                let projection = try DashboardStore(supportDirectory: root, readOnlyProjection: true)
                var refused = false
                do { _ = try projection.database.createFolder(name: "Forbidden frontend write") }
                catch { refused = true }
                try require(refused, "Read-only frontend accepted a database mutation")
                _ = try await BackendRPCClient(socketURL: endpoint).call(method: "admit")
                // Exit with work admitted but not yet written. No provider/runtime is launched.
                return
            }
        }
        let root = URL(fileURLWithPath: "/private/tmp/wm-process-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let client = BackendRPCClient(socketURL: root.appending(path: "control.sock"))
        var backend = try child("backend", root: root)
        defer { if backend.isRunning { backend.terminate() } }
        try await ready(client, process: backend)
        let initial = try JSONDecoder().decode(BackendInvalidations.self,
            from: await client.call(method: "changes", payload: JSONEncoder().encode(BackendInvalidationCursor?.none)))
        let frontend = try child("frontend", root: root)
        try await wait(frontend)
        try require(backend.isRunning, "Frontend exit stopped backend")
        let projection = try DashboardStore(supportDirectory: root, readOnlyProjection: true)
        let changed = try JSONDecoder().decode(BackendInvalidations.self,
            from: await client.call(method: "changes", payload: JSONEncoder().encode(initial.cursor)))
        try require(changed.scopes.contains(.workspace), "Detached completion did not publish invalidation")
        let snapshot = try await projection.snapshot()
        try require(snapshot.workspace.folders.contains { $0.name == "Completed after frontend exit" }, "Reconnected frontend did not observe backend result")
        try require(!snapshot.workspace.folders.contains { $0.name == "Forbidden frontend write" }, "Frontend altered backend data")
        _ = try await client.call(method: "stop")
        try await wait(backend)
        try require(!FileManager.default.fileExists(atPath: client.socketURL.path), "Orderly shutdown left a stale endpoint")
        backend = try child("backend", root: root)
        try await ready(client, process: backend)
        let restarted = try JSONDecoder().decode(BackendInvalidations.self,
            from: await client.call(method: "changes", payload: JSONEncoder().encode(changed.cursor)))
        try require(restarted.requiresReload && restarted.cursor.instanceID != changed.cursor.instanceID,
                    "Restart incorrectly reused previous invalidation cursor")
        let afterRestart = try await projection.snapshot()
        try require(afterRestart.workspace.folders.contains { $0.name == "Completed after frontend exit" }, "Restart lost persisted result")
        _ = try await client.call(method: "stop")
        try await wait(backend)
        print("Backend process boundary: passed (separate owner, frontend write exclusion, completion after client exit, reconnect, restart).")
    }
}
