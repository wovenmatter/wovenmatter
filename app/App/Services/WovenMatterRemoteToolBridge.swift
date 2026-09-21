import Foundation
import WovenMatterCore
import WovenMatterClient

/// SSH authenticates the existing workspace connection; the local endpoint binds
/// caller identity. Startup never blocks the main actor on a semaphore.
final class WovenMatterRemoteToolBridge: @unchecked Sendable {
    let remoteCLIPath: String
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let gate = WovenToolBridgeReady()
    private let lock = NSLock()
    private var stopped = false
    private var forwarder: WovenMatterRelayForwarder?

    private init(configuration: RemoteWorkspaceConfiguration, ownerID: UUID, source: String) throws {
        guard configuration.workspaceID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,47}$/) != nil else {
            throw WorkspaceToolError.invalid("Invalid workspace identity.")
        }
        let destination = try RemoteWorkspaceSSHClient.validatedDestination(hostName: configuration.hostName, userName: configuration.userName)
        let directory = "/home/.wmt/" + ownerID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + "/" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        remoteCLIPath = directory + "/wovenmatter"
        let encoded = Data(source.utf8).base64EncodedString()
        let bootstrap = "import base64; WOVENMATTER_SOURCE=base64.b64decode('\(encoded)').decode(); exec(compile(WOVENMATTER_SOURCE, '<wovenmatter>', 'exec'))"
        let command = ["docker", "exec", "--interactive", "wovenmatter-\(configuration.workspaceID)",
                       "python3", "-c", bootstrap, "--relay", directory].map(Self.quote).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", destination, command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    static func start(configuration: RemoteWorkspaceConfiguration, ownerID: UUID, localSocket: String, source: String) async throws -> WovenMatterRemoteToolBridge {
        let bridge = try WovenMatterRemoteToolBridge(configuration: configuration, ownerID: ownerID, source: source)
        try bridge.process.run()
        bridge.read(localSocket: localSocket)
        let timeout = Task { [weak bridge] in
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled {
                if bridge?.gate.finish(.failure(WovenNoteSocketError.timedOut)) == true { bridge?.stop() }
            }
        }
        defer { timeout.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await bridge.gate.wait()
                try Task.checkCancellation()
            } onCancel: { bridge.stop() }
            return bridge
        } catch { bridge.stop(); throw error }
    }

    var isRunning: Bool { lock.withLock { !stopped && process.isRunning } }

    private func read(localSocket: String) {
        let input = input, output = output
        let forwarder = WovenMatterRelayForwarder(localSocket: localSocket,
            write: { try input.write(contentsOf: $0) }, onFailure: { [weak self] _ in self?.stop() })
        let started = lock.withLock {
            guard !stopped else { return false }
            self.forwarder = forwarder
            return true
        }
        guard started else { forwarder.stop(); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.stop() }
            do {
                var pending = Data()
                while let chunk = try output.read(upToCount: 65_536), !chunk.isEmpty {
                    pending.append(chunk)
                    guard pending.count <= 8 * 1_024 * 1_024 else { throw WovenNoteSocketError.requestTooLarge }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        let packet = try JSONDecoder().decode(GatewayJSONValue.self, from: line)
                        if packet.objectValue?["ready"]?.boolValue == true { self?.gate.finish(.success(())); continue }
                        guard let id = packet.objectValue?["id"]?.stringValue, UUID(uuidString: id) != nil,
                              let payload = packet.objectValue?["payload"]?.stringValue,
                              let request = Data(base64Encoded: payload) else { throw WorkspaceToolError.invalid("Invalid tool relay packet.") }
                        try forwarder.submit(id: id, request: request)
                    }
                }
            } catch { self?.gate.finish(.failure(error)) }
        }
    }

    func stop() {
        let (shouldStop, forwarder) = lock.withLock {
            if stopped { return (false, nil as WovenMatterRelayForwarder?) }
            stopped = true
            let value = self.forwarder
            self.forwarder = nil
            return (true, value)
        }
        guard shouldStop else { return }
        forwarder?.stop()
        gate.finish(.failure(WorkspaceToolError.invalid("The remote tools connection closed.")))
        try? input.close()
        try? output.close()
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private final class WovenToolBridgeReady: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let existing: Result<Void, any Error>? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil as Result<Void, any Error>?
            }
            if let existing { continuation.resume(with: existing) }
        }
    }

    @discardableResult
    func finish(_ result: Result<Void, any Error>) -> Bool {
        let (won, waiter) = lock.withLock {
            guard self.result == nil else { return (false, nil as CheckedContinuation<Void, any Error>?) }
            self.result = result
            let value = continuation
            continuation = nil
            return (true, value)
        }
        waiter?.resume(with: result)
        return won
    }
}

/// One slow local call cannot block the relay reader or another request. Admission
/// is bounded like the remote listener; replies remain complete serialized lines.
final class WovenMatterRelayForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let localSocket: String
    private let timeout: TimeInterval
    private let maximumConnections: Int
    private let write: @Sendable (Data) throws -> Void
    private let onFailure: @Sendable (any Error) -> Void
    private var stopped = false
    private var active: [String: WovenToolForwardCancellation] = [:]
    private var writingID: String?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(localSocket: String, timeout: TimeInterval = 55, maximumConnections: Int = 4,
         write: @escaping @Sendable (Data) throws -> Void,
         onFailure: @escaping @Sendable (any Error) -> Void) {
        precondition(maximumConnections > 0 && timeout.isFinite && timeout > 0)
        self.localSocket = localSocket; self.timeout = timeout
        self.maximumConnections = maximumConnections; self.write = write; self.onFailure = onFailure
    }

    func submit(id: String, request: Data) throws {
        guard UUID(uuidString: id) != nil, request.count <= 4 * 1_024 * 1_024 else {
            throw WorkspaceToolError.invalid("Invalid tool relay packet.")
        }
        let cancellation = WovenToolForwardCancellation()
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            guard active[id] == nil, writingID != id, active.count < maximumConnections else {
                throw WorkspaceToolError.invalid("The tool relay already has its maximum in-flight requests.")
            }
            active[id] = cancellation
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var ownershipFinished = false
            defer { if !ownershipFinished { finished(id: id) } }
            do {
                let response: Data
                do {
                    response = try WovenMatterCommandLine.forward(request, to: localSocket,
                        timeout: timeout, cancellation: cancellation)
                } catch {
                    let requestID = (try? JSONDecoder().decode(WovenMatterToolRequest.self, from: request))?.requestID
                    response = try JSONEncoder().encode(WovenMatterToolResponse(success: false,
                        error: error.localizedDescription, requestID: requestID))
                }
                var packet = try JSONEncoder().encode(["id": id, "payload": response.base64EncodedString()])
                packet.append(10)
                try writeLock.withLock {
                    // Complete ownership before another writer takes over; the
                    // outer cleanup also handles errors before this boundary.
                    defer { finished(id: id); ownershipFinished = true }
                    let canWrite = lock.withLock {
                        guard !stopped else { return false }
                        // The peer can receive a complete line and replace its
                        // request before write returns. Retire the socket slot
                        // first; retain one bounded writer until it finishes.
                        active.removeValue(forKey: id)
                        writingID = id
                        return true
                    }
                    guard canWrite else { return }
                    do { try write(packet) }
                    catch {
                        // Retire the forwarder before waking idle waiters.
                        stop()
                        onFailure(error)
                    }
                }
            } catch { onFailure(error); stop() }
        }
    }

    private func finished(id: String) {
        let waiters = lock.withLock {
            active.removeValue(forKey: id)
            if writingID == id { writingID = nil }
            guard active.isEmpty, writingID == nil else { return [CheckedContinuation<Void, Never>]() }
            let values = idleWaiters; idleWaiters.removeAll(); return values
        }
        waiters.forEach { $0.resume() }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                guard !active.isEmpty || writingID != nil else { return true }
                idleWaiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }

    func stop() {
        let calls = lock.withLock {
            stopped = true
            return Array(active.values)
        }
        calls.forEach { $0.cancel() }
    }
}
