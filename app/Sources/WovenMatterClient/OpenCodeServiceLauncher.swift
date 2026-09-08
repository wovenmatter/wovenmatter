import Foundation

public enum OpenCodeServiceLauncher {
    /// Launch the official service contender only when registration is absent.
    /// Never calls Service.ensure/stop: those may replace another client's service.
    public static func start(executable: URL, registration: URL = OpenCodeConnection.registrationURL()) async throws {
        guard !FileManager.default.fileExists(atPath: registration.path) else {
            throw OpenCodeError.message("A shared service is already registered. Connect to it, or manage an unhealthy service with OpenCode itself.")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw OpenCodeError.message("Choose the installed opencode2 executable in settings.")
        }
        guard registration.lastPathComponent == "service.json", registration.deletingLastPathComponent().lastPathComponent == "opencode" else {
            throw OpenCodeError.message("The service registration must be an opencode/service.json file under an XDG state directory.")
        }
        let output = FileManager.default.temporaryDirectory.appending(path: "opencode-version-" + UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let probe = Process(); probe.executableURL = executable; probe.arguments = ["--version"]
        probe.standardOutput = handle; probe.standardError = FileHandle.nullDevice; probe.standardInput = FileHandle.nullDevice
        try probe.run()
        defer { if probe.isRunning { probe.terminate() } }
        for _ in 0..<40 where probe.isRunning { try await Task.sleep(for: .milliseconds(250)) }
        guard !probe.isRunning, probe.terminationStatus == 0 else { throw OpenCodeError.message("Could not verify the selected OpenCode executable.") }
        let version = String(decoding: try Data(contentsOf: output).prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard version == OpenCodeConnection.supportedVersion else { throw OpenCodeError.incompatible(version) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--service"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_STATE_HOME"] = registration.deletingLastPathComponent().deletingLastPathComponent().path
        process.environment = environment
        // This process intentionally outlives Woven Matter and is never registered
        // with LocalACPClient's process cleanup or panel lifecycle.
        try process.run()
        for _ in 0..<120 {
            try Task.checkCancellation()
            if let endpoint = try? OpenCodeConnection.discover(file: registration),
               (try? await OpenCodeHTTPClient(connection: endpoint).health()) != nil { return }
            if !process.isRunning && process.terminationStatus != 0 {
                throw OpenCodeError.message("OpenCode could not start its shared service. Check opencode2 service status.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw OpenCodeError.message("OpenCode service startup is still pending. Refresh discovery; Woven Matter has not stopped the service.")
    }
}
