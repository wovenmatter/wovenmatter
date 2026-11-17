import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum OpenCodeServiceLauncher {
    /// Reuse the standard service. Only a missing or dead process permits a
    /// launch; a live incompatible/unhealthy service is never replaced.
    public static func ensure(executable: URL?, registration: URL = OpenCodeConnection.registrationURL(),
                              clientFactory: @Sendable (OpenCodeConnection) -> OpenCodeHTTPClient = { OpenCodeHTTPClient(connection: $0) }) async throws -> OpenCodeConnection {
        try await NativeMCPAdapter.installOpenCode()
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

    /// OpenCode 2 from its official installer (https://opencode.ai/v2/install), which puts
    /// it in ~/.opencode/bin where the terminal, OpenCode's desktop app and Woven Matter all
    /// find the same install.
    public static var installDefinition: LocalACPRuntimeDefinition {
        let catalog = LocalACPRuntimeCatalog.definition(for: .opencode)
        return LocalACPRuntimeDefinition(runtimeKind: .opencode, displayName: "OpenCode v2", commandName: "opencode", alternativeCommandNames: ["opencode2"],
            arguments: [], underlyingCLIName: nil,
            cliInstallerSource: catalog?.cliInstallerSource ?? URL(string: "https://opencode.ai/v2/install"),
            cliInstallerInterpreter: catalog?.cliInstallerInterpreter ?? "bash",
            cliInstallerArguments: catalog?.cliInstallerArguments ?? [],
            updateArguments: catalog?.updateArguments ?? ["upgrade"],
            adapterPackage: nil, adapterDescription: "Local OpenCode v2 service")
    }

    /// Runs the official installer and checks that the `opencode` it leaves is OpenCode 2.
    public static func install(using installer: LocalACPRuntimeInstaller = LocalACPRuntimeInstaller()) async throws -> URL {
        let executable = try await installer.install(installDefinition, component: .cli)
        let result = try await Task.detached {
            try LocalACPProcessRunner.run(executableURL: executable, arguments: ["--version"])
        }.value
        guard result.succeeded, OpenCodeConnection.supportsVersion(normalizedVersion(result.stdout)) else {
            throw OpenCodeError.message("The installed OpenCode isn't OpenCode 2. Try installing again.")
        }
        return executable
    }

    /// The OpenCode 1 version that installing OpenCode 2 would replace: OpenCode 1 is
    /// installed and no OpenCode 2 is. Both use the `opencode` command, and the official
    /// installer writes the same file, so this is asked about first.
    public static func versionOneToReplace(resolver: LocalACPRuntimeResolver = LocalACPRuntimeResolver(),
                                           native: URL? = LocalACPRuntimeResolver.nativeLocation(named: "opencode"),
                                           probe: RuntimeMaintenance.Probe = RuntimeMaintenance.probeVersion) -> String? {
        let candidates = (installDefinition.commandNames.compactMap { resolver.executable(named: $0) }
            + [native].compactMap { $0 }.filter { FileManager.default.isExecutableFile(atPath: $0.path) })
            .map(\.standardizedFileURL).uniqued()
        let versions = candidates.compactMap { probe($0).map(normalizedVersion) }
        guard !versions.contains(where: OpenCodeConnection.supportsVersion) else { return nil }
        return versions.first { $0.split(separator: ".").first == "1" }
    }

    /// What the person agrees to before OpenCode 2 replaces OpenCode 1.
    public static func replacementNotice(replacing version: String, on place: String = "this Mac") -> String {
        "Woven Matter works with OpenCode 2. Its official installer replaces the opencode command from OpenCode \(version) on \(place). OpenCode's settings and data are kept."
    }

    /// `opencode upgrade`, then a restart so the shared service runs the new version.
    public static func upgrade(executable: URL, registration: URL = OpenCodeConnection.registrationURL()) async throws {
        try await RuntimeMaintenance.runVendorUpdate(.opencode, executable: executable)
        try await runService("restart", executable: executable, registration: registration)
    }

    public static func stop(registration: URL = OpenCodeConnection.registrationURL()) async throws {
        guard FileManager.default.fileExists(atPath: registration.path) else { return }
        let connection = try OpenCodeConnection.discover(file: registration)
        guard isRunning(connection.pid) else { return }
        // Verify the authenticated service identity before signaling its process.
        _ = try await OpenCodeHTTPClient(connection: connection).health(allowLegacyBetaForStop: true)
        guard try OpenCodeConnection.discover(file: registration) == connection,
              let pid = connection.pid else { throw OpenCodeError.message("OpenCode changed while stopping. Try again.") }
        guard kill(Int32(pid), SIGTERM) == 0 || errno == ESRCH else {
            throw OpenCodeError.message("OpenCode could not be stopped.")
        }
        for _ in 0..<80 {
            if !isRunning(pid) { return }
            try await Task.sleep(for: .milliseconds(125))
        }
        throw OpenCodeError.message("OpenCode is still shutting down. Wait before restarting it.")
    }

    public static func normalizedVersion(_ output: String) -> String {
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["opencode v", "opencode2 v"] where version.hasPrefix(prefix) {
            return String(version.dropFirst(prefix.count))
        }
        return version
    }

    /// Prefer the standard command, while retaining the npm compatibility alias.
    /// A v1 command must not hide a supported v2 alias in the same environment.
    public static func resolveExecutable(resolver: LocalACPRuntimeResolver = LocalACPRuntimeResolver(),
                                         probe: RuntimeMaintenance.Probe = RuntimeMaintenance.probeVersion) -> URL? {
        let candidates = installDefinition.commandNames.compactMap { resolver.executable(named: $0) }
        return candidates.first { candidate in
            probe(candidate).map { OpenCodeConnection.supportsVersion(normalizedVersion($0)) } == true
        } ?? candidates.first
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
        guard OpenCodeConnection.supportsVersion(version) else { throw OpenCodeError.incompatible(version) }
        try await runService("start", executable: executable, registration: registration)
    }

    /// The arguments for one `opencode service` action.
    public static func serviceArguments(_ action: String) -> [String] { ["service", action] }

    /// Starts or restarts OpenCode's shared background service with OpenCode's own
    /// `opencode service` command, so OpenCode owns it rather than Woven Matter: it keeps
    /// running when Woven Matter quits, and the terminal and desktop app use the same one.
    static func runService(_ action: String, executable: URL, registration: URL) async throws {
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_STATE_HOME"] = registration.deletingLastPathComponent().deletingLastPathComponent().path
        // OpenCode runs session tools in the service process, which inherits this environment.
        WovenSessionEnvironment.apply(to: &environment)
        let previous = try? OpenCodeConnection.discover(file: registration)
        let result = try await Task.detached(priority: .userInitiated) {
            try LocalACPProcessRunner.run(executableURL: executable, arguments: serviceArguments(action),
                environment: environment, currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser, timeout: 60)
        }.value
        guard result.succeeded else {
            throw OpenCodeError.message("OpenCode could not \(action) its shared service. Check opencode service status.")
        }
        for _ in 0..<120 {
            try Task.checkCancellation()
            if let endpoint = try? OpenCodeConnection.discover(file: registration),
               action != "restart" || endpoint != previous,
               (try? await OpenCodeHTTPClient(connection: endpoint).health()) != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw OpenCodeError.message("OpenCode service startup is still pending. Refresh discovery; Woven Matter has not stopped the service.")
    }
}
