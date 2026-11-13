import Foundation
import WovenMatterCore

/// A build's data role is part of its bundle, so Finder launches and restarts use
/// the same data role as the launcher. Release builds ignore these keys.
enum DevelopmentLaunch {
    enum Mode: String {
        case snapshot, live

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
    static var isLiveHost: Bool { mode == .live }
    static var isSnapshot: Bool { mode == .snapshot }
    static func deviceName(host: String = Host.current().localizedName ?? "This Mac",
                           mode: Mode? = DevelopmentLaunch.mode, instance: String? = DevelopmentLaunch.instance) -> String {
        guard mode != nil else { return host }
        return host + " (Dev)" + (instance.map { " · " + $0 } ?? "")
    }

    static func validate() throws {
        #if DEBUG
        guard Bundle.main.bundleIdentifier?.hasPrefix("wovenmatter.desktop.dev") == true else { return }
        guard mode != nil, instance != nil, let directory = supportDirectory else {
            throw WorkspaceToolError.invalid("Launch development builds with scripts/build_and_run.sh --mode snapshot or --mode live.")
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
        let marker = try Data(contentsOf: directory.appending(path: "development-snapshot.json"))
        guard let value = try JSONSerialization.jsonObject(with: marker) as? [String: Any], value["version"] as? Int == 1 else {
            throw WorkspaceToolError.invalid("Create this snapshot with the development launcher before opening it.")
        }
        #endif
    }
}
