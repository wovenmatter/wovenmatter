import Foundation

/// Private pipe only: credential responses never enter session wire recording.
public enum DefaultAgentControl {
    public static func run(_ request: Data) async throws -> Data {
        try await Task.detached(priority: .utility) {
            guard let launch = DefaultAgentSupport.resolution().launchConfiguration else {
                throw DefaultAgentError.message("The bundled Default Agent helper is unavailable.")
            }
            let child = Process(), input = Pipe(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", #"ulimit -c 0; exec "$@""#, "woven-default-agent", launch.executableURL.path] + launch.arguments + ["--control"]
            child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
            let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
            try child.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 70, execute: deadline)
            defer { deadline.cancel(); if child.isRunning { child.terminate() } }
            var body = request; body.append(10)
            try input.fileHandleForWriting.write(contentsOf: body)
            try input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0, response.count < 1_048_576,
                  let line = response.split(separator: 10).last,
                  let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let result = object["result"] else {
                throw DefaultAgentError.message("Default Agent credential refresh could not complete. Existing credentials were retained.")
            }
            return try JSONSerialization.data(withJSONObject: result)
        }.value
    }
}
