import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct RuntimeMaintenanceTests {
    @Test func ordersVersionsWithoutTreatingUnknownAsCurrent() {
        #expect(RuntimeMaintenance.version("codex-acp 1.7.0", precedes: "1.11.0"))
        #expect(!RuntimeMaintenance.version("1.11.0", precedes: "1.7.0"))
        #expect(RuntimeMaintenance.version("0.0.0-beta-19000", precedes: "0.0.0-beta-19278"))
        #expect(RuntimeMaintenance.version("1.2.3-beta.9", precedes: "1.2.3"))
        #expect(!RuntimeMaintenance.version("unknown", precedes: "1.11.0"))
        #expect(!RuntimeMaintenance.version("2026.09.10-abc", precedes: "2026.09.10-def"))
        #expect(RuntimeMaintenance.version("2026.09.09-abc", precedes: "2026.09.10-def"))
    }

    @Test func registryRejectsPlaceholderAndRanges() async throws {
        let version = try await RuntimeMaintenance.registryVersion("@example/cli", fetch: { url in
            #expect(url.absoluteString == "https://registry.npmjs.org/@example%2fcli/latest")
            return Data(#"{"version":"1.11.0","bin":{"cli":"bin.js"}}"#.utf8)
        })
        #expect(version == "1.11.0")
        await #expect(throws: (any Error).self) {
            try await RuntimeMaintenance.registryVersion("@opencode/cli", fetch: { _ in
                Data(#"{"version":"0.0.0-reserved"}"#.utf8)
            })
        }
    }

    @Test func codexInventoryFindsTheEngineBesideTheLaunchedAdapter() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = root.appending(path: "lib/node_modules/@agentclientprotocol/codex-acp")
        let engine = adapter.appending(path: "node_modules/@openai/codex")
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: adapter.appending(path: "dist"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine.appending(path: "bin"), withIntermediateDirectories: true)
        try Data(#"{"name":"@agentclientprotocol/codex-acp","version":"1.11.0"}"#.utf8).write(to: adapter.appending(path: "package.json"))
        try Data(#"{"name":"@openai/codex","version":"0.148.0"}"#.utf8).write(to: engine.appending(path: "package.json"))
        try Data("#!/bin/sh\necho 0.148.0\n".utf8).write(to: engine.appending(path: "bin/codex.js"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.appending(path: "bin/codex.js").path)
        let script = adapter.appending(path: "dist/index.js")
        try Data("#!/bin/sh\necho 1.11.0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "bin/codex-acp"), withDestinationURL: script)
        let cli = root.appending(path: "bin/codex")
        try Data("#!/bin/sh\necho 0.154.0\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let resolver = LocalACPRuntimeResolver(executableSearchDirectories: [root.appending(path: "bin").path])
        let inventory = await RuntimeMaintenance.inspect(.codex, checkLatest: true, resolver: resolver,
            fetch: { _ in Data(#"{"version":"1.12.0","bin":{"cli":"bin.js"}}"#.utf8) })
        #expect(inventory.isInstalled)
        #expect(inventory.components[1].installed == "0.148.0")
        #expect(inventory.components[2].installed == "0.154.0")
        #expect(inventory.outdated)
        try FileManager.default.removeItem(at: engine.appending(path: "bin/codex.js"))
        let broken = await RuntimeMaintenance.inspect(.codex, checkLatest: false, resolver: resolver)
        #expect(!broken.isInstalled)
        #expect(broken.components[1].present == false)
        let diagnostic = RuntimeMaintenance.diagnostic(inventory: broken, kind: .codex, attempts: 2, failure: "Verification failed")
        #expect(diagnostic.contains("0.148.0"))
        #expect(diagnostic.contains("0.154.0"))
        #expect(!diagnostic.contains(root.path))
    }

    @Test func claudeSDKRequiresItsDeclaredNativePlatformDependency() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let name = "@anthropic-ai/claude-agent-sdk-darwin-arm64"
        #else
        let name = "@anthropic-ai/claude-agent-sdk-darwin-x64"
        #endif
        try JSONSerialization.data(withJSONObject: ["name": "@anthropic-ai/claude-agent-sdk", "optionalDependencies": [name: "0.3.257"]]).write(to: root.appending(path: "package.json"))
        // A leftover legacy file must not hide a missing current native engine.
        try Data().write(to: root.appending(path: "cli.js"))
        #expect(RuntimeMaintenance.bundledEngine(in: root, kind: .claudeCode) == nil)
        let native = root.appending(path: "node_modules/" + name)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["name": name, "version": "0.3.257"]).write(to: native.appending(path: "package.json"))
        #expect(RuntimeMaintenance.bundledEngine(in: root, kind: .claudeCode) == native.appending(path: "claude"))
    }

    @Test func hermesCheckDoesNotTreatFailedOrAmbiguousChecksAsCurrent() {
        #expect(RuntimeMaintenance.hermesCheck("✓ Already up to date.") == false)
        #expect(RuntimeMaintenance.hermesCheck("⚕ Update available: 4 commits behind origin/main.") == true)
        #expect(RuntimeMaintenance.hermesCheck("Fetch failed") == nil)
        #expect(RuntimeMaintenance.hermesCheck("Already up to date.\nUpdate available: 4 commits") == nil)
    }

    @Test func hermesOfficialUpdateRequiresCleanIdleCheckoutAndVerifiesCurrentACP() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "venv/bin"), withIntermediateDirectories: true)
        try Data("[project]\nname = \"hermes-agent\"\n".utf8).write(to: root.appending(path: "pyproject.toml"))
        let python = root.appending(path: "venv/bin/python")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        let launcher = root.appending(path: "launcher")
        try Data("#!/bin/bash\nexec \"\(python.path)\" \"\(root.path)/hermes\" \"$@\"\n".utf8).write(to: launcher)
        var dirty = true
        var active = false
        var stale = false
        var updates = 0
        let run: (URL, [String], TimeInterval) throws -> LocalACPProcessResult = { _, args, timeout in
            let output: String
            if args.contains("rev-parse") { output = root.path }
            else if args.contains("status") { output = dirty ? " M user.py" : "" }
            else if args == ["update", "--plan"] { output = "Update plan:\n  Install: git (v0.21.2)\n  " + (active ? "Running services to restart (1):" : "Running Hermes services: none detected — code swap only.") }
            else if args == ["update", "--help"] { output = "--yes --check --plan" }
            else if args == ["update", "--yes"] { #expect(timeout == 600); updates += 1; output = "Update complete" }
            else if args == ["update", "--check"] { output = stale ? "Update available: 1 commit" : "Already up to date." }
            else if args == ["acp", "--version"] { output = "0.21.2" }
            else { output = "" }
            return LocalACPProcessResult(terminationStatus: 0, stdout: output)
        }
        #expect(throws: (any Error).self) { try RuntimeMaintenance.updateHermes(executable: launcher, run: run) }
        #expect(updates == 0)
        dirty = false; active = true
        #expect(throws: (any Error).self) { try RuntimeMaintenance.updateHermes(executable: launcher, run: run) }
        #expect(updates == 0)
        active = false; stale = true
        #expect(throws: (any Error).self) { try RuntimeMaintenance.updateHermes(executable: launcher, run: run) }
        stale = false
        try RuntimeMaintenance.updateHermes(executable: launcher, run: run)
        #expect(updates == 2)
        #expect(RuntimeMaintenance.hermesPython(launcher) == python)
        #expect(!RuntimeMaintenance.hermesPlanAllowsUpdate("Update plan:\nInstall: docker\nRunning Hermes services: none detected — code swap only."))
        #expect(RuntimeMaintenance.hermesHasActiveProcesses("123 /checkout/venv/bin/python -m acp_adapter.entry"))
    }

    @Test func cursorReleaseUsesTheVersionSegment() async {
        let version = await RuntimeMaintenance.latestVersion(kind: .cursor, package: nil, fetch: { _ in
            Data(#"DOWNLOAD_URL="https://downloads.cursor.com/lab/2026.09.10-fd3934a/${OS}/${ARCH}/agent-cli-package.tar.gz""#.utf8)
        })
        #expect(version == "2026.09.10-fd3934a")
    }

    @Test func failedVerificationPreservesThePreviousLauncherAndDependencyTree() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let npm = root.appending(path: "npm")
        try Data("""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--prefix' ]; then shift; prefix="$1"; fi
          shift
        done
        mkdir -p "$prefix/bin"
        printf '#!/bin/sh\\necho 1.2.3\\n' > "$prefix/bin/fixture"
        chmod 700 "$prefix/bin/fixture"
        """.utf8).write(to: npm)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: npm.path)
        let prefix = root.appending(path: "managed")
        let installer = LocalACPRuntimeInstaller(installPrefix: prefix, npmExecutableURL: npm)
        func definition(_ version: String) -> LocalACPRuntimeDefinition {
            LocalACPRuntimeDefinition(runtimeKind: .pi, displayName: "Fixture", commandName: "fixture",
                arguments: [], underlyingCLIName: nil, cliInstallerSource: nil, cliInstallerInterpreter: nil,
                adapterPackage: "@example/fixture", minimumAdapterVersion: version, adapterDescription: "Fixture")
        }
        let launcher = try await installer.install(definition("1.2.3"), component: .adapter)
        let firstTree = launcher.resolvingSymlinksInPath()
        await #expect(throws: (any Error).self) {
            try await installer.install(definition("1.2.4"), component: .adapter)
        }
        #expect(launcher.resolvingSymlinksInPath() == firstTree)
        #expect(FileManager.default.isExecutableFile(atPath: firstTree.path))
        let installed = try FileManager.default.contentsOfDirectory(at: prefix.appending(path: "Installations"), includingPropertiesForKeys: nil)
        #expect(installed.count == 1)
    }

    @Test func openCodeInventorySeparatesPinnedCLIFromRegisteredServiceWithoutCopyingCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "opencode2")
        try Data("#!/bin/sh\necho \(OpenCodeConnection.supportedVersion)\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let registration = root.appending(path: "service.json")
        try JSONSerialization.data(withJSONObject: ["url": "http://127.0.0.1:12345", "pid": 12345, "password": "fixture-secret", "version": "0.0.0-beta-19000"]).write(to: registration)
        let inventory = await RuntimeMaintenance.inspect(.opencode, checkLatest: false,
            resolver: LocalACPRuntimeResolver(executableSearchDirectories: [root.path]),
            selectedOpenCode: cli, openCodeRegistration: registration)
        #expect(inventory.isInstalled)
        #expect(inventory.components[0].installed == OpenCodeConnection.supportedVersion)
        #expect(inventory.components[1].installed == "0.0.0-beta-19000")
        #expect(!inventory.components[1].required)
        let prompt = RuntimeMaintenance.diagnostic(inventory: inventory, kind: .opencode, attempts: 2, failure: "Verification failed")
        #expect(!prompt.contains("fixture-secret"))
        #expect(!prompt.contains("12345"))
        #expect(!prompt.contains(root.path))
    }

    @Test func timesOutWithoutLeavingAChildWriter() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appending(path: "late-write")
        #expect(throws: (any Error).self) {
            try LocalACPProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(sleep 1; touch '\(marker.path)') & wait"], timeout: 0.05)
        }
        Thread.sleep(forTimeInterval: 1.1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
