import Foundation
import Darwin

public struct DefaultAgentSDKStatus: Codable, Equatable, Sendable {
    public struct SDK: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let installedVersion: String?
        public let latestVersion: String?
        public let updateAvailable: Bool
        public let notice: String?
        public let consistent: Bool?
        public var displayName: String { id == "pi" ? "Pi Durable SDK" : name }
    }
    public let sdks: [SDK]
    public let generation: String?
    public let notice: String?
}

public struct DefaultAgentSDKRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case status, check, update }
    public let action: Action
    public let id: String?
    public let version: String?

    public init(action: Action, id: String? = nil, version: String? = nil) {
        self.action = action; self.id = id; self.version = version
    }
}

/// SDK maintenance never loads account credentials or starts an agent session.
public enum DefaultAgentSDKControl {
    public static func run(_ request: DefaultAgentSDKRequest) async throws -> DefaultAgentSDKStatus {
        guard let root = DefaultAgentSupport.resources else {
            throw DefaultAgentError.message("The bundled Pi Durable helper is unavailable.")
        }
        return try await run(request, executable: root.appending(path: "bin/node"),
            arguments: [root.appending(path: "src/sdk-control.mjs").path],
            timeout: request.action == .update ? 900 : 90)
    }

    // Injectable only for local process-lifecycle fixtures. This starts no account/runtime session.
    static func run(_ request: DefaultAgentSDKRequest, executable: URL,
                    arguments: [String], timeout: TimeInterval) async throws -> DefaultAgentSDKStatus {
        let cancellation = CancellationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // poll/read/waitpid can block for an entire installation. Own
                // an OS thread: neither Swift's cooperative executor nor GCD's
                // shared utility pool may gate maintenance or cancellation.
                let worker = Thread {
                    continuation.resume(with: Result {
                        let response = try execute(request, executable: executable,
                            arguments: arguments, timeout: timeout, cancellation: cancellation)
                        struct Envelope: Decodable { let result: DefaultAgentSDKStatus?; let error: String? }
                        guard let line = response.split(separator: 10).last,
                              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(line)) else {
                            throw DefaultAgentError.message("SDK maintenance did not complete. Reload installed versions before trying again.")
                        }
                        // A completed activation remains installed even if cancellation
                        // arrives while its response is flushing or the helper exits.
                        if let result = envelope.result { return result }
                        if let error = envelope.error { throw DefaultAgentError.message(error) }
                        throw DefaultAgentError.message("SDK maintenance did not complete. Reload installed versions before trying again.")
                    })
                }
                worker.name = "Woven Matter SDK maintenance"
                worker.qualityOfService = .utility
                worker.start()
            }
        } onCancel: { cancellation.cancel() }
    }

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private static func execute(_ request: DefaultAgentSDKRequest, executable: URL,
                                arguments: [String], timeout: TimeInterval, cancellation: CancellationState) throws -> Data {
        guard !cancellation.isCancelled else { throw CancellationError() }
        let input = Pipe(), output = Pipe()
        let inputRead = input.fileHandleForReading, inputWrite = input.fileHandleForWriting
        let outputRead = output.fileHandleForReading, outputWrite = output.fileHandleForWriting
        defer {
            try? inputRead.close(); try? inputWrite.close()
            try? outputRead.close(); try? outputWrite.close()
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func requireSuccess(_ result: Int32) throws {
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        }
        try requireSuccess(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try requireSuccess(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try requireSuccess(posix_spawn_file_actions_adddup2(&actions, inputRead.fileDescriptor, STDIN_FILENO))
        try requireSuccess(posix_spawn_file_actions_adddup2(&actions, outputWrite.fileDescriptor, STDOUT_FILENO))
        try requireSuccess(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        for descriptor in [inputRead.fileDescriptor, inputWrite.fileDescriptor, outputRead.fileDescriptor, outputWrite.fileDescriptor] {
            try requireSuccess(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        // A private group contains only this maintenance helper and its installer.
        // Never signal the shared runtime or the app's process group.
        // Inherit only the explicit stdio descriptors, never app sockets/files.
        try requireSuccess(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try requireSuccess(posix_spawnattr_setpgroup(&attributes, 0))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let started = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { environment in
                posix_spawn(&pid, executable.path, &actions, &attributes,
                    UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: environment.baseAddress!))
            }
        }
        guard started == 0 else { throw POSIXError(POSIXErrorCode(rawValue: started) ?? .EIO) }
        // Keep the child unreaped while signaling its group, so its PID cannot be
        // reused for another process between a timeout check and SIGKILL.
        defer {
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
        try inputRead.close(); try outputWrite.close()
        _ = fcntl(inputWrite.fileDescriptor, F_SETNOSIGPIPE, 1)
        var body = try JSONEncoder().encode(request); body.append(10)
        try inputWrite.write(contentsOf: body); try inputWrite.close()
        let descriptor = outputRead.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stopDeadline: TimeInterval?, childExitedAt: TimeInterval?, reachedEOF = false, response = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if !reachedEOF {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard response.count + count <= 1_048_576 else { throw DefaultAgentError.message("The Pi Durable helper returned too much data.") }
                    response.append(contentsOf: buffer.prefix(count))
                } else if count == 0 { reachedEOF = true }
                else if errno != EAGAIN && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            var info = siginfo_t()
            let waited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if waited < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
            let now = ProcessInfo.processInfo.systemUptime
            if waited == 0 && info.si_pid == pid {
                if reachedEOF { return response }
                childExitedAt = childExitedAt ?? now
            }
            // A descendant can create its own session yet retain stdout. Its
            // descriptor must not keep this maintenance request alive forever.
            if let childExitedAt, now - childExitedAt >= 0.5 { return response }
            if let stopDeadline, now >= stopDeadline + 0.5 { return response }
            if stopDeadline == nil && (cancellation.isCancelled || now >= deadline) {
                kill(-pid, SIGTERM)
                stopDeadline = now + 2
            }
            if let stopDeadline, now >= stopDeadline { kill(-pid, SIGKILL) }
            var event = pollfd(fd: reachedEOF ? -1 : descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&event, 1, 25)
        }
    }
}
