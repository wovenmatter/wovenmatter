import CryptoKit
import Foundation
import LibraryClient
import Security
import WovenMatterClient
import WovenMatterCore

/// `memberKey`: the public half of this Dev instance's stream key, admitted to
/// the live host's in-memory roster with the new credential (optional: older
/// clients send none).
struct DevelopmentClientRequest: Codable { var deviceID: String; var name: String; var memberKey: Data? = nil }
struct DevelopmentDisconnectRequest: Codable { var deviceID: String; var credential: String }
struct DevelopmentClientConnection: Codable { var endpoint: URL; var pairing: PairResponse; var stream: DevelopmentStreamRoute? = nil }
/// `development.stream`: admit this Dev identity's stream key again (the live
/// host's roster is in memory only), authenticated by its current credential.
struct DevelopmentStreamRequest: Codable { var deviceID: String; var credential: String; var memberKey: Data }
/// Where a Dev client's stream is: the live host's loopback development
/// listener, the member ID it signs for, and the workspace its `hello` names.
struct DevelopmentStreamRoute: Codable, Equatable, Sendable {
    var port: UInt16; var audience: String; var libraryID: String; var workspaceID: String
}

/// A client-mode Dev build's stream key: an Ed25519 key in this instance's
/// own Keychain namespace (the bundle ID is part of the service), created
/// once per Dev identity. It is never a library member key: only the public
/// half goes to the live host on its same-user socket, which keeps it in
/// memory for its loopback stream alone.
enum DevelopmentStreamKey {
    private static var service: String { ClientCredentialNamespace.service("com.wovenmatter.wovenmatter.development-stream") }

    static func loadOrCreate(deviceID: String) throws -> Curve25519.Signing.PrivateKey {
        let account = deviceID.lowercased()
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try .init(rawRepresentation: data) }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let key = Curve25519.Signing.PrivateKey()
        let added = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecValueData: key.rawRepresentation, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return key
    }
}

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
    static func deviceName(host: String = Host.current().localizedName ?? "This Mac",
                           mode: Mode? = DevelopmentLaunch.mode, instance: String? = DevelopmentLaunch.instance) -> String {
        guard mode != nil else { return host }
        return host + " (Dev)" + (instance.map { " · " + $0 } ?? "")
    }

    @MainActor static func disconnect(deviceID: String, credential: String) async throws {
        let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Woven Matter")
        _ = try await BackendRPCClient(socketURL: LocalExecutionRole.backendSocketURL(workspaceDirectory: production))
            .call(method: "development.disconnect", payload: JSONEncoder().encode(DevelopmentDisconnectRequest(deviceID: deviceID, credential: credential)), timeout: 3)
    }

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

    @MainActor static func connect(deviceID: String, memberKey: Data? = nil) async throws -> DevelopmentClientConnection {
        let bytes = try await liveHostSocket.call(method: "development.connect",
            payload: JSONEncoder().encode(DevelopmentClientRequest(deviceID: deviceID, name: displayName, memberKey: memberKey)), timeout: 3)
        return try JSONDecoder().decode(DevelopmentClientConnection.self, from: bytes)
    }

    /// Admits this instance's stream key on the live host's same-user socket
    /// and returns where its loopback stream listens.
    @MainActor static func admitStream(_ request: DevelopmentStreamRequest) async throws -> DevelopmentStreamRoute {
        let bytes = try await liveHostSocket.call(method: "development.stream", payload: JSONEncoder().encode(request), timeout: 3)
        return try JSONDecoder().decode(DevelopmentStreamRoute.self, from: bytes)
    }

    /// The live library host's private same-user endpoint (production's
    /// background server, or an explicit live Dev host, which uses its path).
    @MainActor private static var liveHostSocket: BackendRPCClient {
        let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Woven Matter")
        return BackendRPCClient(socketURL: LocalExecutionRole.backendSocketURL(workspaceDirectory: production))
    }
}
