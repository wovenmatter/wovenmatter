import Foundation
import WovenMatterCore

/// Inventory follows the executable selected for launch, including nested SDKs.
/// A standalone CLI version is never used as the adapter's engine version.
public struct RuntimeComponent: Codable, Equatable, Sendable {
    public let name: String
    public let executable: URL?
    public let installed: String?
    public let latest: String?
    public let package: String?
    public let required: Bool
    public let present: Bool
    public var verified: Bool = true

    public var outdated: Bool {
        guard let installed, let latest else { return false }
        return RuntimeMaintenance.version(installed, precedes: latest)
    }
}

public struct RuntimeInventory: Codable, Equatable, Sendable {
    public let kind: AgentRuntimeKind
    public let components: [RuntimeComponent]
    public let limitation: String?
    public var versionCheckAvailable: Bool? = nil
    public var updateAvailable: Bool { outdated }
    public var isInstalled: Bool { !components.isEmpty && components.allSatisfy { !$0.required || ($0.present && $0.verified) } }
    public var outdated: Bool { components.contains(where: \.outdated) }
    public var summary: String {
        components.map { component in
            "\(component.name) \(component.present ? component.installed ?? "version unavailable" : "missing")"
                + (component.outdated ? " → \(component.latest!)" : "")
        }.joined(separator: " · ")
    }
    public var latestUnavailable: Bool { components.contains { $0.required && (!$0.name.hasPrefix("Bundled ") || $0.package != nil) && $0.latest == nil } }
}

public enum RuntimeMaintenance {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public typealias Probe = @Sendable (URL) -> String?

    public static func inspect(
        _ kind: AgentRuntimeKind,
        checkLatest: Bool,
        resolver: LocalACPRuntimeResolver = LocalACPRuntimeResolver(),
        selectedOpenCode: URL? = nil,
        openCodeRegistration: URL = OpenCodeConnection.registrationURL(),
        fetch: @escaping Fetch = fetchMetadata,
        probe: @escaping Probe = probeVersion
    ) async -> RuntimeInventory {
        guard let definition = kind == .opencode ? OpenCodeServiceLauncher.installDefinition : LocalACPRuntimeCatalog.definition(for: kind) else {
            return RuntimeInventory(kind: kind, components: [], limitation: "This agent has no install definition.")
        }
        let resolution = resolver.resolve(runtimeKind: kind)
        let executable = kind == .opencode
            ? selectedOpenCode ?? OpenCodeServiceLauncher.resolveExecutable(resolver: resolver, probe: probe)
            : resolution.availability.executablePath.map { URL(fileURLWithPath: $0) }
                ?? definition.commandNames.compactMap { resolver.executable(named: $0) }.first
        var components: [RuntimeComponent] = []
        let package = definition.adapterPackage ?? npmPackage(kind)
        let installed = executable.flatMap { probe($0) }.flatMap(normalizeVersion)
        let latest = checkLatest ? await latestVersion(kind: kind, package: package, fetch: fetch) : nil
        let minimumSatisfied = definition.minimumAdapterVersion.map { minimum in
            installed.map { !version($0, precedes: minimum) } ?? false
        } ?? true
        components.append(RuntimeComponent(name: definition.commandName, executable: executable,
            installed: installed, latest: latest, package: package, required: true, present: executable != nil, verified: installed != nil && minimumSatisfied && (kind != .opencode || installed.map(OpenCodeConnection.supportsVersion) == true)))
        if kind == .opencode {
            // Registration is a declaration, not proof that a service is live.
            // Enable/connect still verifies authenticated health and process identity.
            let registered = try? OpenCodeConnection.discover(file: openCodeRegistration)
            components.append(RuntimeComponent(name: "Registered OpenCode service", executable: nil,
                installed: registered?.version.flatMap(normalizeVersion), latest: nil, package: nil,
                required: false, present: registered != nil))
        }
        if let adapter = definition.adapterPackage {
            let root = executable.flatMap { packageRoot(executable: $0, name: adapter) }
            // The adapter drives the person's own CLI (CODEX_PATH / CLAUDE_CODE_EXECUTABLE), so
            // a copy of the CLI bundled inside it isn't reported. Claude's adapter still runs
            // on its Claude Agent SDK library, which is.
            if kind == .claudeCode {
                let dependency = "@anthropic-ai/claude-agent-sdk"
                let bundled = root.flatMap { dependencyRoot(from: $0, name: dependency) }
                let version = bundled.flatMap { packageVersion(at: $0) }
                components.append(RuntimeComponent(name: "Bundled \(dependency)", executable: nil,
                    installed: version, latest: checkLatest ? try? await registryVersion(dependency, executableRequired: false, fetch: fetch) : definition.minimumEngineVersion, package: dependency, required: true, present: version != nil, verified: version != nil))
            }
            if let minimum = definition.minimumProtocolSDKVersion {
                let sdk = root.flatMap { dependencyRoot(from: $0, name: "@agentclientprotocol/sdk") }
                let installed = sdk.flatMap { packageVersion(at: $0) }
                components.append(RuntimeComponent(name: "Bundled ACP SDK", executable: nil,
                    installed: installed, latest: checkLatest ? try? await registryVersion("@agentclientprotocol/sdk", executableRequired: false, fetch: fetch) : minimum,
                    package: "@agentclientprotocol/sdk", required: true, present: sdk != nil, verified: installed != nil))
            }
            if let cliName = definition.underlyingCLIName {
                let cli = resolver.executable(named: cliName)
                // Compare with the channel the vendor's own update command follows: Claude
                // Code's native releases can trail its npm package by a release or two.
                let cliLatest: String? = !checkLatest ? nil : kind == .claudeCode
                    ? (try? await fetch(claudeCodeNativeChannel)).flatMap { normalizeVersion(String(decoding: $0, as: UTF8.self)) }
                    : try? await registryVersion("@openai/codex", fetch: fetch)
                let cliVersion = cli.flatMap(probe).flatMap(normalizeVersion)
                // codex-acp speaks Codex's app-server protocol, so the CLI must be at least the
                // engine version the adapter was released against.
                let cliSupported = kind != .codex || definition.minimumEngineVersion.map { minimum in
                    cliVersion.map { !version($0, precedes: minimum) } ?? false
                } ?? true
                components.append(RuntimeComponent(name: cliComponentName(cliName), executable: cli,
                    installed: cliVersion, latest: cliLatest ?? (cliSupported ? nil : definition.minimumEngineVersion),
                    package: nil, required: true, present: cli != nil, verified: cliVersion != nil && cliSupported))
            }
        }
        if kind == .codex || kind == .claudeCode {
            let key = kind == .codex ? "CODEX_PATH" : "CLAUDE_CODE_EXECUTABLE"
            if let override = ProcessInfo.processInfo.environment[key], !override.isEmpty {
                let path = override.hasPrefix("/") ? URL(fileURLWithPath: override) : resolver.executable(named: override)
                let found = path.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
                let overrideVersion = found ? path.flatMap(probe).flatMap(normalizeVersion) : nil
                components.append(RuntimeComponent(name: key + " override", executable: path,
                    installed: overrideVersion, latest: nil, package: nil, required: true,
                    present: found, verified: overrideVersion != nil))
            }
        }
        let limitation: String? = switch kind {
        case .codex: ProcessInfo.processInfo.environment["CODEX_PATH"]?.isEmpty == false
            ? "Chat has an inherited CODEX_PATH override; its version is reported separately."
            : "Chat uses the adapter and its independently updated Codex engine."
        case .claudeCode: ProcessInfo.processInfo.environment["CLAUDE_CODE_EXECUTABLE"]?.isEmpty == false
            ? "Chat has an inherited Claude executable override; its version is reported separately."
            : "Chat uses the adapter and its independently updated Claude SDK."
        case .opencode: "OpenCode v2 releases can be updated independently. The running service is not restarted."
        default: nil
        }
        return RuntimeInventory(kind: kind, components: components, limitation: limitation)
    }

    /// The newest Claude Code release on its native channel, which `claude update` installs.
    static let claudeCodeNativeChannel = URL(string: "https://downloads.claude.ai/claude-code-releases/latest")!

    /// The row for the person's own CLI that an ACP adapter drives ("codex CLI").
    public static func cliComponentName(_ cliName: String) -> String { cliName + " CLI" }

    /// Updates an installed CLI with its vendor's own command (`claude update`, `codex update`,
    /// `grok update`, `opencode upgrade`), run in the person's login shell with no window, so
    /// it updates the install their terminal uses, however it was installed.
    public static func runVendorUpdate(_ kind: AgentRuntimeKind, executable: URL, timeout: TimeInterval = 120,
                                       run: @escaping VendorCommandRunner = runInLoginShell) async throws {
        guard let arguments = vendorUpdateArguments(kind) else { throw RuntimeMaintenanceError.unavailable }
        let result = try await Task.detached(priority: .utility) {
            try run(executable, arguments, timeout)
        }.value
        guard result.succeeded else { throw LocalACPRuntimeInstallError.installFailed(result.combinedOutput) }
    }

    public typealias VendorCommandRunner = @Sendable (URL, [String], TimeInterval) throws -> LocalACPProcessResult

    /// Each harness's update command from the shared catalog.
    public static func vendorUpdateArguments(_ kind: AgentRuntimeKind) -> [String]? {
        LocalACPRuntimeCatalog.definition(for: kind).flatMap { $0.updateArguments.isEmpty ? nil : $0.updateArguments }
    }

    /// Runs `executable arguments…` through `zsh -l`, which loads the person's PATH and
    /// configuration as a Terminal window would. The executable and arguments are passed as
    /// positional parameters, never spliced into the script.
    public static func runInLoginShell(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> LocalACPProcessResult {
        try LocalACPProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-l", "-c", #"exec "$0" "$@""#, executable.path] + arguments,
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser, timeout: timeout)
    }

    public static func npmPackage(_ kind: AgentRuntimeKind) -> String? {
        switch kind {
        case .codex: "@agentclientprotocol/codex-acp"
        case .claudeCode: "@agentclientprotocol/claude-agent-acp"
        case .opencode: "@opencode/cli"
        default: nil
        }
    }

    static func latestVersion(kind: AgentRuntimeKind, package: String?, fetch: Fetch) async -> String? {
        if let package { return try? await registryVersion(package, fetch: fetch) }
        do {
            switch kind {
            case .grokBuild:
                return normalizeVersion(String(decoding: try await fetch(URL(string: "https://x.ai/cli/stable")!), as: UTF8.self))
            default: return nil
            }
        } catch { return nil }
    }

    public static func registryVersion(_ package: String, tag: String = "latest", executableRequired: Bool = true, fetch: Fetch = fetchMetadata) async throws -> String {
        let encoded = package.replacingOccurrences(of: "/", with: "%2f")
        let base = "https://registry.npmjs.org/\(encoded)"
        let supportedMajor = package == "@opencode/cli" ? 2 : nil
        func supported(_ version: String) -> Bool {
            guard LocalACPRuntimeInstaller.isExactSemanticVersion(version) else { return false }
            guard let supportedMajor else { return true }
            return !version.contains("-") && version.split(separator: ".").first == Substring(String(supportedMajor))
        }
        let metadata = try JSONSerialization.jsonObject(with: await fetch(URL(string: base)!)) as? [String: Any]
        // Inspect publications rather than a potentially stale dist-tag. Adapter,
        // engine and standalone CLI each select their own newest stable release.
        let versions = metadata?["versions"] as? [String: [String: Any]]
            ?? (metadata?["version"] as? String).map { [$0: metadata ?? [:]] } ?? [:]
        guard let newest = versions.keys.filter({ supported($0) && !$0.contains("-")
            && (!executableRequired || versions[$0]?["bin"] != nil) && versions[$0]?["deprecated"] == nil })
            .sorted(by: { version($0, precedes: $1) }).last else { throw RuntimeMaintenanceError.unavailable }
        return newest
    }

    public static func fetchMetadata(_ url: URL) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(path: "runtime-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await LocalACPBoundedHTTPSDownloader.download(url, to: file, maximumBytes: 32 * 1_024 * 1_024)
        return try Data(contentsOf: file)
    }

    public static func probeVersion(_ executable: URL) -> String? {
        guard let result = try? LocalACPProcessRunner.run(executableURL: executable, arguments: ["--version"],
            environment: ProcessInfo.processInfo.environment.merging(["PATH": executable.deletingLastPathComponent().path + ":" + LocalACPManagedRuntimePaths.nodeBinDirectory().path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")]) { _, new in new }, timeout: 15), result.succeeded else { return nil }
        return result.stdout
    }

    public static func normalizeVersion(_ output: String) -> String? {
        guard let range = output.range(of: #"(?<![0-9])[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    public static func version(_ installed: String, precedes latest: String) -> Bool {
        guard let a = normalizeVersion(installed), let b = normalizeVersion(latest), a != b else { return false }
        let aParts = a.split(separator: "-", maxSplits: 1); let bParts = b.split(separator: "-", maxSplits: 1)
        let aNumbers = aParts[0].split(separator: ".").compactMap { Int($0) }
        let bNumbers = bParts[0].split(separator: ".").compactMap { Int($0) }
        if aNumbers != bNumbers { return aNumbers.lexicographicallyPrecedes(bNumbers) }
        if aParts.count == 1 { return false }
        if bParts.count == 1 { return true }
        // Calendar/hash versions on the same date have no defined ordering.
        if aNumbers.first ?? 0 > 2000 { return false }
        return String(aParts[1]).compare(String(bParts[1]), options: .numeric) == .orderedAscending
    }

    static func bundledEngine(in root: URL, kind: AgentRuntimeKind) -> URL? {
        if kind == .codex { return root.appending(path: "bin/codex.js") }
        #if arch(arm64)
        let nativePackage = "@anthropic-ai/claude-agent-sdk-darwin-arm64"
        #else
        let nativePackage = "@anthropic-ai/claude-agent-sdk-darwin-x64"
        #endif
        let optional = packageObject(at: root)?["optionalDependencies"] as? [String: Any]
        if optional?[nativePackage] != nil {
            return dependencyRoot(from: root, name: nativePackage)?.appending(path: "claude")
        }
        return root.appending(path: "cli.js")
    }

    static func packageRoot(executable: URL, name: String) -> URL? {
        var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<12 {
            if packageObject(at: directory)?["name"] as? String == name { return directory }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }; directory = parent
        }
        return nil
    }

    static func dependencyRoot(from root: URL, name: String) -> URL? {
        var directory = root
        for _ in 0..<12 {
            let candidate = directory.appending(path: "node_modules/" + name)
            if packageObject(at: candidate)?["name"] as? String == name { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }; directory = parent
        }
        return nil
    }

    static func packageObject(at root: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appending(path: "package.json")), data.count < 2 * 1_024 * 1_024 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func packageVersion(at root: URL) -> String? { packageObject(at: root)?["version"] as? String }

    /// Diagnostic output is allowlisted: versions and error category, never raw
    /// installer output, environment, credential paths, URLs or account details.
    public static func diagnostic(inventory: RuntimeInventory?, kind: AgentRuntimeKind, attempts: Int, failure: String) -> String {
        let components = inventory?.components.map {
            "\($0.name): installed=\($0.installed.flatMap(normalizeVersion) ?? "unknown"), latest=\($0.latest.flatMap(normalizeVersion) ?? "unknown"), present=\($0.present)"
        }.joined(separator: "\n") ?? "Inventory unavailable"
        return """
        Diagnose Woven Matter \(kind.displayName) installation/update after \(attempts) failed attempts on macOS.
        \(components)
        Failure category: \(failure)
        \(inventory?.limitation ?? "")
        Managed npm prefix: ~/Library/Application Support/Woven Matter/Node Tools.
        Inspect the executable Woven Matter resolves and its actual dependencies. For Codex, inspect codex-acp and its bundled @openai/codex; do not assume the standalone codex is the chat engine or set CODEX_PATH as a shortcut. Preserve active sessions. Ask before changing host installations. Raw command output and credentials were omitted.
        """
    }
}

public enum RuntimeMaintenanceError: LocalizedError {
    case unavailable, verification, busy, timeout
    /// The vendor's update command finished, but the CLI is on the same version.
    case unchanged(name: String, version: String)
    public var errorDescription: String? {
        switch self {
        case .unchanged(let name, let version): "\(name) is still \(version): its update command finished without updating it."
        case .unavailable: "Latest version information is unavailable. Retry when the update source is reachable."
        case .verification: "Installation finished, but the selected runtime or its required dependencies could not be verified. Retry installation."
        case .timeout: "The runtime command timed out. Retry after checking the installation."
        case .busy: "Wait for the current runtime operation or conversation to finish."
        }
    }
}

extension RuntimeInventory {
    /// This Mac's inventory in the shape a Linux host serves at `/v1/runtime-maintenance`,
    /// so another Mac's Settings → Updates reads both the same way. Paths stay on this Mac.
    public func maintenance(operation: RemoteHarnessOperation? = nil, failureCount: Int = 0) -> RemoteRuntimeMaintenance {
        // As a Linux host reports it: the person's own CLI is `cli` (native) beside the ACP
        // adapter's `runtime` (managed), or `runtime` itself for a harness without an adapter.
        let definition = LocalACPRuntimeCatalog.definition(for: kind)
        let cliName = definition?.underlyingCLIName.map(RuntimeMaintenance.cliComponentName) ?? definition?.commandName
        return RemoteRuntimeMaintenance(
            id: kind, displayName: kind.displayName, installed: isInstalled,
            components: components.enumerated().map { index, component in
                let native = component.name == cliName
                return RemoteRuntimeComponent(id: native && index > 0 ? "cli" : index == 0 ? "runtime" : component.name,
                                       displayName: component.name, path: nil,
                                       installedVersion: component.installed, latestVersion: component.latest,
                                       source: native ? (component.present ? "native" : "missing") : "managed",
                                       required: component.required,
                                       installed: component.present && component.verified)
            },
            operation: operation, failureCount: failureCount, notice: limitation,
            updateAvailable: updateAvailable, versionCheckAvailable: versionCheckAvailable ?? !latestUnavailable)
    }
}
