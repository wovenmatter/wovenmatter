import Foundation
import WovenMatterCore

/// Inventory follows the executable selected for launch, including nested SDKs.
/// A standalone CLI version is never used as the adapter's engine version.
public struct RuntimeComponent: Equatable, Sendable {
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

public struct RuntimeInventory: Equatable, Sendable {
    public let kind: AgentRuntimeKind
    public let components: [RuntimeComponent]
    public let limitation: String?
    public var updateNotice: String? = nil
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
    public var latestUnavailable: Bool { if kind == .hermes { return versionCheckAvailable == false }; return components.contains { $0.required && !$0.name.hasPrefix("Bundled ") && $0.latest == nil } }
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
        let definition = kind == .opencode ? OpenCodeServiceLauncher.installDefinition : LocalACPRuntimeCatalog.definition(for: kind)!
        let resolution = resolver.resolve(runtimeKind: kind)
        let executable = kind == .opencode
            ? selectedOpenCode ?? resolver.executable(named: "opencode2")
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
            installed: installed, latest: latest, package: package, required: true, present: executable != nil, verified: installed != nil && minimumSatisfied && (kind != .opencode || installed == OpenCodeConnection.supportedVersion)))
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
        if kind == .hermes, let executable {
            let environment = ProcessInfo.processInfo.environment.merging(["PATH": LocalACPRuntimeResolver.executableSearchPath]) { _, new in new }
            let version = try? LocalACPProcessRunner.run(executableURL: executable, arguments: ["acp", "--version"], environment: environment, timeout: 15)
            let check = try? LocalACPProcessRunner.run(executableURL: executable, arguments: ["acp", "--check"], environment: environment, timeout: 30)
            components.append(RuntimeComponent(name: "Native ACP", executable: executable,
                installed: version?.succeeded == true ? normalizeVersion(version!.stdout) : nil, latest: latest,
                package: "hermes-agent", required: true, present: check?.succeeded == true,
                verified: check?.succeeded == true && version?.succeeded == true))
            if let python = hermesPython(executable) {
                let metadata = try? LocalACPProcessRunner.run(executableURL: python,
                    arguments: ["-c", "import importlib.metadata; print(importlib.metadata.version('agent-client-protocol'))"], environment: environment, timeout: 15)
                if metadata?.succeeded == true, let version = metadata.flatMap({ normalizeVersion($0.stdout) }) {
                    components.append(RuntimeComponent(name: "ACP SDK", executable: nil, installed: version, latest: nil,
                        package: "agent-client-protocol", required: false, present: true))
                }
            }
        }
        let limitation: String? = switch kind {
        case .codex: ProcessInfo.processInfo.environment["CODEX_PATH"]?.isEmpty == false
            ? "Chat has an inherited CODEX_PATH override; its version is reported separately."
            : "Chat uses the adapter’s bundled Codex; adapter updates include its engine."
        case .claudeCode: ProcessInfo.processInfo.environment["CLAUDE_CODE_EXECUTABLE"]?.isEmpty == false
            ? "Chat has an inherited Claude executable override; its version is reported separately."
            : "Chat uses the adapter’s bundled Claude SDK."
        case .opencode: "Service compatibility is pinned to \(OpenCodeConnection.supportedVersion). Newer releases require app support; the running service is not restarted."
        case .openclaw: "Local CLI only. Linked gateways and their provider runtimes are managed on the gateway host."
        case .hermes: "Native ACP; updates require idle Hermes services."
        default: nil
        }
        var inventory = RuntimeInventory(kind: kind, components: components, limitation: limitation)
        if kind == .hermes, checkLatest { inventory.versionCheckAvailable = false }
        if kind == .hermes, checkLatest, let executable {
            let result = try? LocalACPProcessRunner.run(executableURL: executable, arguments: ["update", "--check"],
                environment: ProcessInfo.processInfo.environment.merging(["PATH": resolver.executable(named: "hermes")?.deletingLastPathComponent().path ?? "/usr/bin:/bin"]) { old, new in new + ":" + old }, timeout: 30)
            let check = result?.succeeded == true ? hermesCheck(result!.stdout) : nil
            inventory.detectedUpdateAvailable = check == true
            inventory.versionCheckAvailable = check != nil
            inventory.updateNotice = check.map { $0 ? "Update available." : "Up to date." }
                ?? "Latest unavailable."
        }
        return inventory
    }

    static func hermesCheck(_ output: String) -> Bool? {
        let available = output.contains("Update available:") || output.contains("Update available (behind ")
        let current = output.contains("Already up to date.")
        guard available != current else { return nil }
        return available
    }

    public static func updateNative(_ kind: AgentRuntimeKind, executable: URL?) async throws {
        guard let executable else { throw RuntimeMaintenanceError.verification }
        if kind == .hermes {
            try await Task.detached(priority: .utility) { try updateHermes(executable: executable) }.value
            return
        }
        if kind == .openclaw {
            let version = try await registryVersion("openclaw")
            _ = try await LocalACPRuntimeInstaller().installPackage("openclaw", version: version, executableName: "openclaw")
            return
        }
        if kind == .codex {
            let definition = LocalACPRuntimeCatalog.definition(for: kind)!
            let installer = LocalACPRuntimeInstaller()
            let preview = try await installer.prepareCLIInstall(definition)
            _ = try await installer.install(definition, component: .cli, expectedSourceSHA256: preview.sha256)
            return
        }
        guard [.claudeCode, .cursor, .grokBuild].contains(kind) else { throw RuntimeMaintenanceError.unavailable }
        let result = try await Task.detached(priority: .utility) {
            try LocalACPProcessRunner.run(executableURL: executable, arguments: ["update"],
                environment: ProcessInfo.processInfo.environment.merging(["PATH": LocalACPRuntimeResolver.executableSearchPath]) { _, new in new })
        }.value
        guard result.succeeded else { throw LocalACPRuntimeInstallError.installFailed(result.combinedOutput) }
    }

    // Official update parser exposes --yes/--plan, but no --no-restart. A
    // confirmed idle fleet is required because the updater owns all profiles.
    static func hermesPlanAllowsUpdate(_ output: String) -> Bool {
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.contains("Update plan:")
            && lines.contains(where: { $0 == "Install: git" || $0.hasPrefix("Install: git (") })
            && lines.contains("Running Hermes services: none detected — code swap only.")
            && !output.contains("NOT updatable in place") && !output.contains("Running services to restart")
    }

    static func hermesHasActiveProcesses(_ output: String) -> Bool {
        output.components(separatedBy: .newlines).contains { line in
            line.split(whereSeparator: \.isWhitespace).contains { token in
                let name = String(token).split(separator: "/").last.map(String.init) ?? ""
                return ["hermes", "hermes-acp", "hermes-agent", "hermes_cli.main", "acp_adapter.entry"].contains(name)
            }
        }
    }

    static func updateHermes(executable: URL,
        run: (URL, [String], TimeInterval) throws -> LocalACPProcessResult = { executable, arguments, timeout in
            try LocalACPProcessRunner.run(executableURL: executable, arguments: arguments,
                environment: ProcessInfo.processInfo.environment.merging(["PATH": LocalACPRuntimeResolver.executableSearchPath, "GIT_TERMINAL_PROMPT": "0"]) { _, new in new }, timeout: timeout)
        }
    ) throws {
        guard let installation = hermesInstallation(executable) else { throw RuntimeMaintenanceError.hermesCheckoutUnverified }
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let top = try run(git, ["-C", installation.root.path, "rev-parse", "--show-toplevel"], 15)
        guard top.succeeded, URL(fileURLWithPath: top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath() == installation.root.resolvingSymlinksInPath() else { throw RuntimeMaintenanceError.hermesCheckoutUnverified }
        let status = try run(git, ["-C", installation.root.path, "status", "--porcelain", "--untracked-files=normal"], 15)
        guard status.succeeded, status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuntimeMaintenanceError.hermesCheckoutDirty }
        let plan = try run(executable, ["update", "--plan"], 30)
        guard plan.succeeded, hermesPlanAllowsUpdate(plan.stdout) else { throw RuntimeMaintenanceError.hermesUpdateUnsafe }
        let processes = try run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,command="], 15)
        guard processes.succeeded, !hermesHasActiveProcesses(processes.stdout) else { throw RuntimeMaintenanceError.busy }
        let help = try run(executable, ["update", "--help"], 15)
        guard help.succeeded, help.stdout.contains("--yes") else { throw RuntimeMaintenanceError.unavailable }
        let result = try run(executable, ["update", "--yes"], 600)
        guard result.succeeded else { throw LocalACPRuntimeInstallError.installFailed(result.combinedOutput) }
        let checked = try run(executable, ["update", "--check"], 30)
        let acp = try run(executable, ["acp", "--check"], 30)
        let version = try run(executable, ["acp", "--version"], 15)
        guard checked.succeeded, hermesCheck(checked.stdout) == false, acp.succeeded,
              version.succeeded, normalizeVersion(version.stdout) != nil else { throw RuntimeMaintenanceError.verification }
    }

    static func hermesInstallation(_ executable: URL) -> (root: URL, python: URL)? {
        let resolved = executable.resolvingSymlinksInPath()
        var candidates: [(URL, URL)] = []
        // Current official installer writes this literal two-path shell shim.
        // Parse paths only; never source or evaluate the launcher as shell code.
        if let text = try? String(contentsOf: resolved, encoding: .utf8), text.utf8.count < 16_384,
           let regex = try? NSRegularExpression(pattern: #"(?m)^exec "(/[^"\n]+)" "(/[^"\n]+/hermes)" "\$@"$"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let p = Range(match.range(at: 1), in: text), let entry = Range(match.range(at: 2), in: text) {
            candidates.append((URL(fileURLWithPath: String(text[entry])).deletingLastPathComponent(), URL(fileURLWithPath: String(text[p]))))
        }
        let bin = resolved.deletingLastPathComponent()
        if bin.lastPathComponent == "bin", ["venv", ".venv"].contains(bin.deletingLastPathComponent().lastPathComponent) {
            candidates.append((bin.deletingLastPathComponent().deletingLastPathComponent(), bin.appending(path: "python")))
        }
        return candidates.first { root, python in
            let expected = [root.appending(path: "venv/bin/python").path, root.appending(path: ".venv/bin/python").path,
                root.appending(path: "venv/bin/python3").path, root.appending(path: ".venv/bin/python3").path]
            let metadata = try? String(contentsOf: root.appending(path: "pyproject.toml"), encoding: .utf8)
            return expected.contains(python.path) && FileManager.default.isExecutableFile(atPath: python.path)
                && metadata?.range(of: #"(?m)^name\s*=\s*["']hermes-agent["']\s*$"#, options: .regularExpression) != nil
        }
    }

    static func hermesPython(_ executable: URL) -> URL? { hermesInstallation(executable)?.python }

    public static func npmPackage(_ kind: AgentRuntimeKind) -> String? {
        switch kind {
        case .codex: "@agentclientprotocol/codex-acp"
        case .claudeCode: "@agentclientprotocol/claude-agent-acp"
        case .pi: "@earendil-works/pi-coding-agent"
        case .openclaw: "openclaw"
        case .opencode: "@opencode/cli"
        default: nil
        }
    }

    static func latestVersion(kind: AgentRuntimeKind, package: String?, fetch: Fetch) async -> String? {
        if kind == .opencode {
            // `latest` is a reserved placeholder, not the v2 prerelease channel.
            return try? await registryVersion("@opencode/cli", tag: OpenCodeConnection.supportedVersion, fetch: fetch)
        }
        if let package { return try? await registryVersion(package, fetch: fetch) }
        do {
            switch kind {
            case .grokBuild:
                return normalizeVersion(String(decoding: try await fetch(URL(string: "https://x.ai/cli/stable")!), as: UTF8.self))
            case .cursor:
                let script = String(decoding: try await fetch(URL(string: "https://cursor.com/install")!), as: UTF8.self)
                guard let range = script.range(of: #"https://downloads\.cursor\.com/lab/([0-9]{4}\.[0-9]{2}\.[0-9]{2}-[a-z0-9]+)/"#, options: .regularExpression) else { return nil }
                return script[range].split(separator: "/").last.map(String.init)
            default: return nil
            }
        } catch { return nil }
    }

    public static func registryVersion(_ package: String, tag: String = "latest", fetch: Fetch = fetchMetadata) async throws -> String {
        let encoded = package.replacingOccurrences(of: "/", with: "%2f")
        let data = try await fetch(URL(string: "https://registry.npmjs.org/\(encoded)/\(tag)")!)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let version = object?["version"] as? String,
              LocalACPRuntimeInstaller.isExactSemanticVersion(version),
              object?["bin"] != nil else { throw RuntimeMaintenanceError.unavailable }
        return version
    }

    public static func fetchMetadata(_ url: URL) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(path: "runtime-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try await LocalACPBoundedHTTPSDownloader.download(url, to: file, maximumBytes: 2 * 1_024 * 1_024)
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
    case unavailable, verification, busy, timeout, hermesCheckoutUnverified, hermesCheckoutDirty, hermesUpdateUnsafe
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Latest version information is unavailable. Retry when the update source is reachable."
        case .verification: "Installation finished, but the selected runtime or its required dependencies could not be verified. Retry installation."
        case .timeout: "The runtime command timed out. Retry after checking the installation."
        case .hermesUpdateUnsafe: "Hermes Update requires an in-place Git install with no active Hermes services. Stop its services and retry."
        case .hermesCheckoutUnverified: "The Hermes source checkout could not be verified. Repair its launcher and retry."
        case .hermesCheckoutDirty: "Hermes has local source changes. Commit or stash them, then retry Update."
        case .busy: "Wait for the current runtime operation or conversation to finish."
        }
    }
}
