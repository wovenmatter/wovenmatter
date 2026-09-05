import Foundation
import WovenMatterCore

public struct LocalACPRuntimeDefinition: Equatable, Identifiable, Sendable {
    public let runtimeKind: AgentRuntimeKind
    public let displayName: String
    public let commandName: String
    public let alternativeCommandNames: [String]
    public let arguments: [String]
    public let environment: [String: String]
    public let underlyingCLIName: String?
    public let cliInstallerSource: URL?
    public let cliInstallerInterpreter: String?
    public let cliInstallerArguments: [String]
    public let cliNpmPackageSpec: String?
    public let adapterPackage: String?
    public let minimumAdapterVersion: String?
    public let adapterDescription: String
    public let readinessProbe: LocalACPRuntimeReadinessProbe?

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
        environment: [String: String] = [:],
        underlyingCLIName: String?,
        cliInstallerSource: URL?,
        cliInstallerInterpreter: String?,
        cliInstallerArguments: [String] = [],
        cliNpmPackageSpec: String? = nil,
        adapterPackage: String?,
        minimumAdapterVersion: String? = nil,
        adapterDescription: String,
        readinessProbe: LocalACPRuntimeReadinessProbe? = nil
    ) {
        self.runtimeKind = runtimeKind
        self.displayName = displayName
        self.commandName = commandName
        self.alternativeCommandNames = alternativeCommandNames
        self.arguments = arguments
        self.environment = environment
        self.underlyingCLIName = underlyingCLIName
        self.cliInstallerSource = cliInstallerSource
        self.cliInstallerInterpreter = cliInstallerInterpreter
        self.cliInstallerArguments = cliInstallerArguments
        self.cliNpmPackageSpec = cliNpmPackageSpec
        self.adapterPackage = adapterPackage
        self.minimumAdapterVersion = minimumAdapterVersion
        self.adapterDescription = adapterDescription
        self.readinessProbe = readinessProbe
    }
}

public struct LocalACPRuntimeReadinessProbe: Equatable, Sendable {
    public let expectedAgentName: String?
    public let setupAuthenticationMethodID: String?
    public let readyDetail: String
    public let setupRequiredDetail: String

    public init(
        expectedAgentName: String? = nil,
        setupAuthenticationMethodID: String? = nil,
        readyDetail: String,
        setupRequiredDetail: String
    ) {
        self.expectedAgentName = expectedAgentName
        self.setupAuthenticationMethodID = setupAuthenticationMethodID
        self.readyDetail = readyDetail
        self.setupRequiredDetail = setupRequiredDetail
    }
}

public enum LocalACPRuntimeCatalog {
    public static let definitions: [LocalACPRuntimeDefinition] = {
        guard let catalog = try? HarnessCatalog.loadBundled() else { return [] }
        return catalog.harnesses.map { harness in
            LocalACPRuntimeDefinition(
                runtimeKind: harness.id,
                displayName: harness.displayName,
                commandName: harness.command,
                alternativeCommandNames: harness.id == .claudeCode
                    ? ["claude-code-acp"]
                    : [],
                arguments: harness.arguments,
                environment: environment(for: harness.id),
                underlyingCLIName: harness.adapterPackage == nil
                    && harness.id != .openclaw
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
                adapterDescription: "Woven Matter uses \(harness.transport) transport for \(harness.displayName).",
                readinessProbe: readinessProbe(for: harness.id)
            )
        }
    }()

    private static func environment(
        for runtimeKind: AgentRuntimeKind
    ) -> [String: String] {
        switch runtimeKind {
        case .codex:
            ["CODEX_CONFIG": #"{"approvals_reviewer":"auto_review"}"#]
        case .hermes:
            ["HERMES_ACP_SKIP_CONFIGURED_MCP": "0"]
        default:
            [:]
        }
    }

    private static func readinessProbe(
        for runtimeKind: AgentRuntimeKind
    ) -> LocalACPRuntimeReadinessProbe? {
        switch runtimeKind {
        case .hermes:
            LocalACPRuntimeReadinessProbe(
                expectedAgentName: "hermes-agent",
                setupAuthenticationMethodID: "hermes-setup",
                readyDetail: "Hermes ACP is connected to the current Hermes profile.",
                setupRequiredDetail: "Hermes needs provider setup. Run “hermes model” in your terminal, then refresh its status."
            )
        case .cursor:
            LocalACPRuntimeReadinessProbe(
                setupAuthenticationMethodID: CursorACPSupport.authMethodID,
                readyDetail: CursorACPSupport.readyDetail(email: nil),
                setupRequiredDetail: CursorACPSupport.unauthenticatedDetail()
            )
        case .pi:
            LocalACPRuntimeReadinessProbe(
                readyDetail: PiRPCSupport.readyDetail(modelCount: 0),
                setupRequiredDetail: PiRPCSupport.unauthenticatedDetail()
            )
        default:
            nil
        }
    }

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
        case .hermes: "direct-hermes"
        case .openclaw: "direct-openclaw"
        case .cursor: "direct-cursor"
        case .opencode: "direct-opencode"
        case .pi: "direct-pi"
        }
    }
}

public struct LocalACPRuntimePreferences {
    public struct State: Equatable, Sendable {
        public var enabledRuntimeKinds: Set<AgentRuntimeKind>
        public var shownRuntimeKinds: Set<AgentRuntimeKind>

        public init(
            enabledRuntimeKinds: Set<AgentRuntimeKind>,
            shownRuntimeKinds: Set<AgentRuntimeKind>
        ) {
            self.enabledRuntimeKinds = enabledRuntimeKinds
            self.shownRuntimeKinds = shownRuntimeKinds
        }
    }

    public static let enabledRuntimeKindsKey =
        "wovenmatter.local-acp.enabled-runtimes"
    public static let shownRuntimeKindsKey =
        "wovenmatter.local-acp.shown-runtimes"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var state: State {
        State(
            enabledRuntimeKinds: runtimeKinds(forKey: Self.enabledRuntimeKindsKey),
            shownRuntimeKinds: runtimeKinds(forKey: Self.shownRuntimeKindsKey)
        )
    }

    @discardableResult
    public func enable(_ runtimeKind: AgentRuntimeKind) -> State {
        var state = state
        state.enabledRuntimeKinds.insert(runtimeKind)
        state.shownRuntimeKinds.insert(runtimeKind)
        save(state)
        return state
    }

    @discardableResult
    public func disable(_ runtimeKind: AgentRuntimeKind) -> State {
        var state = state
        state.enabledRuntimeKinds.remove(runtimeKind)
        save(state)
        return state
    }

    @discardableResult
    public func setShown(
        _ isShown: Bool,
        for runtimeKind: AgentRuntimeKind
    ) -> State {
        var state = state
        if isShown {
            state.shownRuntimeKinds.insert(runtimeKind)
        } else {
            state.shownRuntimeKinds.remove(runtimeKind)
        }
        save(state)
        return state
    }

    public static func visibleRuntimeKinds(
        in orderedRuntimeKinds: [AgentRuntimeKind],
        shownRuntimeKinds: Set<AgentRuntimeKind>
    ) -> [AgentRuntimeKind] {
        orderedRuntimeKinds.filter(shownRuntimeKinds.contains)
    }

    private func runtimeKinds(forKey key: String) -> Set<AgentRuntimeKind> {
        Set(
            defaults.stringArray(forKey: key)?
                .compactMap(AgentRuntimeKind.init(rawValue:)) ?? []
        )
    }

    private func save(_ state: State) {
        defaults.set(
            state.enabledRuntimeKinds.map(\.rawValue).sorted(),
            forKey: Self.enabledRuntimeKindsKey
        )
        defaults.set(
            state.shownRuntimeKinds.map(\.rawValue).sorted(),
            forKey: Self.shownRuntimeKindsKey
        )
    }
}

public struct LocalACPRuntimeAvailability: Equatable, Identifiable, Sendable {
    public enum State: String, Equatable, Sendable {
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
    public var needsCLIInstallation: Bool { state == .cliMissing }
    public var needsAdapterInstallation: Bool {
        state == .adapterMissing || state == .adapterOutdated
    }
    public var compactDetail: String {
        switch state {
        case .ready:
            "Ready through ACP"
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

public struct LocalACPRuntimeLaunchConfiguration: Sendable {
    public let runtimeKind: AgentRuntimeKind
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let environmentKeysToRemove: [String]
    public let environmentKeyPrefixesToRemove: [String]
    public let processWorkingDirectoryURL: URL?

    public init(
        runtimeKind: AgentRuntimeKind,
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        environmentKeysToRemove: [String] = [],
        environmentKeyPrefixesToRemove: [String] = [],
        processWorkingDirectoryURL: URL? = nil
    ) {
        self.runtimeKind = runtimeKind
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.environmentKeysToRemove = environmentKeysToRemove
        self.environmentKeyPrefixesToRemove = environmentKeyPrefixesToRemove
        self.processWorkingDirectoryURL = processWorkingDirectoryURL
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
    public static func verify(
        definition: LocalACPRuntimeDefinition,
        resolution: LocalACPRuntimeResolution,
        workingDirectory: URL
    ) async -> LocalACPRuntimeResolution {
        guard let launch = resolution.launchConfiguration else {
            return resolution
        }
        if definition.runtimeKind == .cursor {
            return await verifyCursor(
                definition: definition,
                resolution: resolution,
                launch: launch,
                workingDirectory: workingDirectory
            )
        }
        if definition.runtimeKind == .pi {
            return await verifyPi(
                definition: definition,
                resolution: resolution,
                launch: launch,
                workingDirectory: workingDirectory
            )
        }
        guard let requirement = definition.readinessProbe else {
            return resolution
        }
        do {
            let probe = try await LocalACPClient.probeConnection(
                launch: launch,
                workingDirectory: workingDirectory
            )
            if let expectedAgentName = requirement.expectedAgentName,
               probe.agentName != expectedAgentName {
                return failedResolution(
                    definition: definition,
                    resolution: resolution,
                    state: .executableUnavailable,
                    detail: "\(definition.commandName) answered ACP as \(probe.agentName ?? "an unknown agent"), not \(expectedAgentName)."
                )
            }
            if let setupMethodID = requirement.setupAuthenticationMethodID,
               !probe.authenticationMethodIDs.contains(where: {
                   $0 != setupMethodID
               }) {
                return failedResolution(
                    definition: definition,
                    resolution: resolution,
                    state: .authenticationRequired,
                    detail: requirement.setupRequiredDetail
                )
            }
            return LocalACPRuntimeResolution(
                availability: LocalACPRuntimeAvailability(
                    runtimeKind: definition.runtimeKind,
                    displayName: definition.displayName,
                    state: .ready,
                    detail: requirement.readyDetail,
                    executablePath: resolution.availability.executablePath
                ),
                launchConfiguration: launch
            )
        } catch {
            return failedResolution(
                definition: definition,
                resolution: resolution,
                state: .executableUnavailable,
                detail: "\(definition.commandName) was found but did not complete the ACP readiness handshake: \(error.localizedDescription)"
            )
        }
    }

    private static func verifyPi(
        definition: LocalACPRuntimeDefinition,
        resolution: LocalACPRuntimeResolution,
        launch: LocalACPRuntimeLaunchConfiguration,
        workingDirectory: URL
    ) async -> LocalACPRuntimeResolution {
        do {
            let configuration = try await PiRPCClient.probe(
                launch: launch,
                workingDirectory: workingDirectory
            )
            if configuration.modelOptions.isEmpty {
                return failedResolution(
                    definition: definition,
                    resolution: resolution,
                    state: .authenticationRequired,
                    detail: PiRPCSupport.unauthenticatedDetail()
                )
            }
            return LocalACPRuntimeResolution(
                availability: LocalACPRuntimeAvailability(
                    runtimeKind: definition.runtimeKind,
                    displayName: definition.displayName,
                    state: .ready,
                    detail: PiRPCSupport.readyDetail(
                        modelCount: configuration.modelOptions.count
                    ),
                    executablePath: resolution.availability.executablePath
                ),
                launchConfiguration: launch
            )
        } catch {
            return failedResolution(
                definition: definition,
                resolution: resolution,
                state: .executableUnavailable,
                detail: "\(definition.commandName) was found but did not complete the RPC handshake: \(error.localizedDescription)"
            )
        }
    }

    private static func verifyCursor(
        definition: LocalACPRuntimeDefinition,
        resolution: LocalACPRuntimeResolution,
        launch: LocalACPRuntimeLaunchConfiguration,
        workingDirectory: URL
    ) async -> LocalACPRuntimeResolution {
        let about = CursorACPSupport.probeAbout(executable: launch.executableURL)
        if case .unauthenticated = about.auth {
            return failedResolution(
                definition: definition,
                resolution: resolution,
                state: .authenticationRequired,
                detail: about.message ?? CursorACPSupport.unauthenticatedDetail()
            )
        }
        do {
            _ = try await LocalACPClient.probeConnection(
                launch: launch,
                workingDirectory: workingDirectory
            )
            let email: String?
            if case .authenticated(let value) = about.auth {
                email = value
            } else {
                email = nil
            }
            return LocalACPRuntimeResolution(
                availability: LocalACPRuntimeAvailability(
                    runtimeKind: definition.runtimeKind,
                    displayName: definition.displayName,
                    state: .ready,
                    detail: CursorACPSupport.readyDetail(email: email),
                    executablePath: resolution.availability.executablePath
                ),
                launchConfiguration: launch
            )
        } catch {
            return failedResolution(
                definition: definition,
                resolution: resolution,
                state: .executableUnavailable,
                detail: "\(definition.commandName) was found but did not complete the ACP readiness handshake: \(error.localizedDescription)"
            )
        }
    }

    private static func failedResolution(
        definition: LocalACPRuntimeDefinition,
        resolution: LocalACPRuntimeResolution,
        state: LocalACPRuntimeAvailability.State,
        detail: String
    ) -> LocalACPRuntimeResolution {
        LocalACPRuntimeResolution(
            availability: LocalACPRuntimeAvailability(
                runtimeKind: definition.runtimeKind,
                displayName: definition.displayName,
                state: state,
                detail: detail,
                executablePath: resolution.availability.executablePath
            ),
            launchConfiguration: nil
        )
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

    init(executableSearchDirectoriesProvider: @escaping @Sendable () -> [String]) {
        searchDirectories = executableSearchDirectoriesProvider
    }

    /// Reuses one search-path discovery within a refresh. Create a new snapshot
    /// for each refresh so subsequent installs and PATH changes remain visible.
    public func snapshottingExecutableSearchDirectories() -> Self {
        Self(executableSearchDirectories: effectiveSearchDirectories)
    }

    public func resolve(
        runtimeKind: AgentRuntimeKind
    ) -> LocalACPRuntimeResolution {
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
            }
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

    public static var executableSearchPath: String {
        executableSearchDirectories().joined(separator: ":")
    }

    private func resolveExecutable(named name: String) -> URL? {
        Self.resolveExecutable(
            named: name,
            searchDirectories: effectiveSearchDirectories
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

    private var effectiveSearchDirectories: [String] {
        searchDirectories()
    }

    private func launchEnvironment(
        definition: LocalACPRuntimeDefinition,
        executable: URL,
        underlyingCLI: URL?
    ) -> [String: String] {
        let directories = (
            [executable.deletingLastPathComponent().path]
                + [underlyingCLI?.deletingLastPathComponent().path].compactMap { $0 }
                + effectiveSearchDirectories
        ).reduce(into: [String]()) { result, item in
            if !item.isEmpty, !result.contains(item) { result.append(item) }
        }
        var environment = definition.environment
        if definition.runtimeKind == .hermes {
            environment["HERMES_HOME"] = Self.hermesHomeDirectory(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                environment: ProcessInfo.processInfo.environment
            ).path
        }
        environment["PATH"] = directories.joined(separator: ":")
        return environment
    }

    static func hermesHomeDirectory(
        homeDirectory: URL,
        environment: [String: String]
    ) -> URL {
        if let explicit = environment["HERMES_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
                .standardizedFileURL
        }

        let root = homeDirectory.appending(
            path: ".hermes",
            directoryHint: .isDirectory
        )
        let activeProfileURL = root.appending(path: "active_profile")
        guard let rawProfile = try? String(
            contentsOf: activeProfileURL,
            encoding: .utf8
        ) else {
            return root
        }
        let profile = rawProfile.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard profile != "default", Self.isValidHermesProfileName(profile) else {
            return root
        }
        return root
            .appending(path: "profiles", directoryHint: .isDirectory)
            .appending(path: profile, directoryHint: .isDirectory)
    }

    private static func isValidHermesProfileName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count),
              let first = bytes.first,
              Self.isASCIILowercaseLetter(first) || Self.isASCIIDigit(first) else {
            return false
        }
        return bytes.allSatisfy {
            Self.isASCIILowercaseLetter($0) || Self.isASCIIDigit($0)
                || $0 == 95 || $0 == 45
        }
    }

    private static func isASCIILowercaseLetter(_ byte: UInt8) -> Bool {
        byte >= 97 && byte <= 122
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
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
            home.appending(path: ".openclaw/bin").path,
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
        )
            .reduce(into: [String]()) { result, item in
                if !item.isEmpty, !result.contains(item) { result.append(item) }
            }
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
