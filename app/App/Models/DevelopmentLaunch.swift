import AppKit
import Foundation
import WovenMatterClient
import WovenMatterCore

struct DevelopmentHostStatus: Codable, Sendable { var allowed: Bool; var ready: Bool }

struct DevelopmentClientRequest: Codable { var deviceID: String; var name: String }
struct DevelopmentClientConnection: Codable { var endpoint: URL; var pairing: CompanionPairResponse }

/// A build's data role is part of its bundle, so Finder launches and restarts use
/// the same data role as the launcher. Release builds ignore these keys.
enum DevelopmentLaunch {
    enum Mode: String {
        case client, snapshot, live

        func workspaceFolder(instance: String) -> String {
            self == .live ? "Woven Matter" : "Woven Matter Dev/\(instance)/\(rawValue)"
        }
    }
    static var mode: Mode? {
        #if DEBUG
        return Mode(rawValue: Bundle.main.object(forInfoDictionaryKey: "WovenMatterDevelopmentMode") as? String ?? "")
        #else
        return nil
        #endif
    }
    static var instance: String? {
        guard mode != nil,
              let value = Bundle.main.object(forInfoDictionaryKey: "WovenMatterDevelopmentInstance") as? String,
              !value.isEmpty, value.count <= 64,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return value
    }
    static var supportDirectory: URL? {
        guard let mode, let instance else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: mode.workspaceFolder(instance: instance), directoryHint: .isDirectory)
    }
    static var executionHome: URL? { isLiveHost ? nil : supportDirectory?.appending(path: "ExecutionHome", directoryHint: .isDirectory) }
    static var isClient: Bool { mode == .client }
    static var isLiveHost: Bool { mode == .live }
    static var isSnapshot: Bool { mode == .snapshot }
    static var displayName: String { "Dev · " + (instance ?? "") }

    static func validate() throws {
        #if DEBUG
        guard Bundle.main.bundleIdentifier?.hasPrefix("wovenmatter.desktop.dev") == true else { return }
        guard mode != nil, instance != nil, let directory = supportDirectory else {
            throw WorkspaceToolError.invalid("Launch development builds with scripts/build_and_run.sh --mode client, --mode snapshot, or --mode live.")
        }
        let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Woven Matter").resolvingSymlinksInPath().path
        let resolved = directory.resolvingSymlinksInPath().path
        if isLiveHost {
            guard resolved == production,
                  FileManager.default.fileExists(atPath: directory.appending(path: "workspace.sqlite").path) else {
                throw WorkspaceToolError.invalid("Live host mode requires the existing production library.")
            }
            // Startup acquires production's workspace-owner.lock before opening
            // any database or resuming its existing execution bindings.
            return
        }
        guard resolved != production, !resolved.hasPrefix(production + "/"),
              directory.path == resolved else {
            throw WorkspaceToolError.invalid("Development storage must be an independent directory without symbolic links.")
        }
        if isSnapshot {
            let marker = try Data(contentsOf: directory.appending(path: "development-snapshot.json"))
            guard let value = try JSONSerialization.jsonObject(with: marker) as? [String: Any], value["version"] as? Int == 1 else {
                throw WorkspaceToolError.invalid("Create this snapshot with the development launcher before opening it.")
            }
        }
        #endif
    }

    @MainActor private static var lastClientStartup: Data?

    @MainActor static func reportClientStartup(ready: Bool, error: String? = nil) {
        guard isClient, let directory = supportDirectory else { return }
        let value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "executable": Bundle.main.executableURL?.path ?? "",
            "state": ready ? "ready" : error == nil ? "connecting" : "failed",
            "error": error ?? ""]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            guard data != lastClientStartup else { return }
            try data.write(to: directory.appending(path: "development-client-startup.json"), options: .atomic)
            lastClientStartup = data
        } catch { NSLog("Could not report Dev client startup: %@", error.localizedDescription) }
    }

    /// Same-user IPC establishes trust. Never invoke remote pairing or copy host credentials.
    @MainActor static func connect(deviceID: String) async throws -> DevelopmentClientConnection {
        guard isClient else { throw BackendRPCError.remote("Automatic local connection is only available to Dev client builds.") }
        let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Woven Matter")
        let client = BackendRPCClient(socketURL: LocalExecutionRole.backendSocketURL(workspaceDirectory: production))
        return try await connectWhenReady(
            status: {
                let data = try await client.call(method: "development.status", timeout: 2)
                return try JSONDecoder().decode(DevelopmentHostStatus.self, from: data)
            },
            wakeHost: {
                guard NSRunningApplication.runningApplications(withBundleIdentifier: "wovenmatter.desktop").isEmpty else { return }
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "wovenmatter.desktop") else {
                    throw BackendRPCError.remote("Install the central Woven Matter app before launching a Dev client.")
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            },
            enroll: {
                let bytes = try await client.call(method: "development.connect",
                    payload: JSONEncoder().encode(DevelopmentClientRequest(deviceID: deviceID, name: displayName)), timeout: 10)
                return try JSONDecoder().decode(DevelopmentClientConnection.self, from: bytes)
            })
    }

    @MainActor static func connectWhenReady(
        attempts: Int = 60,
        status: () async throws -> DevelopmentHostStatus,
        wakeHost: () async throws -> Void,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) },
        enroll: () async throws -> DevelopmentClientConnection
    ) async throws -> DevelopmentClientConnection {
        var wokeHost = false
        for _ in 0..<attempts {
            try Task.checkCancellation()
            let current: DevelopmentHostStatus?
            do { current = try await status() }
            catch BackendRPCError.unavailable {
                current = nil
                if !wokeHost { try await wakeHost(); wokeHost = true }
            } catch BackendRPCError.timedOut { current = nil }
            if let current {
                guard current.allowed else {
                    throw BackendRPCError.remote("Enable Allow local Dev clients in the central Mac’s Devices settings once. Future Dev launches connect automatically.")
                }
                if current.ready { return try await enroll() }
            }
            try await pause()
        }
        throw BackendRPCError.remote("The central Woven Matter app did not become ready. Install a version with local Dev client support and enable Allow local Dev clients in its Devices settings once.")
    }
}
