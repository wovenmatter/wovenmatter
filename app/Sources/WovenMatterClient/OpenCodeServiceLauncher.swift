import Foundation
import Darwin

public enum OpenCodeServiceLauncher {
    /// Reuse the standard service. Only a missing or dead process permits a
    /// launch; a live incompatible/unhealthy service is never replaced.
    public static func ensure(executable: URL?, registration: URL = OpenCodeConnection.registrationURL(),
                              clientFactory: @Sendable (OpenCodeConnection) -> OpenCodeHTTPClient = { OpenCodeHTTPClient(connection: $0) }) async throws -> OpenCodeConnection {
        if FileManager.default.fileExists(atPath: registration.path) {
            let existing = try OpenCodeConnection.discover(file: registration)
            do { _ = try await clientFactory(existing).health(); return existing }
            catch { if isRunning(existing.pid) { throw error } }
        }
        guard let executable else { throw OpenCodeError.message("Install OpenCode v2 so Woven Matter can start its local service.") }
        try await start(executable: executable, registration: registration)
        let connection = try OpenCodeConnection.discover(file: registration)
        _ = try await clientFactory(connection).health()
        return connection
    }

    public static func normalizedVersion(_ output: String) -> String {
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.hasPrefix("opencode2 v") ? String(version.dropFirst("opencode2 v".count)) : version
    }

    private static func isRunning(_ pid: Int?) -> Bool {
        guard let pid else { return false }
        return kill(Int32(pid), 0) == 0 || errno != ESRCH
    }

    public static func start(executable: URL, registration: URL = OpenCodeConnection.registrationURL()) async throws {
        if FileManager.default.fileExists(atPath: registration.path) {
            let existing = try OpenCodeConnection.discover(file: registration)
            guard !isRunning(existing.pid) else {
                throw OpenCodeError.message("The local OpenCode service is already running. Woven Matter has not replaced it.")
            }
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw OpenCodeError.message("OpenCode v2 is no longer installed at its expected location. Reinstall it and reconnect.")
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
        let version = normalizedVersion(String(decoding: try Data(contentsOf: output).prefix(4096), as: UTF8.self))
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
