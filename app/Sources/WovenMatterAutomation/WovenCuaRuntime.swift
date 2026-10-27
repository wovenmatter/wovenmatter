import Foundation
import Darwin
import WovenMatterCore
import WovenMatterClient

/// The signed GUI spawns the bundled driver directly so macOS attributes its
/// permissions to Woven Matter. Neither agents nor the background server receive
/// the private endpoint. Each caller owns a distinct MCP lifecycle session.
@MainActor
final class WovenCuaRuntime {
    private let executable: URL
    private let bundleID: String
    private var daemon: Process?
    private var lifetime: Pipe?
    private var directory: URL?
    private var clients: [String: WovenCuaMCPProcess] = [:]
    private var retiring: [Process] = []
    private var expiry: [String: Task<Void, Never>] = [:]

    init(executable: URL, bundleID: String) {
        self.executable = executable; self.bundleID = bundleID
    }

    func revoke(callerID: String) {
        expiry.removeValue(forKey: callerID)?.cancel()
        clients.removeValue(forKey: callerID)?.stop()
        if clients.isEmpty { stop() }
    }
    func stop() {
        expiry.values.forEach { $0.cancel() }; expiry.removeAll()
        clients.values.forEach { $0.stop() }; clients.removeAll()
        try? lifetime?.fileHandleForWriting.close(); lifetime = nil
        if let daemon, daemon.isRunning { retiring.append(daemon); daemon.terminate() }
        daemon = nil
        // The child removes its socket on exit. Give every generation its own
        // directory so an old cleanup can never unlink a newer endpoint.
        directory = nil
    }

    func call(_ tool: String, arguments: [String: GatewayJSONValue], callerID: String,
              admit: @MainActor () async throws -> Void) async throws -> GatewayJSONValue {
        try await admit()
        do {
            let client = try await connection(callerID: callerID, admit: admit)
            try await admit()
            let result = try await client.call(method: "tools/call", params: .object([
                "name": .string(tool), "arguments": .object(arguments)
            ]))
            expiry[callerID] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.revoke(callerID: callerID)
            }
            return result
        } catch {
            revoke(callerID: callerID)
            throw error
        }
    }

    private func connection(callerID: String, admit: @MainActor () async throws -> Void) async throws -> WovenCuaMCPProcess {
        expiry.removeValue(forKey: callerID)?.cancel()
        if let daemon, !daemon.isRunning { stop() }
        if let client = clients[callerID], client.isRunning { return client }
        let retirementDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while retiring.contains(where: \.isRunning) {
            try await admit()
            guard ContinuousClock.now < retirementDeadline else {
                throw WorkspaceToolError.invalid("The previous Cua Driver is still stopping. Inspect state after it exits.")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        retiring.removeAll()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WorkspaceToolError.invalid("The bundled Cua Driver is missing. Rebuild or update Woven Matter.")
        }
        if daemon == nil {
            // Darwin's sockaddr_un path is limited to 104 bytes; the user's
            // long per-user TMPDIR can exceed that before our filename.
            let root = URL(fileURLWithPath: "/private/tmp").appending(path: "woven-cua-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let process = Process(), pipe = Pipe()
            process.executableURL = executable
            process.arguments = ["serve", "--embedded", "--socket", root.appending(path: "driver.sock").path,
                "--pid-file", root.appending(path: "driver.pid").path]
            process.environment = environment(root)
            process.standardInput = pipe
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in try? FileManager.default.removeItem(at: root) }
            try await admit()
            do { try process.run() }
            catch { try? FileManager.default.removeItem(at: root); throw error }
            daemon = process; lifetime = pipe; directory = root
        }
        guard let root = directory, let daemon else { throw CancellationError() }
        let socket = root.appending(path: "driver.sock")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: socket.path) {
            try await admit()
            guard daemon.isRunning, ContinuousClock.now < deadline else {
                stop()
                throw WorkspaceToolError.invalid("Cua Driver could not start. Check Woven Matter's macOS permissions.")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await admit()
        let client = try WovenCuaMCPProcess(executable: executable,
            arguments: ["mcp", "--embedded", "--socket", socket.path], environment: environment(root))
        clients[callerID] = client
        _ = try await client.call(method: "initialize", params: .object([
            "protocolVersion": .string("2025-03-26"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("woven"), "version": .string("1")])
        ]))
        try client.notify(method: "notifications/initialized", params: .object([:]))
        return client
    }

    private func environment(_ root: URL) -> [String: String] {
        // Do not forward provider credentials, user-selected driver endpoints,
        // policies, telemetry, recording, or updater settings to this helper.
        ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(),
         "CUA_DRIVER_EMBEDDED": "1", "CUA_DRIVER_HOST_BUNDLE_ID": bundleID,
         "CUA_DRIVER_PARENT_LIVENESS_STDIN": "1",
         "CUA_DRIVER_RS_HOME": root.appending(path: "state").path,
         "CUA_DRIVER_HOME": root.appending(path: "state").path,
         "CUA_DRIVER_LOCAL_HOME": root.appending(path: "state").path,
         "CUA_HOME": root.appending(path: "config").path,
         "CUA_DRIVER_RS_TELEMETRY_ENABLED": "false", "CUA_DRIVER_RS_UPDATE_CHECK": "false",
         "DO_NOT_TRACK": "1"]
    }
}

/// Bounded JSON-RPC over private stdio. Disconnecting the proxy closes its
/// implicit Cua session; interrupted native input is never retried here.
@MainActor
final class WovenCuaMCPProcess {
    private let process = Process()
    private let input = Pipe()
    private var pending: [String: CheckedContinuation<GatewayJSONValue, any Error>] = [:]
    private var bytes = Data()
    private var stopped = false
    var isRunning: Bool { !stopped && process.isRunning }

    init(executable: URL, arguments: [String], environment: [String: String]) throws {
        let output = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let reader = output.fileHandleForReading
        Thread { [weak self] in
            // read(upToCount:) can wait to fill the buffer on a Darwin pipe.
            // availableData completes after one available read, so a small
            // JSON-RPC response is delivered while the child stays alive.
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                DispatchQueue.main.async { [weak self] in self?.receive(chunk) }
            }
            try? reader.close()
            DispatchQueue.main.async { [weak self] in self?.stop() }
        }.start()
    }

    func stop() {
        guard !stopped else { return }; stopped = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let calls = pending; pending.removeAll(); bytes.removeAll()
        for call in calls.values {
            call.resume(throwing: WorkspaceToolError.invalid("Cua connection closed. Inspect fresh state before repeating input."))
        }
    }

    func call(method: String, params: GatewayJSONValue) async throws -> GatewayJSONValue {
        try Task.checkCancellation()
        let id = UUID().uuidString.lowercased()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard isRunning else { continuation.resume(throwing: CancellationError()); return }
                pending[id] = continuation
                do { try send(method: method, params: params, id: id) }
                catch { pending.removeValue(forKey: id)?.resume(throwing: error); stop() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                try? self?.notify(method: "notifications/cancelled", params: .object(["requestId": .string(id)]))
                self?.stop()
            }
        }
    }

    func notify(method: String, params: GatewayJSONValue) throws { try send(method: method, params: params, id: nil) }
    private func send(method: String, params: GatewayJSONValue, id: String?) throws {
        guard isRunning else { throw CancellationError() }
        var message: [String: GatewayJSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
        if let id { message["id"] = .string(id) }
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(GatewayJSONValue.object(message)) + Data([10]))
    }
    private func receive(_ chunk: Data) {
        guard !stopped else { return }
        bytes.append(chunk)
        guard bytes.count <= 8 * 1024 * 1024 else { stop(); return }
        while let newline = bytes.firstIndex(of: 10) {
            let line = Data(bytes[..<newline]); bytes.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(GatewayJSONValue.self, from: line),
                  let object = message.objectValue else { stop(); return }
            guard let id = object["id"]?.stringValue, let continuation = pending.removeValue(forKey: id) else { continue }
            if object["error"] != nil {
                continuation.resume(throwing: WorkspaceToolError.invalid("Cua rejected the operation. Inspect fresh state before retrying."))
            } else if let result = object["result"] { continuation.resume(returning: result) }
            else { continuation.resume(throwing: WorkspaceToolError.invalid("Invalid Cua response.")) }
        }
    }
}
