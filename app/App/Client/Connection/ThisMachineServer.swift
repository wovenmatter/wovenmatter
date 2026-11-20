import Foundation

/// This Mac's background server: the app's own signed program run with
/// `--server`, as a per-user launchd agent so it outlives the window. Closing
/// or quitting the UI leaves it and its sessions running; launchd restarts it
/// after a crash; any exit it chose stays stopped.
///
/// The installed app's agent is a login item in ~/Library/LaunchAgents. A dev
/// instance has its own label, data folder and socket (its bundle identifier
/// is its own), keeps its job file in its data folder so it never starts at
/// login, and offers the stand-in runtime. It stays off the tailnet unless its
/// data folder holds `tailnet-port` (written by `build_and_run.sh --port`):
/// then it listens on that port and finds only servers on that port.
enum ThisMachineServer {
    static var label: String { (Bundle.main.bundleIdentifier ?? "wovenmatter.desktop") + ".server" }
    static var dataFolder: URL { AppDataFolder.url }
    static var socketPath: String { dataFolder.appending(path: "server.sock").path }
    static var isDevelopmentInstance: Bool { !(AppDataFolder.developmentInstance ?? "").isEmpty }

    private static var domain: String { "gui/\(getuid())" }
    private static var service: String { domain + "/" + label }

    private static var jobFile: URL {
        isDevelopmentInstance
            ? dataFolder.appending(path: label + ".plist")
            : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/" + label + ".plist")
    }

    /// Starts the server if it is not running. Never restarts a running one.
    static func start() async throws {
        try await Task.detached(priority: .userInitiated) {
            let changed = try writeJob()
            if try launchctl(["print", service]) != 0 {
                try checked(["bootstrap", domain, jobFile.path])
            } else if changed {
                // The program moved (a rebuilt or reinstalled app): load the new job.
                _ = try launchctl(["bootout", service])
                try checked(["bootstrap", domain, jobFile.path])
            }
            try checked(["kickstart", service])
        }.value
    }

    /// Restarts the server, for a server left running by another app release.
    static func restart() async throws {
        try await Task.detached(priority: .userInitiated) {
            try checked(["kickstart", "-k", service])
        }.value
    }

    private static func arguments() -> [String] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var arguments = [Bundle.main.executableURL?.path ?? "", ServerEntry.argument, dataFolder.path,
                         "--socket", socketPath, "--app-version", version]
        if isDevelopmentInstance {
            arguments += ["--folders", dataFolder.appending(path: "Folders").path, "--stand-in-runtime",
                          "--instance", AppDataFolder.developmentInstance ?? "dev"]
            if let text = try? String(contentsOf: dataFolder.appending(path: "tailnet-port"), encoding: .utf8),
               let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                arguments += ["--listen", "auto", "--port", String(port)]
            } else {
                arguments += ["--tailnet", "none"]
            }
        } else {
            arguments += ["--listen", "auto"]
        }
        return arguments
    }

    /// Writes the job file; true when it changed.
    private static func writeJob() throws -> Bool {
        let log = dataFolder.appending(path: "server.log").path
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments(),
            "RunAtLoad": true,
            // Restarted after a crash only: a clean stop, a start that failed and
            // a machine another one removed all stay stopped.
            "KeepAlive": ["Crashed": true],
            "ThrottleInterval": 5,
            "ExitTimeOut": 60,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Background",
            "WorkingDirectory": dataFolder.path,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jobFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: jobFile)) == data { return false }
        try data.write(to: jobFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jobFile.path)
        return true
    }

    private static func checked(_ arguments: [String]) throws {
        let status = try launchctl(arguments)
        guard status == 0 else {
            throw NSError(domain: "ThisMachineServer", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "The Woven server could not be started (launchctl \(arguments[0]) \(status))."
            ])
        }
    }

    private static func launchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
