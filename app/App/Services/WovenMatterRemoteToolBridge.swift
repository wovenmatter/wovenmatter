import Foundation
import WovenMatterCore
import WovenMatterClient

/// The workspace exposes authenticated HTTP MCP inside its own container. The
/// existing SSH connection carries complete requests to the owning Mac; neither
/// a shell CLI nor a workspace filesystem socket grants tool authority.
final class WovenMCPRemoteBridge: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let localConnection: WovenMCPConnection
    private let gate = WovenMCPBridgeReady()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var stopped = false
    private var connection: WovenMCPConnection?
    private var requests: [String: Task<Void, Never>] = [:]

    var remoteConnection: WovenMCPConnection {
        get throws {
            try lock.withLock {
                guard let connection, !stopped else { throw WorkspaceToolError.invalid("The remote Woven MCP endpoint is unavailable.") }
                return connection
            }
        }
    }

    private init(configuration: RemoteWorkspaceConfiguration, localConnection: WovenMCPConnection, source: String) throws {
        guard configuration.workspaceID.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,47}$/) != nil else {
            throw WorkspaceToolError.invalid("Invalid workspace identity.")
        }
        guard let endpoint = URL(string: localConnection.endpointURL),
              endpoint.scheme == "https" || (endpoint.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(endpoint.host ?? "")),
              endpoint.user == nil, endpoint.password == nil else {
            throw WorkspaceToolError.invalid("The Woven MCP endpoint must use HTTPS or loopback HTTP.")
        }
        let destination = try RemoteWorkspaceSSHClient.validatedDestination(hostName: configuration.hostName, userName: configuration.userName)
        let encoded = Data(source.utf8).base64EncodedString()
        let bootstrap = "const m=await import('data:text/javascript;base64,\(encoded)');await m.runMCPRelay();"
        let command = ["docker", "exec", "--interactive", "wovenmatter-\(configuration.workspaceID)",
                       "node", "--input-type=module", "-e", bootstrap].map(Self.quote).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", destination, command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        self.process = process; self.localConnection = localConnection
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
    }

    static func start(configuration: RemoteWorkspaceConfiguration, localConnection: WovenMCPConnection) async throws -> WovenMCPRemoteBridge {
        guard let sourceURL = Bundle.main.resourceURL?.appending(path: "mcp-relay.mjs") else {
            throw WorkspaceToolError.invalid("The bundled Woven MCP remote transport is missing.")
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let bridge = try WovenMCPRemoteBridge(configuration: configuration, localConnection: localConnection, source: source)
        try bridge.process.run()
        bridge.read()
        try bridge.write(.object(["type": .string("configure"), "bearerToken": .string(localConnection.bearerToken)]))
        let timeout = Task { [weak bridge] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            bridge?.gate.finish(.failure(WorkspaceToolError.invalid("The remote Woven MCP endpoint did not start.")))
            bridge?.stop()
        }
        defer { timeout.cancel() }
        do {
            try await withTaskCancellationHandler { try await bridge.gate.wait(); try Task.checkCancellation() }
                onCancel: { bridge.stop() }
            return bridge
        } catch { bridge.stop(); throw error }
    }

    var isRunning: Bool { lock.withLock { !stopped && process.isRunning } }

    private func write(_ packet: GatewayJSONValue) throws {
        var bytes = try JSONEncoder().encode(packet); bytes.append(10)
        try writeLock.withLock { try input.write(contentsOf: bytes) }
    }

    private func read() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer { stop() }
            do {
                var pending = Data()
                while let chunk = try output.read(upToCount: 65_536), !chunk.isEmpty {
                    pending.append(chunk)
                    guard pending.count <= 8 * 1_024 * 1_024 else { throw WorkspaceToolError.invalid("The MCP relay frame is too large.") }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                        let packet = try JSONDecoder().decode(GatewayJSONValue.self, from: line)
                        guard let object = packet.objectValue, let type = object["type"]?.stringValue else { throw WorkspaceToolError.invalid("Invalid MCP relay frame.") }
                        if type == "ready" {
                            guard let endpoint = object["endpointURL"]?.stringValue, let url = URL(string: endpoint),
                                  url.scheme == "http", url.host == "127.0.0.1", url.path == "/mcp", url.port != nil,
                                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                                throw WorkspaceToolError.invalid("Invalid remote MCP endpoint.")
                            }
                            lock.withLock { connection = WovenMCPConnection(endpointURL: endpoint, bearerToken: localConnection.bearerToken, captureID: localConnection.captureID, sessionID: localConnection.sessionID) }
                            gate.finish(.success(())); continue
                        }
                        guard let id = object["id"]?.stringValue, UUID(uuidString: id) != nil else { throw WorkspaceToolError.invalid("Invalid MCP request identity.") }
                        if type == "cancel" { lock.withLock { requests.removeValue(forKey: id)?.cancel() }; continue }
                        guard type == "request", let body = object["body"] else { throw WorkspaceToolError.invalid("Invalid MCP relay request.") }
                        let admitted = lock.withLock {
                            guard !stopped, requests.count < 4, requests[id] == nil else { return false }
                            let task = Task.detached { [weak self] in
                                guard let self else { return }
                                // Admission and registration finish under the same
                                // lock before a request may reach its owning host.
                                guard self.lock.withLock({ !self.stopped && self.requests[id] != nil }) else { return }
                                await self.forward(id: id, body: body)
                            }
                            requests[id] = task; return true
                        }
                        if !admitted { throw WorkspaceToolError.invalid("Too many MCP relay requests.") }
                    }
                }
            } catch { gate.finish(.failure(error)) }
        }
    }

    private func forward(id: String, body: GatewayJSONValue) async {
        defer { _ = lock.withLock { requests.removeValue(forKey: id) } }
        do {
            guard let endpoint = URL(string: localConnection.endpointURL) else { return }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"; request.timeoutInterval = 115
            request.setValue("Bearer " + localConnection.bearerToken, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, [200, 202].contains(http.statusCode), data.count <= 4 * 1_024 * 1_024 else {
                throw WorkspaceToolError.invalid("The owning Woven MCP service is unavailable.")
            }
            let result: GatewayJSONValue = http.statusCode == 202 ? .null : try JSONDecoder().decode(GatewayJSONValue.self, from: data)
            try write(.object(["type": .string("response"), "id": .string(id), "status": .number(Double(http.statusCode)), "body": result]))
        } catch {
            guard !Task.isCancelled else { return }
            try? write(.object(["type": .string("response"), "id": .string(id), "status": .number(502), "body": .object(["jsonrpc": .string("2.0"), "id": body.objectValue?["id"] ?? .null, "error": .object(["code": .number(-32000), "message": .string("The owning Woven MCP service is unavailable. Inspect prior effects before retrying mutations.")])])]))
        }
    }

    func stop() {
        let calls = lock.withLock { () -> [Task<Void, Never>]? in
            guard !stopped else { return nil }
            stopped = true; let values = Array(requests.values); requests.removeAll(); return values
        }
        guard let calls else { return }
        calls.forEach { $0.cancel() }
        gate.finish(.failure(WorkspaceToolError.invalid("The remote Woven MCP connection closed.")))
        try? input.close(); try? output.close()
        if process.isRunning { process.terminate() }
    }
    deinit { stop() }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private final class WovenMCPBridgeReady: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var continuation: CheckedContinuation<Void, any Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let existing = lock.withLock { () -> Result<Void, any Error>? in
                if let result { return result }; self.continuation = continuation; return nil
            }
            if let existing { continuation.resume(with: existing) }
        }
    }
    @discardableResult func finish(_ result: Result<Void, any Error>) -> Bool {
        let (won, waiter) = lock.withLock {
            guard self.result == nil else { return (false, nil as CheckedContinuation<Void, any Error>?) }
            self.result = result; let value = continuation; continuation = nil; return (true, value)
        }
        waiter?.resume(with: result); return won
    }
}
