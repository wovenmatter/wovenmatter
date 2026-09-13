import CryptoKit
import Darwin
import Foundation

/// Hermes's built-in `serve` backend. No ACP adapter or custom server is involved.
public struct HermesGatewayConnection: Codable, Equatable, Sendable {
    public let home: String
    public let port: Int
    public let token: String
    public let pid: Int32

    public var identity: String { "hermes:" + home }
    public var websocketURL: URL {
        var parts = URLComponents()
        parts.scheme = "ws"; parts.host = "127.0.0.1"; parts.port = port
        parts.path = "/api/ws"
        parts.queryItems = [URLQueryItem(name: "token", value: token)]
        return parts.url!
    }
}

public actor HermesGatewayService {
    public static let shared = HermesGatewayService()
    private var starting: [String: Task<HermesGatewayConnection, any Error>] = [:]

    public func ensure(launch: LocalACPRuntimeLaunchConfiguration) async throws -> HermesGatewayConnection {
        let home = launch.environment["HERMES_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hermes").path
        if let task = starting[home] { return try await task.value }
        let task = Task { try await Self.startOrReuse(launch: launch, home: home) }
        starting[home] = task
        defer { starting[home] = nil }
        return try await task.value
    }

    private static func folder(home: String) -> URL {
        let digest = SHA256.hash(data: Data(home.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".woven-matter/runtime/hermes/" + digest)
    }

    /// Stops only this application's authenticated service, never `hermes serve --stop` (all services).
    public func stopIfIdle(home: String) async throws {
        if let task = starting[home] { _ = try await task.value }
        let registration = Self.folder(home: home).appending(path: "service.json")
        guard FileManager.default.fileExists(atPath: registration.path) else { return }
        let connection = try JSONDecoder().decode(HermesGatewayConnection.self, from: Data(contentsOf: registration))
        guard connection.home == home, connection.pid > 0 else { throw HermesGatewayError.message("Hermes service identity is invalid.") }
        guard kill(connection.pid, 0) == 0 || errno != ESRCH else { return }
        let client = HermesGatewayRPC(connection: connection)
        do {
            try await client.connect()
            let active = try await client.call("session.active_list")
            guard active["sessions"].array.allSatisfy({ ["idle", "ready", "completed"].contains($0["status"].text) }) else {
                throw HermesGatewayError.message("Finish or stop the active Hermes turns before disabling its Gateway.")
            }
            await client.disconnect()
        } catch { await client.disconnect(); throw error }
        guard try JSONDecoder().decode(HermesGatewayConnection.self, from: Data(contentsOf: registration)) == connection else {
            throw HermesGatewayError.message("Hermes connection changed while stopping. Refresh and retry.")
        }
        let stats = try await HermesSessionHistory.fetch(connection: connection, path: "/api/system/stats")
        guard stats["process"]["pid"].number == Double(connection.pid) else {
            throw HermesGatewayError.message("Hermes did not confirm its process identity. Its process has not been stopped.")
        }
        guard kill(connection.pid, SIGTERM) == 0 || errno == ESRCH else { throw HermesGatewayError.message("Hermes Gateway could not be stopped.") }
        for _ in 0..<80 {
            if kill(connection.pid, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(125))
        }
        throw HermesGatewayError.message("Hermes is still shutting down. Wait before updating it.")
    }

    private static func startOrReuse(launch: LocalACPRuntimeLaunchConfiguration, home: String) async throws -> HermesGatewayConnection {
        let folder = folder(home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let lockFD = open(folder.appending(path: "launch.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw HermesGatewayError.message("Could not lock Hermes service startup.") }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        var acquired = false
        for _ in 0..<240 {
            if flock(lockFD, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
        }
        guard acquired else { throw HermesGatewayError.message("Another Woven Matter instance is starting Hermes. Refresh after it finishes.") }
        let registration = folder.appending(path: "service.json")
        if FileManager.default.fileExists(atPath: registration.path) {
            let bytes = try Data(contentsOf: registration)
            guard bytes.count < 16_384,
                  let connection = try? JSONDecoder().decode(HermesGatewayConnection.self, from: bytes),
                  connection.home == home, (1...65535).contains(connection.port), !connection.token.isEmpty,
                  connection.pid > 0 else {
                throw HermesGatewayError.message("Hermes service registration is invalid. Review the Hermes connection before starting another server.")
            }
            if kill(connection.pid, 0) == 0 || errno != ESRCH {
                // A live registration is never replaced merely because authentication or health fails.
                let client = HermesGatewayRPC(connection: connection)
                do { try await client.connect(); await client.disconnect(); return connection }
                catch { await client.disconnect(); throw error }
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let ready = folder.appending(path: "ready-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: ready) }
        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = ["serve", "--isolated", "--host", "127.0.0.1", "--port", "0"]
        var environment = ProcessInfo.processInfo.environment
        for key in launch.environmentKeysToRemove { environment.removeValue(forKey: key) }
        for key in Array(environment.keys) where launch.environmentKeyPrefixesToRemove.contains(where: key.hasPrefix) { environment.removeValue(forKey: key) }
        environment.merge(launch.environment) { _, new in new }
        let token = UUID().uuidString + UUID().uuidString
        environment["HERMES_HOME"] = home
        environment["HERMES_DASHBOARD_SESSION_TOKEN"] = token
        environment["HERMES_DESKTOP_READY_FILE"] = ready.path
        // Do not inherit another Desktop's process owner, cron launcher, or workspace override.
        for key in ["HERMES_DESKTOP", "HERMES_DESKTOP_PARENT_PID", "HERMES_DESKTOP_PARENT_IDENTITY", "TERMINAL_CWD", "HERMES_TUI_SIDECAR_URL"] { environment.removeValue(forKey: key) }
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var registered = false
        defer { if !registered && process.isRunning { process.terminate() } }
        for _ in 0..<180 {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: ready), let port = try? HermesValue.decode(data)["port"].number,
               port.rounded() == port, port >= 1, port <= 65535 {
                let connection = HermesGatewayConnection(home: home, port: Int(port), token: token, pid: process.processIdentifier)
                let client = HermesGatewayRPC(connection: connection)
                do { try await client.connect(); await client.disconnect() }
                catch { await client.disconnect(); throw error }
                let encoded = try JSONEncoder().encode(connection)
                try encoded.write(to: registration, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registration.path)
                registered = true
                return connection
            }
            guard process.isRunning else { throw HermesGatewayError.message("Hermes could not start its native Gateway. Check Hermes setup and update its installed CLI.") }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw HermesGatewayError.message("Hermes Gateway startup timed out.")
    }
}
