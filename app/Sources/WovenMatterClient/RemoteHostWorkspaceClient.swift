import Foundation

/// What `remote-host.sh install` sets up: a full workspace host, or the Woven server
/// with only its `bots` role, which a workspace can be added to later.
public enum RemoteHostInstallMode: String, Sendable {
    /// `addWorkspace` adds the workspace role to a bots-only server: roles only grow, so
    /// the host keeps bots and becomes `workspace,bots` on the same server and data root.
    /// `addBots` is the same for bots on a server that has only its workspace.
    case workspace, botsOnly, addWorkspace, addBots
    /// The workspace id the Mac records for a bots-only host until a workspace is added.
    /// remote-host.sh lets the first workspace install take over this placeholder once.
    public static let botsOnlyWorkspaceID = "bots"
    /// The roles argument of `remote-host.sh prepare|install|update`. nil keeps the
    /// host's recorded roles (or `workspace` on a new host); roles only grow there.
    public var roles: String? {
        switch self {
        case .workspace: nil
        case .botsOnly, .addBots: "bots"
        case .addWorkspace: "workspace"
        }
    }
}

/// The library host binaries a host bundle carries (`remote/host/library/linux-<arch>/`,
/// built by `scripts/build-linux-library.sh`). Every Linux host holds a library copy, so
/// a bundle without its machine's binary is never installed.
public enum RemoteHostLibrary {
    public static let architectures = ["x86_64", "aarch64"]

    /// The library binary's directory name for `remote-host.sh inspect`'s architecture.
    public static func architecture(_ reported: String) -> String? {
        switch reported.lowercased() {
        case "amd64", "x86_64", "x64": "x86_64"
        case "arm64", "aarch64": "aarch64"
        default: nil
        }
    }

    /// Architectures whose library host this deployment root ships.
    public static func bundled(root: URL) -> [String] {
        architectures.filter { arch in
            let directory = root.appending(path: "remote/host/library/linux-" + arch)
            return ["wovenmatter-library.gz", "wovenmatter-library"].contains { name in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: directory.appending(path: name).path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
        }
    }

    /// Throws unless the root ships the library host for `architecture`, or, while the
    /// host's architecture is unknown, for at least one (the host then checks its own).
    public static func require(root: URL, architecture: String?) throws {
        let shipped = bundled(root: root)
        let needed = architecture.flatMap(Self.architecture)
        if let needed { if shipped.contains(needed) { return } } else if !shipped.isEmpty { return }
        let machine = needed.map { "\($0) " } ?? ""
        throw RemoteWorkspaceClientError.commandFailed(
            "This Woven Matter build has no library host for \(machine)Linux hosts, so it can't install one: the host would hold no library copy and could never join your devices. Build it with scripts/build-linux-library.sh, then rebuild Woven Matter.")
    }
}

/// The host release fingerprint of this app's bundled host sources, hashed once per process
/// (the sources include the Linux library binaries, so it is not free).
private actor BundledHostFingerprint {
    static let shared = BundledHostFingerprint()
    private var task: Task<String?, Never>?
    func value() async -> String? {
        if let task { return await task.value }
        let task = Task.detached(priority: .utility) { () -> String? in
            guard let root = try? RemoteWorkspaceSSHClient.loadDeploymentRoot() else { return nil }
            return try? RemoteWorkspaceDeployment(root: root).fingerprint
        }
        self.task = task
        return await task.value
    }
}

extension RemoteWorkspaceSSHClient {
    /// The fingerprint `deployHost` installs from this app: a Linux host reporting any other
    /// release in `GET /v1/bots/status` is out of date. nil without bundled host sources.
    public static func bundledHostFingerprint() async -> String? {
        await BundledHostFingerprint.shared.value()
    }

    /// Ships source and its locked dependency graph from this Mac. npm installs
    /// on the destination so native optional dependencies match Linux/CPU ABI.
    /// The API token is the first stdin line, never an argument or progress text.
    /// `architecture` is the host's, from `inspect`, when known: the bundle must carry its
    /// library host.
    @discardableResult
    public func deployHost(configuration: RemoteWorkspaceConfiguration, token: String? = nil,
                           update: Bool = false, mode: RemoteHostInstallMode = .workspace, architecture: String? = nil,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> RemoteWorkspaceStatus {
        guard configuration.kind == .host else {
            throw RemoteWorkspaceClientError.invalidResponse("Select a Linux host workspace for native deployment.")
        }
        try Self.validateConfiguration(configuration)
        let secret = token ?? ""
        guard !secret.contains("\n"), !secret.contains("\r"), !secret.contains("\0"), update || !secret.isEmpty else {
            throw RemoteWorkspaceClientError.invalidResponse("The host service credential is invalid.")
        }
        let destination = try Self.validatedDestination(hostName: configuration.hostName, userName: configuration.userName)
        let root = try deploymentRoot ?? Self.loadDeploymentRoot()
        try RemoteHostLibrary.require(root: root, architecture: architecture)
        let deployment = try RemoteWorkspaceDeployment(root: root)
        progress("Preparing the host service bundle…")
        let bundle = try RemoteHostBundle.archive(root: root, deployment: deployment)
        let script = try String(data: hostScriptLoader(), encoding: .utf8).unwrapHostScript()
        let arguments = [update ? "update" : "install", configuration.workspaceID,
                         String(configuration.remotePort), configuration.accessMode.rawValue, deployment.fingerprint]
            + (mode.roles.map { [$0] } ?? [])
        let command = "exec bash -c " + RemoteWorkspaceExecTarget.quote(script) + " -- "
            + arguments.map(RemoteWorkspaceExecTarget.quote).joined(separator: " ")
        var input = Data((secret + "\n").utf8)
        input.append(bundle)
        let updates = RemoteWorkspaceBuildProgress(report: progress)
        progress("Uploading the host service…")
        return try decode(RemoteWorkspaceStatus.self,
            from: streamingRunner(destination, command, input) { updates.receive($0) })
    }

    public func logs(configuration: RemoteWorkspaceConfiguration, count: Int = 200) throws -> String {
        guard (1...10000).contains(count) else {
            throw RemoteWorkspaceClientError.invalidResponse("Choose between 1 and 10,000 log lines.")
        }
        try Self.validateConfiguration(configuration)
        let destination = try Self.validatedDestination(hostName: configuration.hostName, userName: configuration.userName)
        if configuration.kind == .host {
            let script = try String(data: hostScriptLoader(), encoding: .utf8).unwrapHostScript()
            let command = "exec bash -c " + RemoteWorkspaceExecTarget.quote(script) + " -- "
                + ["logs", configuration.workspaceID, String(count)].map(RemoteWorkspaceExecTarget.quote).joined(separator: " ")
            struct Response: Decodable { let logs: String }
            return try decode(Response.self, from: runner(destination, command, nil)).logs
        }
        let command = ["docker", "logs", "--tail", String(count), "wovenmatter-" + configuration.workspaceID]
            .map(RemoteWorkspaceExecTarget.quote).joined(separator: " ")
        return String(decoding: try runner(destination, command, nil), as: UTF8.self)
    }

}

private extension Optional where Wrapped == String {
    func unwrapHostScript() throws -> String {
        guard let value = self, !value.isEmpty else { throw RemoteWorkspaceClientError.lifecycleScriptUnavailable }
        return value
    }
}
