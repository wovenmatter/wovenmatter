import Foundation
import WovenMatterCore

public struct LocalACPRuntimeDefinition: Equatable, Identifiable, Sendable {
    public let runtimeKind: AgentRuntimeKind
    public let displayName: String
    public let commandName: String
    public let alternativeCommandNames: [String]
    public let arguments: [String]
    public let underlyingCLIName: String?
    public let cliInstallerSource: URL?
    public let cliInstallerInterpreter: String?
    public let cliInstallerArguments: [String]
    public let cliNpmPackageSpec: String?
    public let adapterPackage: String?
    public let minimumAdapterVersion: String?
    public let minimumEngineVersion: String?
    public let minimumProtocolSDKVersion: String?
    public let adapterDescription: String

    public var id: AgentRuntimeKind { runtimeKind }
    public var commandNames: [String] {
        [commandName] + alternativeCommandNames
    }

    public init(
        runtimeKind: AgentRuntimeKind,
        displayName: String,
        commandName: String,
        alternativeCommandNames: [String] = [],
        arguments: [String],
        underlyingCLIName: String?,
        cliInstallerSource: URL?,
        cliInstallerInterpreter: String?,
        cliInstallerArguments: [String] = [],
        cliNpmPackageSpec: String? = nil,
        adapterPackage: String?,
        minimumAdapterVersion: String? = nil,
        minimumEngineVersion: String? = nil,
        minimumProtocolSDKVersion: String? = nil,
        adapterDescription: String
    ) {
        self.runtimeKind = runtimeKind
        self.displayName = displayName
        self.commandName = commandName
        self.alternativeCommandNames = alternativeCommandNames
        self.arguments = arguments
        self.underlyingCLIName = underlyingCLIName
        self.cliInstallerSource = cliInstallerSource
        self.cliInstallerInterpreter = cliInstallerInterpreter
        self.cliInstallerArguments = cliInstallerArguments
        self.cliNpmPackageSpec = cliNpmPackageSpec
        self.adapterPackage = adapterPackage
        self.minimumAdapterVersion = minimumAdapterVersion
        self.minimumEngineVersion = minimumEngineVersion
        self.minimumProtocolSDKVersion = minimumProtocolSDKVersion
        self.adapterDescription = adapterDescription
    }
}

public enum LocalACPRuntimeCatalog {
    public static let definitions: [LocalACPRuntimeDefinition] = {
        guard let catalog = try? HarnessCatalog.loadBundled() else { return [] }
        return [LocalACPRuntimeDefinition(runtimeKind: .defaultAgent, displayName: AgentRuntimeKind.defaultAgent.displayName, commandName: "woven-default-agent", arguments: [], underlyingCLIName: nil, cliInstallerSource: nil, cliInstallerInterpreter: nil, adapterPackage: nil, adapterDescription: "Included with Woven Matter.")] + catalog.harnesses.filter { AgentRuntimeKind.allCases.contains($0.id) }.map { harness in
            LocalACPRuntimeDefinition(
                runtimeKind: harness.id,
                displayName: harness.displayName,
                commandName: harness.command,
                alternativeCommandNames: harness.id == .claudeCode
                    ? ["claude-code-acp"]
                    : harness.id == .opencode ? ["opencode2"] : [],
                arguments: harness.arguments,
                underlyingCLIName: harness.adapterPackage == nil
                    ? nil
                    : harness.cliCommand,
                cliInstallerSource: harness.install.source,
                cliInstallerInterpreter: harness.install.interpreter,
                cliInstallerArguments: harness.install.arguments,
                cliNpmPackageSpec: harness.install.kind == "npm-global"
                    ? harness.install.package
                    : nil,
                adapterPackage: harness.adapterPackage,
                minimumAdapterVersion: harness.minimumAdapterVersion,
                minimumEngineVersion: harness.minimumEngineVersion,
                minimumProtocolSDKVersion: harness.minimumProtocolSDKVersion,
                adapterDescription: "Woven Matter uses \(harness.transport) transport for \(harness.displayName)."
            )
        }
    }()

    public static func definition(
        for runtimeKind: AgentRuntimeKind
    ) -> LocalACPRuntimeDefinition? {
        definitions.first { $0.runtimeKind == runtimeKind }
    }

    public static func conversationCodename(
        for runtimeKind: AgentRuntimeKind
    ) -> String? {
        switch runtimeKind {
        case .codex: "direct-codex"
        case .claudeCode: "direct-claude-code"
        case .grokBuild: "direct-grok-build"
        case .opencode: "direct-opencode"
        case .defaultAgent: "direct-default-agent"
        }
    }
}

public struct LocalACPRuntimeAvailability: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case ready
        case cliMissing = "cli_missing"
        case adapterMissing = "adapter_missing"
        case adapterOutdated = "adapter_outdated"
        case authenticationRequired = "authentication_required"
        case executableUnavailable = "executable_unavailable"
    }

    public let runtimeKind: AgentRuntimeKind
    public let displayName: String
    public let state: State
    public let detail: String
    public let executablePath: String?

    public var id: AgentRuntimeKind { runtimeKind }
    public var isReady: Bool { state == .ready }
    public var compactDetail: String {
        switch state {
        case .ready:
            "Installed with ACP"
        case .authenticationRequired:
            "Needs sign-in — see Settings"
        case .cliMissing, .adapterMissing, .adapterOutdated,
             .executableUnavailable:
            "Unavailable — see Settings"
        }
    }

    public init(
        runtimeKind: AgentRuntimeKind,
        displayName: String,
        state: State,
        detail: String,
        executablePath: String?
    ) {
        self.runtimeKind = runtimeKind
        self.displayName = displayName
        self.state = state
        self.detail = detail
        self.executablePath = executablePath
    }
}

/// A shell-quoted remote command retained as tokens so harness launch settings
/// can be changed without parsing shell text or modifying SSH's own arguments.
public struct LocalACPRuntimeWrappedCommand: Sendable {
    public let argumentIndex: Int
    public let command: [String]
    public let harnessArgumentsStartIndex: Int

    public init(argumentIndex: Int, command: [String], harnessArgumentsStartIndex: Int) {
        self.argumentIndex = argumentIndex
        self.command = command
        self.harnessArgumentsStartIndex = harnessArgumentsStartIndex
    }
}

public struct LocalACPRuntimeLaunchConfiguration: Sendable {
    /// Owner metadata; never forwarded into the harness environment or command.
    public var inspectionConversationID: String? = nil
    public var historyRecorder: WorkspaceWireRecorder? = nil
    public var mcpConnection: WovenMCPConnection? = nil
    public let runtimeKind: AgentRuntimeKind
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let environmentKeysToRemove: [String]
    public let environmentKeyPrefixesToRemove: [String]
    public let processWorkingDirectoryURL: URL?
    public let requestedPermission: String?
    public let wrappedCommand: LocalACPRuntimeWrappedCommand?

    public init(
        runtimeKind: AgentRuntimeKind,
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        environmentKeysToRemove: [String] = [],
        environmentKeyPrefixesToRemove: [String] = [],
        processWorkingDirectoryURL: URL? = nil,
        requestedPermission: String? = nil,
        wrappedCommand: LocalACPRuntimeWrappedCommand? = nil
    ) {
        self.runtimeKind = runtimeKind
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.environmentKeysToRemove = environmentKeysToRemove
        self.environmentKeyPrefixesToRemove = environmentKeyPrefixesToRemove
        self.processWorkingDirectoryURL = processWorkingDirectoryURL
        self.requestedPermission = requestedPermission
        self.wrappedCommand = wrappedCommand
    }
}

public struct LocalACPRuntimeResolution: Sendable {
    public let availability: LocalACPRuntimeAvailability
    public let launchConfiguration: LocalACPRuntimeLaunchConfiguration?

    public init(
        availability: LocalACPRuntimeAvailability,
        launchConfiguration: LocalACPRuntimeLaunchConfiguration?
    ) {
        self.availability = availability
        self.launchConfiguration = launchConfiguration
    }
}

public enum LocalACPRuntimeVerifier {
    /// Discovery establishes installed executables without starting a provider
    /// session. Reuse this process's last resolution for a runtime until an
    /// explicit action requests a fresh one; user-started sessions still use
    /// the discovered launch configuration normally.
    public static func refresh(
        definition: LocalACPRuntimeDefinition,
        resolution: LocalACPRuntimeResolution,
        workingDirectory: URL,
        credentialCheckRuntimeKinds: Set<AgentRuntimeKind> = [],
        previousResolution: LocalACPRuntimeResolution? = nil
    ) async -> LocalACPRuntimeResolution {
        guard credentialCheckRuntimeKinds.contains(definition.runtimeKind), !Task.isCancelled else {
            guard resolution.launchConfiguration != nil,
                  let previousResolution,
                  [.ready, .authenticationRequired, .executableUnavailable].contains(previousResolution.availability.state),
                  previousResolution.availability.executablePath == resolution.availability.executablePath
            else { return resolution }
            // Preserve explicit readiness/account checks, not stale discovery
            // failures. Managed adapter updates replace the target behind the
            // same executable path, so a repaired installation must become ready.
            return LocalACPRuntimeResolution(
                availability: previousResolution.availability,
                launchConfiguration: previousResolution.launchConfiguration == nil
                    ? nil : resolution.launchConfiguration
            )
        }
        return resolution
    }
}

public struct LocalACPRuntimeResolver: Sendable {
    private let searchDirectories: @Sendable () -> [String]

    public init() {
        searchDirectories = Self.executableSearchDirectories
    }

    init(executableSearchDirectories: [String]) {
        searchDirectories = { executableSearchDirectories }
    }

    /// Reuses one search-path discovery within a refresh. Create a new snapshot
    /// for each refresh so subsequent installs and PATH changes remain visible.
    public func snapshottingExecutableSearchDirectories() -> Self {
        Self(executableSearchDirectories: searchDirectories())
    }

    public func resolve(
        runtimeKind: AgentRuntimeKind
    ) -> LocalACPRuntimeResolution {
        if runtimeKind == .defaultAgent { return DefaultAgentSupport.resolution() }
        guard let definition = LocalACPRuntimeCatalog.definition(for: runtimeKind) else {
            return LocalACPRuntimeResolution(
                availability: LocalACPRuntimeAvailability(
                    runtimeKind: runtimeKind,
                    displayName: runtimeKind.displayName,
                    state: .executableUnavailable,
                    detail: "This runtime does not have a lightweight ACP binding.",
                    executablePath: nil
                ),
                launchConfiguration: nil
            )
        }

        let underlyingCLI = definition.underlyingCLIName.flatMap(resolveExecutable)
        if let executable = definition.commandNames.lazy.compactMap(resolveExecutable).first {
            if let underlyingCLIName = definition.underlyingCLIName,
               underlyingCLI == nil {
                return missingUnderlyingCLIResolution(
                    definition: definition,
                    underlyingCLIName: underlyingCLIName
                )
            }
            if adapterIsOutdated(
                definition: definition,
                executable: executable,
                underlyingCLI: underlyingCLI
            ) {
                return outdatedAdapterResolution(
                    definition: definition,
                    executable: executable
                )
            }
            return LocalACPRuntimeResolution(
                availability: LocalACPRuntimeAvailability(
                    runtimeKind: runtimeKind,
                    displayName: definition.displayName,
                    state: .ready,
                    detail: readyDetail(
                        definition: definition,
                        executable: executable
                    ),
                    executablePath: executable.path
                ),
                launchConfiguration: LocalACPRuntimeLaunchConfiguration(
                    runtimeKind: runtimeKind,
                    executableURL: executable,
                    arguments: definition.arguments,
                    environment: launchEnvironment(
                        definition: definition,
                        executable: executable,
                        underlyingCLI: underlyingCLI
                    )
                )
            )
        }

        let underlyingPresent = underlyingCLI != nil
        let state: LocalACPRuntimeAvailability.State =
            underlyingPresent ? .adapterMissing : .cliMissing
        let detail = underlyingPresent
            ? "\(definition.displayName) CLI is installed. Install \(definition.commandName) to enable ACP."
            : "\(definition.displayName) CLI was not found."
        return LocalACPRuntimeResolution(
            availability: LocalACPRuntimeAvailability(
                runtimeKind: runtimeKind,
                displayName: definition.displayName,
                state: state,
                detail: detail,
                executablePath: nil
            ),
            launchConfiguration: nil
        )
    }

    private func missingUnderlyingCLIResolution(
        definition: LocalACPRuntimeDefinition,
        underlyingCLIName: String
    ) -> LocalACPRuntimeResolution {
        LocalACPRuntimeResolution(
            availability: LocalACPRuntimeAvailability(
                runtimeKind: definition.runtimeKind,
                displayName: definition.displayName,
                state: .cliMissing,
                detail: "\(definition.commandName) is installed, but the \(underlyingCLIName) CLI is missing.",
                executablePath: nil
            ),
            launchConfiguration: nil
        )
    }

    private func outdatedAdapterResolution(
        definition: LocalACPRuntimeDefinition,
        executable: URL
    ) -> LocalACPRuntimeResolution {
        LocalACPRuntimeResolution(
            availability: LocalACPRuntimeAvailability(
                runtimeKind: definition.runtimeKind,
                displayName: definition.displayName,
                state: .adapterOutdated,
                detail: "\(definition.commandName) is outdated. Install the current Woven Matter-managed adapter.",
                executablePath: executable.path
            ),
            launchConfiguration: nil
        )
    }

    private func readyDetail(
        definition: LocalACPRuntimeDefinition,
        executable: URL
    ) -> String {
        if definition.adapterPackage == nil {
            return "\(definition.displayName) is installed with native ACP."
        }
        return "\(definition.displayName) CLI and \(executable.lastPathComponent) are installed."
    }

    private func adapterIsOutdated(
        definition: LocalACPRuntimeDefinition,
        executable: URL,
        underlyingCLI: URL?
    ) -> Bool {
        guard let minimum = definition.minimumAdapterVersion else {
            return false
        }
        let environment = launchEnvironment(
            definition: definition,
            executable: executable,
            underlyingCLI: underlyingCLI
        )
        guard let result = try? LocalACPProcessRunner.run(
            executableURL: executable,
            arguments: ["--version"],
            environment: ProcessInfo.processInfo.environment.merging(environment) {
                _, new in new
            },
            timeout: 15
        ), result.succeeded,
              let installed = Self.semanticVersion(in: result.stdout),
              let required = Self.semanticVersion(in: minimum)
        else {
            return true
        }
        return installed.lexicographicallyPrecedes(required)
    }

    private static func semanticVersion(in text: String) -> [Int]? {
        text.split { !$0.isNumber && $0 != "." }
            .compactMap { token -> [Int]? in
                let components = token.split(separator: ".")
                guard components.count == 3 else { return nil }
                let values = components.compactMap { Int($0) }
                return values.count == 3 ? values : nil
            }
            .first
    }

    public static func resolveExecutable(named name: String) -> URL? {
        if name.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: name).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: candidate.path)
                ? candidate : nil
        }
        return resolveExecutable(
            named: name,
            searchDirectories: executableSearchDirectories()
        )
    }

    public func executable(named name: String) -> URL? { resolveExecutable(named: name) }

    public static var executableSearchPath: String {
        executableSearchDirectories().joined(separator: ":")
    }

    private func resolveExecutable(named name: String) -> URL? {
        Self.resolveExecutable(
            named: name,
            searchDirectories: searchDirectories()
        )
    }

    private static func resolveExecutable(
        named name: String,
        searchDirectories: [String]
    ) -> URL? {
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func launchEnvironment(
        definition: LocalACPRuntimeDefinition,
        executable: URL,
        underlyingCLI: URL?
    ) -> [String: String] {
        let directories = (
            [executable.deletingLastPathComponent().path]
                + [underlyingCLI?.deletingLastPathComponent().path].compactMap { $0 }
                + searchDirectories()
        ).filter { !$0.isEmpty }.uniqued()
        var environment: [String: String] = [:]
        environment["PATH"] = directories.joined(separator: ":")
        return environment
    }

    static func executableSearchDirectories() -> [String] {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser
        let managedDirectories = [
            LocalACPManagedRuntimePaths.nodeToolsBinDirectory.path,
            LocalACPManagedRuntimePaths.nodeBinDirectory().path,
            LocalACPManagedRuntimePaths.applicationSupportDirectory
                .appending(path: "ACP Adapters/bin").path,
        ]
        let standardDirectories = [
            home.appending(path: ".local/share/mise/shims").path,
            home.appending(path: ".local/bin").path,
            home.appending(path: ".volta/bin").path,
            home.appending(path: ".asdf/shims").path,
            home.appending(path: ".bun/bin").path,
            home.appending(path: ".grok/bin").path,
            home.appending(path: ".opencode/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        return (
            managedDirectories
                + environmentPath.split(separator: ":").map(String.init)
                + loginShellSearchDirectories()
                + standardDirectories
        ).filter { !$0.isEmpty }.uniqued()
    }

    private static func loginShellSearchDirectories() -> [String] {
        for shellPath in ["/bin/zsh", "/bin/bash"] {
            let shell = URL(fileURLWithPath: shellPath)
            guard FileManager.default.isExecutableFile(atPath: shell.path),
                  let result = try? LocalACPProcessRunner.run(
                    executableURL: shell,
                    arguments: ["-l", "-c", #"printf "%s" "$PATH""#]
                  ),
                  result.succeeded
            else {
                continue
            }
            let directories = result.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":")
                .map(String.init)
            if !directories.isEmpty {
                return directories
            }
        }
        return []
    }
}
