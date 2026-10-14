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
    public var detectedUpdateAvailable = false
    public var versionCheckAvailable: Bool? = nil
    public var updateAvailable: Bool { outdated || detectedUpdateAvailable }
    public var isInstalled: Bool { !components.isEmpty && components.allSatisfy { !$0.required || ($0.present && $0.verified) } }
    public var outdated: Bool { components.contains(where: \.outdated) }
    public var summary: String {
        components.map { component in
            "\(component.name) \(component.present ? component.installed ?? "version unavailable" : "missing")"
                + (component.outdated ? " → \(component.latest!)" : "")
        }.joined(separator: " · ")
    }
    public var latestUnavailable: Bool { components.contains { $0.required && !$0.name.hasPrefix("Bundled ") && $0.latest == nil } }
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
        guard AgentRuntimeKind.allCases.contains(kind),
              let definition = kind == .opencode ? OpenCodeServiceLauncher.installDefinition : LocalACPRuntimeCatalog.definition(for: kind) else {
            return RuntimeInventory(kind: kind, components: [], limitation: "This agent is retired. Its saved history remains available.")
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
            let dependency = kind == .codex ? "@openai/codex" : "@anthropic-ai/claude-agent-sdk"
            let root = executable.flatMap { packageRoot(executable: $0, name: adapter) }
            let bundled = root.flatMap { dependencyRoot(from: $0, name: dependency) }
            let version = bundled.flatMap { packageVersion(at: $0) }
            let engine = bundled.flatMap { bundledEngine(in: $0, kind: kind) }
            let present = engine.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
            let engineVersion = present ? engine.flatMap(probe).flatMap(normalizeVersion) : nil
            components.append(RuntimeComponent(name: "Bundled \(dependency)", executable: nil,
                installed: version, latest: nil, package: nil, required: true, present: present, verified: version != nil && engineVersion != nil))
            if kind == .claudeCode {
                components.append(RuntimeComponent(name: "Bundled Claude Code", executable: nil,
                    installed: engineVersion, latest: nil, package: nil, required: true,
                    present: present, verified: engineVersion != nil))
            }
            if let cliName = definition.underlyingCLIName {
                let cli = resolver.executable(named: cliName)
                let cliPackage = kind == .codex ? "@openai/codex" : "@anthropic-ai/claude-code"
                let cliLatest = checkLatest ? try? await registryVersion(cliPackage, fetch: fetch) : nil
                components.append(RuntimeComponent(name: cliName + " (sign-in CLI)", executable: cli,
                    installed: cli.flatMap(probe).flatMap(normalizeVersion), latest: cliLatest,
                    package: nil, required: true, present: cli != nil))
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
            : "Chat uses the adapter’s bundled Codex; adapter updates include its engine."
        case .claudeCode: ProcessInfo.processInfo.environment["CLAUDE_CODE_EXECUTABLE"]?.isEmpty == false
            ? "Chat has an inherited Claude executable override; its version is reported separately."
            : "Chat uses the adapter’s bundled Claude SDK."
        case .opencode: "OpenCode v2 releases can be updated independently. The running service is not restarted."
        default: nil
        }
        return RuntimeInventory(kind: kind, components: components, limitation: limitation)
    }

    public static func updateNative(_ kind: AgentRuntimeKind, executable: URL?) async throws {
        guard let executable else { throw RuntimeMaintenanceError.verification }
        if kind == .codex {
            let definition = LocalACPRuntimeCatalog.definition(for: kind)!
            let installer = LocalACPRuntimeInstaller()
            let preview = try await installer.prepareCLIInstall(definition)
            _ = try await installer.install(definition, component: .cli, expectedSourceSHA256: preview.sha256)
            return
        }
        guard [.claudeCode, .grokBuild].contains(kind) else { throw RuntimeMaintenanceError.unavailable }
        let result = try await Task.detached(priority: .utility) {
            try LocalACPProcessRunner.run(executableURL: executable, arguments: ["update"],
                environment: ProcessInfo.processInfo.environment.merging(["PATH": LocalACPRuntimeResolver.executableSearchPath]) { _, new in new })
        }.value
        guard result.succeeded else { throw LocalACPRuntimeInstallError.installFailed(result.combinedOutput) }
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

    public static func registryVersion(_ package: String, tag: String = "latest", fetch: Fetch = fetchMetadata) async throws -> String {
        let encoded = package.replacingOccurrences(of: "/", with: "%2f")
        let base = "https://registry.npmjs.org/\(encoded)"
        let supportedMajor = package == "@opencode/cli" ? 2 : nil
        func supported(_ version: String) -> Bool {
            guard LocalACPRuntimeInstaller.isExactSemanticVersion(version) else { return false }
            guard let supportedMajor else { return true }
            return !version.contains("-") && version.split(separator: ".").first == Substring(String(supportedMajor))
        }
        let data = try await fetch(URL(string: "\(base)/\(tag)")!)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let version = object?["version"] as? String, supported(version), object?["bin"] != nil, object?["deprecated"] == nil { return version }
        // A moving upstream tag can advance beyond the API family we implement.
        // Choose the newest stable release in that family rather than an old pin.
        guard supportedMajor != nil else { throw RuntimeMaintenanceError.unavailable }
        let metadata = try JSONSerialization.jsonObject(with: await fetch(URL(string: base)!)) as? [String: Any]
        let versions = metadata?["versions"] as? [String: [String: Any]] ?? [:]
        guard let newest = versions.keys.filter({ supported($0) && versions[$0]?["bin"] != nil && versions[$0]?["deprecated"] == nil })
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
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Latest version information is unavailable. Retry when the update source is reachable."
        case .verification: "Installation finished, but the selected runtime or its required dependencies could not be verified. Retry installation."
        case .timeout: "The runtime command timed out. Retry after checking the installation."
        case .busy: "Wait for the current runtime operation or conversation to finish."
        }
    }
}
