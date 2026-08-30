import Foundation
import Security
import WovenMatterCore

public struct RemoteMachineCandidate: Codable, Equatable, Identifiable, Sendable {
    public let hostName: String
    public let displayName: String
    public let online: Bool

    public var id: String { hostName }

    public init(hostName: String, displayName: String, online: Bool) {
        self.hostName = hostName
        self.displayName = displayName
        self.online = online
    }
}

public struct RemoteWorkspaceConfiguration: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var workspaceID: String
    public var hostName: String
    public var userName: String?
    public var remotePort: Int
    public var memoryLimit: String?
    public var swapLimit: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        workspaceID: String,
        hostName: String,
        userName: String? = nil,
        remotePort: Int = 7337,
        memoryLimit: String? = nil,
        swapLimit: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.workspaceID = workspaceID
        self.hostName = hostName
        self.userName = userName
        self.remotePort = remotePort
        self.memoryLimit = memoryLimit
        self.swapLimit = swapLimit
        self.createdAt = createdAt
    }
}

public struct RemoteHarnessLaunchContext: Sendable {
    public let launch: LocalACPRuntimeLaunchConfiguration
    public let workspace: LocalACPWorkspaceLaunchConfiguration

    public init(
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration
    ) {
        self.launch = launch
        self.workspace = workspace
    }
}

public enum RemoteHarnessLaunchResolver {
    public static func resolve(
        configuration: RemoteWorkspaceConfiguration,
        runtimeKind: AgentRuntimeKind,
        processWorkingDirectory: URL
    ) throws -> RemoteHarnessLaunchContext {
        let idPattern = /^[a-z0-9][a-z0-9-]{0,47}$/
        guard configuration.workspaceID.wholeMatch(of: idPattern) != nil else {
            throw RemoteWorkspaceClientError.invalidWorkspaceID
        }
        guard let harness = try HarnessCatalog.loadBundled().harnesses.first(
            where: { $0.id == runtimeKind }
        ) else {
            throw RemoteWorkspaceClientError.harnessUnavailable
        }
        let destination = try RemoteWorkspaceSSHClient.validatedDestination(
            hostName: configuration.hostName,
            userName: configuration.userName
        )
        let remoteRoot = URL(
            filePath: "/home/.woven-matter",
            directoryHint: .isDirectory
        )
        var command = [
            "docker", "exec", "--interactive",
            "--workdir", remoteRoot.path,
            "wovenmatter-\(configuration.workspaceID)",
            "env",
            "HOME=/home",
            "PATH=/home/.local/bin:/home/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        ]
        for (key, value) in LocalACPRuntimeCatalog
            .definition(for: runtimeKind)?.environment.sorted(by: { $0.key < $1.key }) ?? [] {
            command.append("\(key)=\(value)")
        }
        command.append(harness.command)
        command.append(contentsOf: harness.arguments)
        let remoteCommand = command.map(shellQuote).joined(separator: " ")
        return RemoteHarnessLaunchContext(
            launch: LocalACPRuntimeLaunchConfiguration(
                runtimeKind: runtimeKind,
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: [
                    "-T",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=10",
                    destination,
                    remoteCommand,
                ],
                processWorkingDirectoryURL: processWorkingDirectory
            ),
            workspace: LocalACPWorkspaceLaunchConfiguration(
                rootURL: remoteRoot,
                repositoriesURL: remoteRoot.appending(
                    path: "REPOS",
                    directoryHint: .isDirectory
                )
            )
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public struct RemoteWorkspacePreflight: Codable, Equatable, Sendable {
    public struct Capabilities: Codable, Equatable, Sendable {
        public let memory: Bool
        public let swap: Bool
    }

    public let ready: Bool
    public let runtime: String
    public let version: String
    public let architecture: String
    public let capabilities: Capabilities
    public let limitations: [String]
    public let hostStorageCapacityBytes: Int64?
    public let hostStorageAvailableBytes: Int64?
    public let hostStorageLow: Bool
    public let storageWarning: String?
    public let canPrepare: Bool?
    public let preparationRequired: Bool?
    public let preparationActions: [String]?
    public let blockingIssues: [String]?
}

public struct RemoteWorkspaceStatus: Codable, Equatable, Sendable {
    public struct Capabilities: Codable, Equatable, Sendable {
        public let memory: Bool
        public let swap: Bool
    }

    public let id: String
    public let name: String
    public let state: String
    public let running: Bool
    public let health: String?
    public let startedAt: String
    public let image: String
    public let memoryBytes: Int64
    public let swapBytes: Int64
    public let swapMode: String?
    public let hostPort: Int
    public let persistentVolume: String
    public let capabilities: Capabilities
    public let storageKind: String
    public let storageUsedBytes: Int64?
    public let hostStorageCapacityBytes: Int64?
    public let hostStorageAvailableBytes: Int64?
    public let hostStorageLow: Bool
    public let storageWarning: String?
    public let legacyStorage: Bool
}

public struct RemoteHarnessStatus: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentRuntimeKind
    public let displayName: String
    public let transport: String
    public let capabilities: [String]
    public let state: String
    public let installationStatus: String?
    public let authenticationStatus: String
    public let transportStatus: String?
    public let transportError: String?
    public let setupMethods: [RemoteHarnessSetupMethod]
    public let detectedProviders: [String]
}

public struct RemoteHarnessSetupMethod: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
}

public struct RemoteInstallerPreview: Codable, Equatable, Sendable {
    public let harnessID: AgentRuntimeKind
    public let source: String
    public let sha256: String?
    public let bytes: Int?
    public let command: String
    public let verification: String
}

public struct RemoteHarnessAuthenticationSession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let harnessID: AgentRuntimeKind
    public let methodID: String
    public let methodName: String
    public let state: String
    public let verificationURL: URL?
    public let userCode: String?
    public let message: String
    public let error: String?
    public let acceptsAuthorizationCode: Bool
    public let credentialInputLabel: String?
    public let credentialInputSecret: Bool?
    public let notice: String?
}

public struct RemoteWorkspaceHealth: Codable, Equatable, Sendable {
    public let status: String
    public let version: String
    public let workspaceRoot: String
    public let harnessCount: Int
}

public struct RemoteOpenClawGatewayStatus: Codable, Equatable, Sendable {
    public let desired: Bool
    public let state: String
    public let pid: Int?
    public let restarts: Int
    public let lastError: String?
    public let socketPath: String
}

public struct RemoteOpenClawGatewayConnection: Sendable {
    public let endpoint: OpenClawGatewayEndpoint
    public let requestHeaders: [String: String]

    public init(
        endpoint: OpenClawGatewayEndpoint,
        requestHeaders: [String: String]
    ) {
        self.endpoint = endpoint
        self.requestHeaders = requestHeaders
    }
}

public struct RemoteHarnessOperation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let harnessID: AgentRuntimeKind
    public let action: String
    public let status: String
    public let output: String
    public let error: String?
    public let startedAt: String
    public let finishedAt: String?
}

public enum RemoteWorkspaceLifecycleAction: String, Sendable {
    case start
    case stop
    case restart
}

public enum RemoteMachineDiscovery {
    public static func tailnetMachines() throws -> [RemoteMachineCandidate] {
        guard let executable = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return []
        }
        let result = try RemoteWorkspaceProcess.run(
            executable: executable,
            arguments: ["status", "--json"]
        )
        guard result.status == 0 else {
            throw RemoteWorkspaceClientError.commandFailed(result.output)
        }
        return try decodeTailnetMachines(from: result.data)
    }

    static func decodeTailnetMachines(from data: Data) throws -> [RemoteMachineCandidate] {
        let document = try JSONSerialization.jsonObject(with: data)
        guard let root = document as? [String: Any],
              let peers = root["Peer"] as? [String: Any]
        else { return [] }
        return peers.values.compactMap { value in
            guard let peer = value as? [String: Any] else { return nil }
            let dnsName = (peer["DNSName"] as? String)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let shortName = (peer["HostName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let preferredName = shortName.flatMap { $0.isEmpty ? nil : $0 }
            // Prefer the name shown by Tailscale. It can match an existing SSH
            // Host entry, preserving its username, identity, and trust settings.
            let hostName = preferredName ?? dnsName
            guard let hostName, !hostName.isEmpty else { return nil }
            return RemoteMachineCandidate(
                hostName: hostName,
                displayName: preferredName ?? hostName,
                online: peer["Online"] as? Bool ?? false
            )
        }.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }
}

struct RemoteWorkspaceResourceCommandValues: Equatable, Sendable {
    let memoryBytes: String
    let memoryAndSwapBytes: String
}

enum RemoteWorkspaceResourceLimits {
    static func commandValues(
        for configuration: RemoteWorkspaceConfiguration
    ) throws -> RemoteWorkspaceResourceCommandValues {
        let memory = try configuration.memoryLimit.map {
            try bytes(from: $0, label: "Memory limit", allowsZero: false)
        }
        if let memory, memory < 6 * 1_024 * 1_024 {
            throw RemoteWorkspaceClientError.invalidResourceLimit(
                "Memory limit must be at least 6 MB."
            )
        }

        let additionalSwap = try configuration.swapLimit.map {
            try bytes(from: $0, label: "Additional swap limit", allowsZero: true)
        }
        if additionalSwap != nil, memory == nil {
            throw RemoteWorkspaceClientError.invalidResourceLimit(
                "Set a memory limit before setting an additional swap limit."
            )
        }
        let memoryAndSwap: Int64?
        if let memory, let additionalSwap {
            let (total, overflow) = memory.addingReportingOverflow(additionalSwap)
            guard !overflow else {
                throw RemoteWorkspaceClientError.invalidResourceLimit(
                    "Memory plus swap exceeds the supported size."
                )
            }
            memoryAndSwap = total
        } else {
            memoryAndSwap = nil
        }

        return RemoteWorkspaceResourceCommandValues(
            memoryBytes: memory.map(String.init) ?? "",
            memoryAndSwapBytes: memoryAndSwap.map(String.init) ?? ""
        )
    }

    private static func bytes(
        from input: String,
        label: String,
        allowsZero: Bool
    ) throws -> Int64 {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            throw RemoteWorkspaceClientError.invalidResourceLimit(
                "\(label) is empty; leave the field blank for no explicit limit."
            )
        }
        let suffix = value.last.map(String.init) ?? ""
        let hasSuffix = ["b", "k", "m", "g", "t"].contains(suffix)
        let digits = hasSuffix ? String(value.dropLast()) : value
        guard !digits.isEmpty,
              digits.allSatisfy(\.isNumber),
              let amount = Int64(digits),
              amount > 0 || allowsZero
        else {
            throw RemoteWorkspaceClientError.invalidResourceLimit(
                "\(label) must be a whole number of gigabytes, such as 8."
            )
        }
        let multiplier: Int64 = switch hasSuffix ? suffix : "g" {
        case "k": 1_024
        case "m": 1_024 * 1_024
        case "g": 1_024 * 1_024 * 1_024
        case "t": 1_024 * 1_024 * 1_024 * 1_024
        default: 1
        }
        let (result, overflow) = amount.multipliedReportingOverflow(by: multiplier)
        guard !overflow else {
            throw RemoteWorkspaceClientError.invalidResourceLimit(
                "\(label) exceeds the supported size."
            )
        }
        return result
    }
}

public actor RemoteWorkspaceSSHClient {
    public typealias Runner = @Sendable (
        _ destination: String,
        _ command: String,
        _ input: Data?
    ) throws -> Data

    private let runner: Runner
    private let scriptLoader: @Sendable () throws -> Data

    public init() {
        self.runner = RemoteWorkspaceSSHClient.runSSH
        self.scriptLoader = RemoteWorkspaceSSHClient.loadLifecycleScript
    }

    public init(
        runner: @escaping Runner,
        scriptLoader: @escaping @Sendable () throws -> Data
    ) {
        self.runner = runner
        self.scriptLoader = scriptLoader
    }

    public func preflight(
        hostName: String,
        userName: String?
    ) throws -> RemoteWorkspacePreflight {
        try decode(
            RemoteWorkspacePreflight.self,
            from: runScript(
                hostName: hostName,
                userName: userName,
                arguments: ["inspect"]
            )
        )
    }

    public func prepareHost(
        hostName: String,
        userName: String?
    ) throws -> RemoteWorkspacePreflight {
        try decode(
            RemoteWorkspacePreflight.self,
            from: runScript(
                hostName: hostName,
                userName: userName,
                arguments: [
                    "prepare",
                    "AUTHORIZED",
                ]
            )
        )
    }

    public func create(
        configuration: RemoteWorkspaceConfiguration,
        token: String
    ) throws -> RemoteWorkspaceStatus {
        let resources = try RemoteWorkspaceResourceLimits.commandValues(
            for: configuration
        )
        return try decode(
            RemoteWorkspaceStatus.self,
            from: runScript(
                hostName: configuration.hostName,
                userName: configuration.userName,
                arguments: [
                    "create",
                    configuration.workspaceID,
                    String(configuration.remotePort),
                    resources.memoryBytes,
                    resources.memoryAndSwapBytes,
                ],
                secret: token
            )
        )
    }

    public func deployService(
        hostName: String,
        userName: String?
    ) throws {
        let destination = try Self.validatedDestination(
            hostName: hostName,
            userName: userName
        )
        let command = #"if docker info >/dev/null 2>&1; then exec docker build --tag wovenmatter/workspace:0.1 --file remote/Dockerfile -; elif sudo -n docker info >/dev/null 2>&1; then exec sudo -n docker build --tag wovenmatter/workspace:0.1 --file remote/Dockerfile -; else printf '%s\n' 'Docker Engine is unavailable after host verification.' >&2; exit 69; fi"#
        _ = try runner(
            destination,
            command,
            try Self.loadDeploymentArchive()
        )
    }

    public func status(
        configuration: RemoteWorkspaceConfiguration
    ) throws -> RemoteWorkspaceStatus {
        return try decode(
            RemoteWorkspaceStatus.self,
            from: runScript(
                hostName: configuration.hostName,
                userName: configuration.userName,
                arguments: ["status", configuration.workspaceID]
            )
        )
    }

    public func lifecycle(
        _ action: RemoteWorkspaceLifecycleAction,
        configuration: RemoteWorkspaceConfiguration
    ) throws -> RemoteWorkspaceStatus {
        return try decode(
            RemoteWorkspaceStatus.self,
            from: runScript(
                hostName: configuration.hostName,
                userName: configuration.userName,
                arguments: [action.rawValue, configuration.workspaceID]
            )
        )
    }

    public func update(
        configuration: RemoteWorkspaceConfiguration
    ) throws -> RemoteWorkspaceStatus {
        let resources = try RemoteWorkspaceResourceLimits.commandValues(
            for: configuration
        )
        return try decode(
            RemoteWorkspaceStatus.self,
            from: runScript(
                hostName: configuration.hostName,
                userName: configuration.userName,
                arguments: [
                    "update",
                    configuration.workspaceID,
                    "wovenmatter/workspace:0.1",
                    resources.memoryBytes,
                    resources.memoryAndSwapBytes,
                    String(configuration.remotePort),
                ]
            )
        )
    }

    public nonisolated static func validateResources(
        configuration: RemoteWorkspaceConfiguration
    ) throws {
        _ = try RemoteWorkspaceResourceLimits.commandValues(for: configuration)
    }

    public nonisolated static func validateConfiguration(
        _ configuration: RemoteWorkspaceConfiguration
    ) throws {
        let idPattern = /^[a-z0-9][a-z0-9-]{0,47}$/
        guard configuration.workspaceID.wholeMatch(of: idPattern) != nil else {
            throw RemoteWorkspaceClientError.invalidWorkspaceID
        }
        guard (1024...65535).contains(configuration.remotePort) else {
            throw RemoteWorkspaceClientError.invalidPort
        }
        _ = try validatedDestination(
            hostName: configuration.hostName,
            userName: configuration.userName
        )
        try validateResources(configuration: configuration)
    }

    public func delete(
        configuration: RemoteWorkspaceConfiguration,
        removePersistentData: Bool
    ) throws {
        var arguments = ["delete", configuration.workspaceID]
        if removePersistentData { arguments.append("--data") }
        _ = try runScript(
            hostName: configuration.hostName,
            userName: configuration.userName,
            arguments: arguments
        )
    }

    private func runScript(
        hostName: String,
        userName: String?,
        arguments: [String],
        secret: String? = nil
    ) throws -> Data {
        let destination = try Self.validatedDestination(
            hostName: hostName,
            userName: userName
        )
        let script = try scriptLoader()
        if let secret {
            guard !secret.contains("\n"), !secret.contains("\r") else {
                throw RemoteWorkspaceClientError.invalidResponse(
                    "A generated remote credential contained an invalid line break."
                )
            }
            let command = "IFS= read -r WOVENMATTER_API_TOKEN; export WOVENMATTER_API_TOKEN; exec bash -s -- "
                + arguments.map(Self.shellQuote).joined(separator: " ")
            var input = Data((secret + "\n").utf8)
            input.append(script)
            return try runner(destination, command, input)
        }
        let command = "exec bash -s -- "
            + arguments.map(Self.shellQuote).joined(separator: " ")
        return try runner(destination, command, script)
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            throw RemoteWorkspaceClientError.invalidResponse(
                String(decoding: data, as: UTF8.self)
            )
        }
    }

    public static func validatedDestination(
        hostName: String,
        userName: String?
    ) throws -> String {
        let cleanHost = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPattern = /^[A-Za-z0-9_][A-Za-z0-9._:-]{0,252}$/
        guard cleanHost.wholeMatch(of: hostPattern) != nil,
              !cleanHost.contains("..") else {
            throw RemoteWorkspaceClientError.invalidHost
        }
        if let userName {
            let cleanUser = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanUser.isEmpty else { return cleanHost }
            let userPattern = /^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$/
            guard cleanUser.wholeMatch(of: userPattern) != nil else {
                throw RemoteWorkspaceClientError.invalidUser
            }
            return "\(cleanUser)@\(cleanHost)"
        }
        return cleanHost
    }

    private static func runSSH(
        destination: String,
        command: String,
        input: Data?
    ) throws -> Data {
        let result = try RemoteWorkspaceProcess.run(
            executable: "/usr/bin/ssh",
            arguments: [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "RequestTTY=no",
                destination,
                command,
            ],
            input: input
        )
        guard result.status == 0 else {
            throw RemoteWorkspaceClientError.commandFailed(result.output)
        }
        return result.data
    }

    private static func loadLifecycleScript() throws -> Data {
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let candidates = [
            Bundle.main.url(forResource: "remote-workspace", withExtension: "sh"),
            currentDirectory.appending(path: "scripts/remote-workspace.sh"),
            currentDirectory.appending(path: "../scripts/remote-workspace.sh"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: {
            FileManager.default.isReadableFile(atPath: $0.path)
        }) else {
            throw RemoteWorkspaceClientError.lifecycleScriptUnavailable
        }
        return try Data(contentsOf: url)
    }

    private static func loadDeploymentArchive() throws -> Data {
        let fileManager = FileManager.default
        let currentDirectory = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        )
        let candidates = [
            Bundle.main.resourceURL,
            currentDirectory,
            currentDirectory.deletingLastPathComponent(),
        ].compactMap { $0 }
        guard let root = candidates.first(where: {
            var remoteDirectory: ObjCBool = false
            var harnessDirectory: ObjCBool = false
            return fileManager.fileExists(
                atPath: $0.appending(path: "remote").path,
                isDirectory: &remoteDirectory
            ) && remoteDirectory.boolValue
                && fileManager.fileExists(
                    atPath: $0.appending(path: "harnesses").path,
                    isDirectory: &harnessDirectory
                ) && harnessDirectory.boolValue
        }) else {
            throw RemoteWorkspaceClientError.deploymentBundleUnavailable
        }
        let result = try RemoteWorkspaceProcess.run(
            executable: "/usr/bin/tar",
            arguments: [
                "-czf", "-",
                "--exclude=remote/test",
                "--exclude=remote/.env.example",
                "--exclude=remote/compose.yaml",
                "-C", root.path,
                "remote", "harnesses",
            ]
        )
        guard result.status == 0 else {
            throw RemoteWorkspaceClientError.commandFailed(result.output)
        }
        return result.data
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public actor RemoteWorkspaceTunnel {
    private var process: Process?
    private var configurationID: UUID?
    public private(set) var localPort: Int?

    public init() {}

    public func start(
        configuration: RemoteWorkspaceConfiguration,
        localPort: Int,
        readinessProbe: @escaping @Sendable (Int) async -> Bool
    ) async throws {
        if process?.isRunning == true,
           configurationID == configuration.id,
           let activePort = self.localPort {
            if await readinessProbe(activePort) { return }
        }
        stop()
        guard (1024...65535).contains(localPort) else {
            throw RemoteWorkspaceClientError.invalidPort
        }
        guard (1024...65535).contains(configuration.remotePort) else {
            throw RemoteWorkspaceClientError.invalidPort
        }
        let destination = try RemoteWorkspaceSSHClient.validatedDestination(
            hostName: configuration.hostName,
            userName: configuration.userName
        )
        var lastFailure = "The SSH loopback tunnel could not be opened."
        for offset in 0..<20 {
            let candidate = 40_000 + ((localPort - 40_000 + offset) % 20_000)
            let candidateProcess = Process()
            let errors = Pipe()
            candidateProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            candidateProcess.arguments = [
                "-N", "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "RequestTTY=no",
                "-L", "127.0.0.1:\(candidate):127.0.0.1:\(configuration.remotePort)",
                destination,
            ]
            candidateProcess.standardError = errors
            try candidateProcess.run()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(15))
            while candidateProcess.isRunning, clock.now < deadline {
                do { try Task.checkCancellation() }
                catch {
                    candidateProcess.terminate()
                    throw error
                }
                if await readinessProbe(candidate) {
                    process = candidateProcess
                    configurationID = configuration.id
                    self.localPort = candidate
                    return
                }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch {
                    candidateProcess.terminate()
                    throw error
                }
            }
            if candidateProcess.isRunning {
                candidateProcess.terminate()
                lastFailure = "The SSH tunnel opened, but the authenticated workspace health check timed out."
                break
            }
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            lastFailure = detail.isEmpty ? lastFailure : detail
            let addressCollision = detail.localizedCaseInsensitiveContains(
                "address already in use"
            ) || detail.localizedCaseInsensitiveContains("cannot listen to port")
            if !addressCollision { break }
        }
        throw RemoteWorkspaceClientError.commandFailed(lastFailure)
    }

    public func stop() {
        process?.terminate()
        process = nil
        configurationID = nil
        localPort = nil
    }
}

public struct RemoteWorkspaceServiceClient: Sendable {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func health() async throws -> RemoteWorkspaceHealth {
        try await request(path: "v1/health", method: "GET", body: nil)
    }

    public func harnesses() async throws -> [RemoteHarnessStatus] {
        struct Document: Decodable { let harnesses: [RemoteHarnessStatus] }
        let document: Document = try await request(
            path: "v1/harnesses",
            method: "GET",
            body: nil
        )
        return document.harnesses
    }

    public func perform(
        harnessID: AgentRuntimeKind,
        action: String,
        confirmed: Bool = false,
        sourceSHA256: String? = nil
    ) async throws -> RemoteHarnessOperation {
        var payload: [String: Any] = ["confirmed": confirmed]
        if let sourceSHA256 { payload["sourceSHA256"] = sourceSHA256 }
        return try await request(
            path: "v1/harnesses/\(harnessID.rawValue)/\(action)",
            method: "POST",
            body: try JSONSerialization.data(
                withJSONObject: payload
            )
        )
    }

    public func installerPreview(
        harnessID: AgentRuntimeKind
    ) async throws -> RemoteInstallerPreview {
        try await request(
            path: "v1/harnesses/\(harnessID.rawValue)/install-preview",
            method: "GET",
            body: nil
        )
    }

    public func startSignIn(
        harnessID: AgentRuntimeKind,
        methodID: String
    ) async throws -> RemoteHarnessAuthenticationSession {
        try await request(
            path: "v1/harnesses/\(harnessID.rawValue)/sign-in",
            method: "POST",
            body: try JSONSerialization.data(
                withJSONObject: ["methodID": methodID]
            )
        )
    }

    public func authenticationSession(
        id: UUID
    ) async throws -> RemoteHarnessAuthenticationSession {
        return try await request(
            path: "v1/authentication-sessions/\(id.uuidString)",
            method: "GET",
            body: nil
        )
    }

    public func submitAuthorizationCode(id: UUID, code: String) async throws {
        struct Accepted: Decodable { let accepted: Bool }
        let _: Accepted = try await request(
            path: "v1/authentication-sessions/\(id.uuidString)/authorization-code",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["code": code])
        )
    }

    public func cancelAuthenticationSession(id: UUID) async throws {
        struct Stopping: Decodable { let stopping: Bool }
        let _: Stopping = try await request(
            path: "v1/authentication-sessions/\(id.uuidString)",
            method: "DELETE",
            body: nil
        )
    }

    public func operation(id: UUID) async throws -> RemoteHarnessOperation {
        try await request(
            path: "v1/operations/\(id.uuidString)",
            method: "GET",
            body: nil
        )
    }

    public func openClawGatewayStatus() async throws -> RemoteOpenClawGatewayStatus {
        try await request(
            path: "v1/openclaw/gateway",
            method: "GET",
            body: nil
        )
    }

    public func startOpenClawGateway() async throws -> RemoteOpenClawGatewayStatus {
        try await request(
            path: "v1/openclaw/gateway/start",
            method: "POST",
            body: nil
        )
    }

    public func restartOpenClawGateway() async throws -> RemoteOpenClawGatewayStatus {
        try await request(
            path: "v1/openclaw/gateway/restart",
            method: "POST",
            body: nil
        )
    }

    private func request<Value: Decodable>(
        path: String,
        method: String,
        body: Data?,
        queryItems: [URLQueryItem] = []
    ) async throws -> Value {
        let endpoint = baseURL.appending(path: path)
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw RemoteWorkspaceClientError.invalidResponse("The workspace URL is invalid.")
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw RemoteWorkspaceClientError.invalidResponse("The workspace URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw RemoteWorkspaceClientError.invalidResponse(
                String(decoding: data, as: UTF8.self)
            )
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

public actor RemoteWorkspaceCredentialStore {
    private let service = "com.wovenmatter.remote-workspaces"

    public init() {}

    public func token(for id: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw RemoteWorkspaceClientError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(token: String, for id: UUID) throws {
        let account = id.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw RemoteWorkspaceClientError.keychain(updated)
        }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw RemoteWorkspaceClientError.keychain(status)
        }
    }

    public func deleteToken(for id: UUID) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteWorkspaceClientError.keychain(status)
        }
    }
}

public enum RemoteWorkspaceClientError: LocalizedError, Equatable, Sendable {
    case invalidHost
    case invalidUser
    case invalidPort
    case invalidWorkspaceID
    case harnessUnavailable
    case lifecycleScriptUnavailable
    case deploymentBundleUnavailable
    case invalidResourceLimit(String)
    case unsupportedResource(String)
    case commandFailed(String)
    case invalidResponse(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidHost: "Enter a valid SSH hostname, IP address, or SSH config alias."
        case .invalidUser: "Enter a valid remote username (letters, digits, dot, underscore, or hyphen) or leave it blank for SSH configuration."
        case .invalidPort: "The remote loopback port must be between 1024 and 65535."
        case .invalidWorkspaceID: "Use 1-48 lowercase letters, digits, or hyphens for the workspace ID, beginning with a letter or digit."
        case .harnessUnavailable: "The selected remote harness is not in the reviewed catalog."
        case .lifecycleScriptUnavailable: "The remote workspace lifecycle script is unavailable."
        case .deploymentBundleUnavailable: "The remote workspace deployment bundle is unavailable."
        case .invalidResourceLimit(let detail): detail
        case .unsupportedResource(let detail): detail
        case .commandFailed(let detail): detail.isEmpty ? "The remote command failed." : detail
        case .invalidResponse(let detail): detail.isEmpty ? "The remote service returned an invalid response." : detail
        case .keychain(let status): "The remote workspace credential could not be accessed (status \(status))."
        }
    }
}

private enum RemoteWorkspaceProcess {
    struct Result {
        let data: Data
        let status: Int32
        var output: String {
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        input: Data? = nil
    ) throws -> Result {
        let process = Process()
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appending(path: "wovenmatter-stdout-\(UUID().uuidString)")
        let errorURL = fileManager.temporaryDirectory
            .appending(path: "wovenmatter-stderr-\(UUID().uuidString)")
        let privateFileAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o600,
        ]
        fileManager.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: privateFileAttributes
        )
        fileManager.createFile(
            atPath: errorURL.path,
            contents: nil,
            attributes: privateFileAttributes
        )
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        var inputURL: URL?
        var inputHandle: FileHandle?
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        if let input {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "wovenmatter-process-\(UUID().uuidString)")
            guard fileManager.createFile(
                atPath: url.path,
                contents: input,
                attributes: privateFileAttributes
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            inputURL = url
            inputHandle = try FileHandle(forReadingFrom: url)
            process.standardInput = inputHandle
        }
        defer {
            try? inputHandle?.close()
            try? outputHandle.close()
            try? errorHandle.close()
            if let inputURL { try? FileManager.default.removeItem(at: inputURL) }
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }
        try process.run()
        process.waitUntilExit()
        try outputHandle.close()
        try errorHandle.close()
        var data = try Data(contentsOf: outputURL)
        if process.terminationStatus != 0 {
            let errorData = try Data(contentsOf: errorURL)
            if !data.isEmpty, !errorData.isEmpty { data.append(Data("\n".utf8)) }
            data.append(errorData)
        }
        return Result(
            data: data,
            status: process.terminationStatus
        )
    }
}
