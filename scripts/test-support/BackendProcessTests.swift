import Darwin
import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

// A provider-free host for the production IPC, invalidation and database boundary.
// This deliberately does not substitute for native ApplicationModel routing tests.
private actor FixtureOwner {
    let database: WorkspaceDatabase
    let root: URL
    let journal = BackendInvalidationJournal()
    var shouldStop = false
    var streamingRun: (conversationID: String, runID: String)?
    init(root: URL) async throws {
        self.root = root
        database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    }
    func handle(_ request: BackendRPCRequest) async -> BackendRPCResponse {
        do {
            switch request.method {
            case "stream":
                let id = try await database.createLocalACPSession(runtimeKind: .codex,
                    title: "Streaming fixture", ownerDeviceID: UUID(), executionRoot: .init(folderID: nil,
                        location: .init(workspaceID: "local", rootPath: root.path, managed: false), defaultPath: root.path))
                let run = try await database.beginLocalACPRun(conversationID: id, input: .init(text: "Fixture only"))
                streamingRun = (id, run.runID)
                try await database.upsertRunActivity(runID: run.runID,
                    activity: .init(id: "shell", kind: .tool, phase: "update", title: "Shell",
                        status: "in_progress", content: "progress one 🧵"))
                await journal.publish(conversationIDs: [id])
                return .init(id: request.id, result: try JSONEncoder().encode(id))
            case "finishStream":
                guard let run = streamingRun else { throw BackendRPCError.unavailable }
                try await database.upsertRunActivity(runID: run.runID,
                    activity: .init(id: "shell", kind: .tool, phase: "end", status: "completed",
                        content: "progress one 🧵\nprogress two"))
                try await database.completeLocalACPRun(runID: run.runID)
                await journal.publish(conversationIDs: [run.conversationID])
                streamingRun = nil
                return .init(id: request.id)
            case "admit":
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    do {
                        _ = try await self.database.createFolder(name: "Completed after frontend exit", location: .init(workspaceID: "device:test", rootPath: "/tmp", managed: false))
                        await self.journal.publish(scopes: [.workspace])
                    } catch { fatalError("Fixture write failed: \(error)") }
                }
                return .init(id: request.id)
            case "stop":
                Task { try? await Task.sleep(for: .milliseconds(100)); self.shouldStop = true }
                return .init(id: request.id)
            default: return .init(id: request.id, error: "Unknown fixture command")
            }
        } catch { return .init(id: request.id, error: error.localizedDescription) }
    }
}

/// A window stream with no conversations of its own: `server.state` only.
@MainActor private final class EmptyConversations: ExecutionConversationSource {
    func localTranscript(conversationID: String, before: String?) async throws -> LibraryTranscript {
        throw LibraryAPIError(code: "wrong_workspace", message: "Fixture only.")
    }
    func localCapabilities(conversationID: String) async throws -> HarnessCapabilities {
        throw LibraryAPIError(code: "wrong_workspace", message: "Fixture only.")
    }
    func localSessionSettings(conversationID: String) async throws -> SessionSettings {
        throw LibraryAPIError(code: "wrong_workspace", message: "Fixture only.")
    }
}

/// The window's side of the persistent stream, frame by frame.
private final class WindowStream: @unchecked Sendable {
    let channel: BackendStreamChannel
    private var buffer = Data()
    private var frames: [StreamFrame] = []
    init(_ socket: URL) async throws { channel = try await BackendRPCClient(socketURL: socket).openStream() }
    func send(_ frame: StreamFrame) async throws { try await channel.write(StreamProtocol.lengthPrefixed(frame)) }
    func next() async throws -> StreamFrame {
        while frames.isEmpty {
            guard let bytes = try await channel.read() else { throw BackendRPCError.unavailable }
            buffer.append(bytes)
            frames = try StreamProtocol.takeLengthPrefixedFrames(from: &buffer)
        }
        return frames.removeFirst()
    }
    /// Subscribes to `server.state`; the first item is `synchronized`.
    func followServerState() async throws {
        guard case .hello = try await next() else { throw BackendRPCError.invalidFrame }
        try await send(.subscribe(.init(id: "state", stream: .serverState)))
        guard case .item(let item) = try await next(), item.payload == .synchronized else { throw BackendRPCError.invalidFrame }
    }
    /// Reads `server.state` items up to the first naming `scope`, and returns
    /// every conversation they named on the way.
    @discardableResult
    func serverState(_ scope: String) async throws -> Set<String> {
        var conversations: Set<String> = []
        for _ in 0..<50 {
            guard case .item(let item) = try await next(), case .serverState(let state) = item.payload else { continue }
            conversations.formUnion(state.conversationIDs ?? [])
            if state.scopes.contains(scope) { return conversations }
        }
        throw BackendRPCError.timedOut
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
                let owner = try await FixtureOwner(root: root)
                let server = BackendRPCServer(socketURL: endpoint)
                let source = await MainActor.run { EmptyConversations() }
                let window = ExecutionWindowStreamServer(database: owner.database, source: source) {
                    StreamHello(deviceID: "backend", libraryID: "fixture", workspaceID: "fixture", serverTime: MemberRequestSignature.now())
                }
                await window.start()
                let feed = window.serverState
                await owner.journal.setListener { scopes, ids in
                    await feed.publish(.init(scopes: scopes.map(\.rawValue).sorted(), conversationIDs: ids.isEmpty ? nil : ids.sorted()))
                }
                try server.start(handler: { await owner.handle($0) }, stream: { window.accept($0) })
                while !(await owner.shouldStop) { try await Task.sleep(for: .milliseconds(25)) }
                server.stop()
                return
            }
            if CommandLine.arguments[1] == "frontend" {
                let projection = try await LibraryStore(supportDirectory: root, readOnlyProjection: true)
                var refused = false
                do { _ = try await projection.database.createFolder(name: "Forbidden frontend write", location: .init(workspaceID: "device:test", rootPath: "/tmp", managed: false)) }
                catch { refused = true }
                try require(refused, "Read-only frontend accepted a database mutation")
                _ = try await BackendRPCClient(socketURL: endpoint).call(method: "admit")
                _ = try await BackendRPCClient(socketURL: endpoint).call(method: "stream")
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
        // The window's persistent stream crosses the process boundary on the same socket.
        let stream = try await WindowStream(client.socketURL)
        try await stream.followServerState()
        let frontend = try child("frontend", root: root)
        try await wait(frontend)
        try require(backend.isRunning, "Frontend exit stopped backend")
        let projection = try await LibraryStore(supportDirectory: root, readOnlyProjection: true)
        // Invalidations reach the window as they are published, never by asking.
        let observedConversations: Set<String>
        do { observedConversations = try await stream.serverState("workspace") }
        catch { throw NSError(domain: "BackendProcessTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Detached completion did not publish invalidation"]) }
        let snapshot = try await projection.snapshot()
        try require(snapshot.workspace.folders.contains { $0.name == "Completed after frontend exit" }, "Reconnected frontend did not observe backend result")
        try require(!snapshot.workspace.folders.contains { $0.name == "Forbidden frontend write" }, "Frontend altered backend data")
        let streamingID = try await projection.database.workspaceOverview().conversations.first {
            $0.title == "Streaming fixture"
        }?.id
        try require(streamingID != nil, "Detached client lost its active conversation")
        try require(observedConversations.contains(streamingID!), "Live transcript write did not notify the frontend")
        let active = try await projection.database.conversationHistoryPage(id: streamingID!, limit: 20, compactActivities: true)
        try require(active.activities.contains { $0.activity.content == "progress one 🧵" && $0.activity.status == "in_progress" },
                    "Read-only frontend could not observe output before completion")
        _ = try await client.call(method: "finishStream")
        let settled = try await projection.database.conversationHistoryPage(id: streamingID!, limit: 20,
            compactActivities: true, activityCursor: active.activityRevision, knownActivityRunIDs: active.runs.map(\.id))
        try require(settled.activities.contains { $0.activity.content == "progress one 🧵\nprogress two" && $0.activity.status == "completed" },
                    "Read-only frontend missed the terminal output delta")
        _ = try await client.call(method: "stop")
        try await wait(backend)
        try require(!FileManager.default.fileExists(atPath: client.socketURL.path), "Orderly shutdown left a stale endpoint")
        var streamEnded = false
        do { while true { _ = try await stream.next() } } catch { streamEnded = true }
        try require(streamEnded, "The window stream outlived its server")
        backend = try child("backend", root: root)
        try await ready(client, process: backend)
        // A new server starts every window from `synchronized`: read everything again.
        try await WindowStream(client.socketURL).followServerState()
        let afterRestart = try await projection.snapshot()
        try require(afterRestart.workspace.folders.contains { $0.name == "Completed after frontend exit" }, "Restart lost persisted result")
        _ = try await client.call(method: "stop")
        try await wait(backend)
        print("Backend process boundary: passed (separate owner, frontend write exclusion, live transcript/terminal delta after client exit, window stream, reconnect, restart).")
    }
}
