import Foundation

public struct DefaultAgentSDKStatus: Codable, Equatable, Sendable {
    public struct SDK: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let installedVersion: String?
        public let latestVersion: String?
        public let updateAvailable: Bool
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
        try await Task.detached(priority: .utility) {
            guard let root = DefaultAgentSupport.resources else {
                throw DefaultAgentError.message("The bundled Built-in helper is unavailable.")
            }
            let child = Process()
            let input = Pipe()
            let output = Pipe()
            child.executableURL = root.appending(path: "bin/node")
            child.arguments = [root.appending(path: "src/sdk-control.mjs").path]
            child.standardInput = input
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
            try child.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + (request.action == .update ? 900 : 90), execute: deadline)
            defer {
                deadline.cancel()
                if child.isRunning { child.terminate() }
            }
            var body = try JSONEncoder().encode(request)
            body.append(10)
            try input.fileHandleForWriting.write(contentsOf: body)
            try input.fileHandleForWriting.close()
            let response = try DefaultAgentControl.readResponse(from: output.fileHandleForReading)
            child.waitUntilExit()
            struct Envelope: Decodable { let result: DefaultAgentSDKStatus?; let error: String? }
            guard let line = response.split(separator: 10).last,
                  let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(line)) else {
                throw DefaultAgentError.message("SDK maintenance did not complete. Check the installed versions before trying again.")
            }
            if let error = envelope.error { throw DefaultAgentError.message(error) }
            guard child.terminationStatus == 0, let result = envelope.result else {
                throw DefaultAgentError.message("SDK maintenance did not complete. Check the installed versions before trying again.")
            }
            return result
        }.value
    }
}
