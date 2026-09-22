import Foundation

/// Private pipe only: credential responses never enter session wire recording.
public enum DefaultAgentControl {
    public static func run(_ request: Data) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard let launch = DefaultAgentSupport.resolution().launchConfiguration else {
                throw DefaultAgentError.message("The bundled Default Agent helper is unavailable.")
            }
            let child = Process()
            let input = Pipe()
            let output = Pipe()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments =
                ["-c", #"ulimit -c 0; exec "$@""#, "woven-default-agent", launch.executableURL.path] + launch.arguments
                + ["--control"]
            child.standardInput = input
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
            try child.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 70, execute: deadline)
            defer {
                deadline.cancel()
                if child.isRunning { child.terminate() }
            }
            var body = request
            body.append(10)
            try input.fileHandleForWriting.write(contentsOf: body)
            try input.fileHandleForWriting.close()
            let response = try readResponse(from: output.fileHandleForReading)
            child.waitUntilExit()
            guard child.terminationStatus == 0,
                let line = response.split(separator: 10).last,
                let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let result = object["result"]
            else {
                throw DefaultAgentError.message(
                    "Default Agent credential refresh could not complete. Existing credentials were retained.")
            }
            return try JSONSerialization.data(withJSONObject: result)
        }.value
    }

    /// Bound memory while reading, rather than after buffering an entire child
    /// response. This pipe can contain credentials and must never be logged.
    static func readResponse(from handle: FileHandle, maximumBytes: Int = 1_048_576) throws -> Data {
        var response = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes - response.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maximumBytes - response.count else {
                throw DefaultAgentError.message("The Default Agent helper returned too much data.")
            }
            response.append(chunk)
        }
        return response
    }
}
