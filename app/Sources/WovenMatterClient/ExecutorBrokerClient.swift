import Foundation

/// Serialized private stdio to the backend-owned Node manager. Responses are
/// bounded; stderr is never recorded because runtime errors may contain secrets.
public actor ExecutorBrokerClient {
    private final class PipeSession: @unchecked Sendable {
        let process = Process(), input = Pipe(), output = Pipe()
    }
    private var session: PipeSession?
    private var tail: Task<Void, Never>?
    private let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func call(_ value: GatewayJSONValue) async throws -> GatewayJSONValue {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_048_576 else { throw DefaultAgentError.message("Executor manager request is too large.") }
        if session?.process.isRunning != true {
            guard let resources = DefaultAgentSupport.resources else { throw DefaultAgentError.message("The bundled Executor manager is unavailable.") }
            let pipe = PipeSession()
            pipe.process.executableURL = URL(fileURLWithPath: "/bin/sh")
            pipe.process.arguments = ["-c", #"ulimit -c 0; exec "$@""#, "woven-executor", resources.appending(path: "bin/node").path,
                resources.appending(path: "src/executor/broker.mjs").path, directory.path]
            pipe.process.standardInput = pipe.input
            pipe.process.standardOutput = pipe.output
            pipe.process.standardError = FileHandle.nullDevice
            try pipe.process.run()
            session = pipe
        }
        let pipe = session!
        let previous = tail
        let task = Task.detached(priority: .utility) {
            await previous?.value
            guard pipe.process.isRunning else { throw DefaultAgentError.message("Executor manager stopped. Check existing effects before retrying a program.") }
            let deadline = DispatchWorkItem { if pipe.process.isRunning { pipe.process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 660, execute: deadline)
            defer { deadline.cancel() }
            var message = data; message.append(10)
            try pipe.input.fileHandleForWriting.write(contentsOf: message)
            var response = Data()
            while let chunk = try pipe.output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                response.append(chunk)
                guard response.count <= 1_048_576 else { pipe.process.terminate(); throw DefaultAgentError.message("Executor manager returned too much data.") }
                if response.last == 10 { break }
            }
            guard !response.isEmpty else { throw DefaultAgentError.message("Executor manager stopped. Check existing effects before retrying a program.") }
            let reply = try JSONDecoder().decode(GatewayJSONValue.self, from: response)
            if let error = reply.objectValue?["error"]?.stringValue { throw DefaultAgentError.message(error) }
            return reply.objectValue?["result"] ?? .null
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    public func shutdown() {
        try? session?.input.fileHandleForWriting.close()
        if session?.process.isRunning == true { session?.process.terminate() }
        session = nil
    }
}
