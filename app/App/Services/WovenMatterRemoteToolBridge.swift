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
                        let response: Data
                        do { response = try WovenMatterCommandLine.forward(request, to: localSocket) }
                        catch { response = try JSONEncoder().encode(WovenMatterToolResponse(success: false, error: error.localizedDescription)) }
                        let result = ["id": id, "payload": response.base64EncodedString()]
                        var data = try JSONEncoder().encode(result)
                        data.append(10)
                        try input.write(contentsOf: data)
                    }
                }
            } catch { self?.gate.finish(.failure(error)) }
        }
    }

    func stop() {
        let shouldStop = lock.withLock {
            if stopped { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
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
