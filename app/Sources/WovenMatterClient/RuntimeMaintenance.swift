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
        let latest = checkLatest ? await latestVersion(kind: kind, package: definition.adapterPackage, fetch: fetch) : nil
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
            // on the Claude Agent SDK library its release pins; updating the adapter moves it.
            if kind == .claudeCode {
                let dependency = "@anthropic-ai/claude-agent-sdk"
                let bundled = root.flatMap { dependencyRoot(from: $0, name: dependency) }
                let version = bundled.flatMap { packageVersion(at: $0) }
                let supported = version.map { installed in
                    definition.minimumEngineVersion.map { !Self.version(installed, precedes: $0) } ?? true
                } ?? false
                components.append(RuntimeComponent(name: "Bundled \(dependency)", executable: nil,
                    installed: version, latest: nil, package: nil, required: true, present: version != nil, verified: supported))
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
                // Compare with the channel the vendor's own update command follows, which can
                // trail npm by a release or two.
                let cliLatest: String? = checkLatest ? await vendorChannelVersion(kind, fetch: fetch) : nil
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
        let limitation: String? = switch kind {
        case .codex: "Chat runs your Codex CLI through the codex-acp adapter."
        case .claudeCode: "Chat runs your Claude Code CLI through the Claude Agent ACP adapter."
        case .opencode: "Woven Matter, Terminal and the OpenCode app share one OpenCode service. Updating restarts it."
        default: nil
        }
        return RuntimeInventory(kind: kind, components: components, limitation: limitation)
    }

    /// The newest Claude Code release on its native channel, which `claude update` installs.
    static let claudeCodeNativeChannel = URL(string: "https://downloads.claude.ai/claude-code-releases/latest")!
    /// The channels each vendor's official installer and update command read.
    static let codexNativeChannel = URL(string: "https://releases.openai.com/codex/channels/latest")!
    static let grokNativeChannel = URL(string: "https://x.ai/cli/stable")!
    static let openCodeNativeChannel = URL(string: "https://opencode.ai/update/api/latest/cli/npm")!

    /// The newest release the vendor's own installer and update command would install.
    static func vendorChannelVersion(_ kind: AgentRuntimeKind, fetch: Fetch) async -> String? {
        do {
            switch kind {
            case .claudeCode:
                return normalizeVersion(String(decoding: try await fetch(claudeCodeNativeChannel), as: UTF8.self))
            case .grokBuild:
                return normalizeVersion(String(decoding: try await fetch(grokNativeChannel), as: UTF8.self))
            case .codex:
                // {"tag_name": "rust-v0.169.1", …}, as Codex's install.sh reads it.
                let metadata = try JSONSerialization.jsonObject(with: try await fetch(codexNativeChannel)) as? [String: Any]
                guard let tag = metadata?["tag_name"] as? String, tag.hasPrefix("rust-v") else { return nil }
                return normalizeVersion(String(tag.dropFirst("rust-v".count)))
            case .opencode:
                let metadata = try JSONSerialization.jsonObject(with: try await fetch(openCodeNativeChannel)) as? [String: Any]
                guard let version = (metadata?["version"] as? String).flatMap(normalizeVersion),
                      OpenCodeConnection.supportsVersion(version) else { return nil }
                return version
            default: return nil
            }
        } catch { return nil }
    }

    /// The row for the person's own CLI that an ACP adapter drives ("codex CLI").
    public static func cliComponentName(_ cliName: String) -> String { cliName + " CLI" }

    /// Updates an installed CLI with its vendor's own command (`claude update`, `codex update`,
    /// `grok update`, `opencode upgrade`), run in the person's login shell with no window, so
    /// it updates the install their terminal uses, however it was installed.
    public static func runVendorUpdate(_ kind: AgentRuntimeKind, executable: URL, timeout: TimeInterval = 600,
                                       run: @escaping VendorCommandRunner = runInLoginShell) async throws {
        guard let arguments = vendorUpdateArguments(kind) else { throw RuntimeMaintenanceError.unavailable }
        let result = try await LocalACPProcessRunner.offCooperativePool { try run(executable, arguments, timeout) }
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

    /// An adapter's newest npm release, or a CLI's newest release on its vendor's channel.
    static func latestVersion(kind: AgentRuntimeKind, package: String?, fetch: Fetch) async -> String? {
        if let package { return try? await registryVersion(package, fetch: fetch) }
        return await vendorChannelVersion(kind, fetch: fetch)
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
        Codex, Claude Code and Grok Build run the person's native CLI (~/.local/bin/codex, ~/.local/bin/claude, ~/.grok/bin/grok), installed by each vendor's official installer and updated by its own update command. Codex and Claude Code connect through ACP adapters in the managed npm prefix, pointed at that CLI with CODEX_PATH / CLAUDE_CODE_EXECUTABLE. OpenCode is OpenCode 2 on its shared service. Preserve active sessions. Ask before changing host installations. Raw command output and credentials were omitted.
        """
    }
}

public enum RuntimeMaintenanceError: LocalizedError {
    case unavailable, verification, busy, timeout, signingIn
    /// The vendor's update command finished, but the CLI is on the same version.
    case unchanged(name: String, version: String)
    public var errorDescription: String? {
        switch self {
        case .unchanged(let name, let version): "\(name) is still \(version): its update command finished without updating it."
        case .unavailable: "Latest version information is unavailable. Retry when the update source is reachable."
        case .verification: "Installation finished, but the selected runtime or its required dependencies could not be verified. Retry installation."
        case .timeout: "The runtime command timed out. Retry after checking the installation."
        case .busy: "Wait for the current runtime operation or conversation to finish."
        case .signingIn: "Finish signing in, then update."
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
