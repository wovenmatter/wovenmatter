import Foundation
import Testing
@testable import WovenMatterClient

struct RemoteWorkspaceDeploymentTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        for file in ["remote/Dockerfile", "remote/build-image.sh", "remote/entrypoint.sh", "remote/package.json", "remote/src/service.mjs", "remote/security/backports.json", "remote/security/patches/repair.patch", "remote/npm-runtime/package.json", "remote/npm-runtime/package-lock.json", "remote/host/runtime-versions.json", "remote/host/build-bundle.sh", "scripts/remote-host.sh", "harnesses/catalog.json", "default-agent/package.json", "default-agent/package-lock.json", "default-agent/src/agent.mjs", "default-agent/.node-version"] {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.utf8).write(to: url)
        }
        return root
    }

    private func hostFixture() throws -> URL {
        let root = try fixture()
        try Data(#"{"nodeVersion":"26.12.1","playwrightVersion":"1.64.1"}"#.utf8).write(to: root.appending(path: "remote/host/runtime-versions.json"))
        try Data("26.12.1\n".utf8).write(to: root.appending(path: "default-agent/.node-version"))
        try Data(#"{"packages":{"node_modules/playwright-core":{"version":"1.64.1"}}}"#.utf8).write(to: root.appending(path: "default-agent/package-lock.json"))
        // Every host holds a library copy, so a host bundle carries its binary.
        let library = root.appending(path: "remote/host/library/linux-x86_64")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("fixture library".utf8).write(to: library.appending(path: "wovenmatter-library.gz"))
        try Data((String(repeating: "0", count: 64) + "  wovenmatter-library\n").utf8).write(to: library.appending(path: "wovenmatter-library.sha256"))
        return root
    }

    @Test func aHostBundleWithoutTheHostsLibraryIsNeverSent() async throws {
        let root = try hostFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let client = RemoteWorkspaceSSHClient(runner: { _, _, _ in Data() }, scriptLoader: { Data("container-lifecycle".utf8) },
            deploymentRoot: root, streamingRunner: { _, _, _, _ in
                Issue.record("A bundle without the host's library host was sent")
                return Data()
            }, hostScriptLoader: { Data("host-lifecycle".utf8) })
        let configuration = RemoteWorkspaceConfiguration(name: "box", workspaceID: "bots", hostName: "host.invalid", userName: "alice", kind: .host)
        #expect(RemoteHostLibrary.bundled(root: root) == ["x86_64"])
        await #expect(throws: RemoteWorkspaceClientError.self) {
            try await client.deployHost(configuration: configuration, token: "fixture-secret", mode: .botsOnly, architecture: "arm64")
        }
        #expect(throws: Never.self) { try RemoteHostLibrary.require(root: root, architecture: "amd64") }
        #expect(throws: Never.self) { try RemoteHostLibrary.require(root: root, architecture: nil) }
        try FileManager.default.removeItem(at: root.appending(path: "remote/host/library"))
        #expect(RemoteHostLibrary.bundled(root: root).isEmpty)
        do {
            try await client.deployHost(configuration: configuration, token: "fixture-secret", update: true)
            Issue.record("An update without any library host was sent")
        } catch {
            #expect(error.localizedDescription.contains("scripts/build-linux-library.sh"))
        }
        #expect(throws: (any Error).self) { try RemoteHostAdministrationClient.hostBundle(root: root) }
    }

    @Test func hostFingerprintTracksNativeInstallerRuntimeAndService() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let originalContainer = try RemoteWorkspaceDeployment(root: root).fingerprint
        for path in ["remote/host/runtime-versions.json", "remote/host/build-bundle.sh", "scripts/remote-host.sh", "default-agent/.node-version"] {
            let before = try RemoteWorkspaceDeployment(root: root, kind: .host).fingerprint
            try Data("updated host input".utf8).write(to: root.appending(path: path))
            #expect(try RemoteWorkspaceDeployment(root: root, kind: .host).fingerprint != before)
            #expect(try RemoteWorkspaceDeployment(root: root).fingerprint == originalContainer)
        }
    }

    @Test func hostUploadCarriesTokenOnlyOnStdinAndUsesNativeScript() async throws {
        let root = try hostFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = "fixture-secret-never-in-command"
        let client = RemoteWorkspaceSSHClient(runner: { _, _, _ in
            Issue.record("Host deployment should stream its bundle using the streaming runner")
            return Data()
        }, scriptLoader: { Data("container-lifecycle".utf8) }, deploymentRoot: root,
        streamingRunner: { destination, command, input, progress in
            #expect(destination == "alice@host.invalid")
            #expect(command.contains("host-lifecycle"))
            #expect(!command.contains("container-lifecycle") && !command.contains(token))
            #expect(command.contains("'install' 'native-fixture' '7337' 'fullRoot'"))
            let input = try #require(input)
            #expect(input.starts(with: Data((token + "\n").utf8)))
            let archive = Data(input.dropFirst(token.utf8.count + 1))
            #expect(archive.starts(with: [0x1f, 0x8b]))
            let extracted = try RemoteWorkspaceProcess.run(executable: "/usr/bin/tar",
                arguments: ["-xzOf", "-", "manifest.json"], input: archive)
            #expect(extracted.status == 0)
            let manifest = try #require(JSONSerialization.jsonObject(with: extracted.data) as? [String: Any])
            #expect(manifest["dependencyInstallation"] as? String == "target-npm-ci")
            #expect((manifest["files"] as? [String: Any])?["host/remote-host.sh"] != nil)
            progress(Data("WM_PROGRESS selftest\n".utf8))
            return Data(#"{"id":"native-fixture","name":"Native","state":"running","running":true,"startedAt":"","image":"native","memoryBytes":0,"swapBytes":0,"hostPort":7337,"persistentVolume":"/home/alice/.local/share/wovenmatter","capabilities":{"memory":false,"swap":false},"storageKind":"host","hostStorageLow":false,"legacyStorage":false,"kind":"host"}"#.utf8)
        }, hostScriptLoader: { Data("host-lifecycle".utf8) })
        let status = try await client.deployHost(configuration: .init(name: "Native", workspaceID: "native-fixture",
            hostName: "host.invalid", userName: "alice", kind: .host, accessMode: .fullRoot), token: token)
        #expect(status.running && status.kind == .host)
    }

    /// Bots-only hosts use remote-host.sh's roles argument, not a second subcommand.
    @Test func botsOnlyHostUsesTheBotsRole() async throws {
        let root = try hostFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let commands = LockedCommands()
        let status = #"{"id":"bots","name":"box","state":"running","running":true,"startedAt":"","image":"native","memoryBytes":0,"swapBytes":0,"hostPort":7337,"persistentVolume":"/home/alice/.local/share/wovenmatter","capabilities":{"memory":false,"swap":false},"storageKind":"host","hostStorageLow":false,"legacyStorage":false,"kind":"host"}"#
        let client = RemoteWorkspaceSSHClient(runner: { _, command, _ in
            commands.append(command)
            return Data(#"{"ready":true,"runtime":"host","version":"","architecture":"x86_64","capabilities":{"memory":false,"swap":false},"limitations":[],"hostStorageLow":false,"blockingIssues":[]}"#.utf8)
        }, scriptLoader: { Data("container-lifecycle".utf8) }, deploymentRoot: root,
        streamingRunner: { _, command, _, _ in commands.append(command); return Data(status.utf8) },
        hostScriptLoader: { Data("host-lifecycle".utf8) })
        let configuration = RemoteWorkspaceConfiguration(name: "box", workspaceID: "bots", hostName: "host.invalid",
            userName: "alice", kind: .host, accessMode: .user)
        _ = try await client.prepareHost(hostName: "host.invalid", userName: "alice", kind: .host, accessMode: .user,
            roles: RemoteHostInstallMode.botsOnly.roles)
        _ = try await client.deployHost(configuration: configuration, token: "fixture-secret", mode: .botsOnly)
        _ = try await client.deployHost(configuration: configuration, token: "fixture-secret")
        // Adding the workspace later: the real id, on the same server, with the workspace role.
        var studio = configuration; studio.workspaceID = "studio"
        _ = try await client.deployHost(configuration: studio, token: "fixture-secret", mode: .addWorkspace)
        // Bots on a workspace host: an update with the bots role, since roles only grow.
        _ = try await client.deployHost(configuration: studio, update: true, mode: .addBots)
        let sent = commands.values
        #expect(sent.count == 5)
        #expect(sent[4].contains("'update' 'studio' '") && sent[4].hasSuffix(" 'bots'"))
        #expect(sent[0].contains("'prepare' 'AUTHORIZED' 'user' 'bots'"))
        #expect(sent[1].contains("'install' 'bots' '") && sent[1].hasSuffix(" 'bots'"))
        #expect(!sent[2].hasSuffix(" 'bots'"), "a workspace install keeps the host's recorded roles")
        #expect(sent[3].contains("'install' 'studio' '") && sent[3].hasSuffix(" 'workspace'"))
        #expect(RemoteHostInstallMode.botsOnlyWorkspaceID == configuration.workspaceID)
    }

    @Test func hostBundlesRecordTheReleaseVersionOutsideTheFingerprint() throws {
        let root = try hostFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let deployment = try RemoteWorkspaceDeployment(root: root, kind: .host)
        func manifest(_ version: String?) throws -> [String: Any] {
            let archive = try RemoteHostBundle.archive(root: root, deployment: deployment, releaseVersion: version)
            let extracted = try RemoteWorkspaceProcess.run(executable: "/usr/bin/tar", arguments: ["-xzOf", "-", "manifest.json"], input: archive)
            return try #require(JSONSerialization.jsonObject(with: extracted.data) as? [String: Any])
        }
        #expect(try manifest("1.4.0")["releaseVersion"] as? String == "1.4.0")
        #expect(try manifest("1.4.0")["fingerprint"] as? String == deployment.fingerprint)
        // Free text never reaches the host's environment.
        #expect(try manifest("1.4\nX=1")["releaseVersion"] == nil)
        #expect(try manifest(nil)["releaseVersion"] == nil)
    }

    @Test func nativeHostArchiveIsDeterministicAndRejectsSourceDrift() throws {
        let root = try hostFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let deployment = try RemoteWorkspaceDeployment(root: root, kind: .host)
        let first = try RemoteHostBundle.archive(root: root, deployment: deployment)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: root.appending(path: "remote/src/service.mjs").path)
        #expect(try RemoteHostBundle.archive(root: root, deployment: deployment) == first)
        try Data("source changed after fingerprinting".utf8).write(to: root.appending(path: "remote/src/service.mjs"))
        #expect(throws: RemoteWorkspaceClientError.self) { try RemoteHostBundle.archive(root: root, deployment: deployment) }
    }

    @Test func hostArchiveRejectsLinksAndMismatchedRuntimePins() throws {
        let root = try hostFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appending(path: "remote/src/linked.mjs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let linked = try RemoteWorkspaceDeployment(root: root, kind: .host)
        #expect(throws: RemoteWorkspaceClientError.self) { try RemoteHostBundle.archive(root: root, deployment: linked) }
        try FileManager.default.removeItem(at: link)
        try Data("26.12.2\n".utf8).write(to: root.appending(path: "default-agent/.node-version"))
        let mismatched = try RemoteWorkspaceDeployment(root: root, kind: .host)
        #expect(throws: RemoteWorkspaceClientError.self) { try RemoteHostBundle.archive(root: root, deployment: mismatched) }
    }

    /// scripts/build-linux-library.sh writes remote/host/library/linux-<arch>/;
    /// installs and updates ship whatever binaries are present, as executables.
    @Test func builtLinuxLibraryBinariesShipAsHostExecutables() throws {
        let root = try hostFixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appending(path: "remote/host/library"))
        let without = try RemoteWorkspaceDeployment(root: root, kind: .host)
        #expect(!without.sourceFiles.contains { $0.hasPrefix("remote/host/library/") })
        let binary = root.appending(path: "remote/host/library/linux-x86_64/wovenmatter-library")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\u{7f}ELF fixture".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let deployment = try RemoteWorkspaceDeployment(root: root, kind: .host)
        #expect(deployment.fingerprint != without.fingerprint)
        let archive = try RemoteHostBundle.archive(root: root, deployment: deployment)
        let listing = try RemoteWorkspaceProcess.run(executable: "/usr/bin/tar", arguments: ["-tvzf", "-"], input: archive)
        let line = try #require(String(decoding: listing.data, as: UTF8.self).split(separator: "\n")
            .first { $0.hasSuffix("host/library/linux-x86_64/wovenmatter-library") })
        #expect(line.hasPrefix("-rwx------"))
    }

    @Test func hostNpmSecurityGraphIsBundledAndBoundToTheSourceIdentity() throws {
        let root = try hostFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let deployment = try RemoteWorkspaceDeployment(root: root, kind: .host)
        let archive = try RemoteHostBundle.archive(root: root, deployment: deployment)
        let extracted = try RemoteWorkspaceProcess.run(executable: "/usr/bin/tar",
            arguments: ["-xzOf", "-", "manifest.json"], input: archive)
        #expect(extracted.status == 0)
        let manifest = try #require(JSONSerialization.jsonObject(with: extracted.data) as? [String: Any])
        let files = try #require(manifest["files"] as? [String: [String: Any]])
        for name in ["package.json", "package-lock.json"] {
            let canonical = "remote/npm-runtime/" + name
            #expect(files["npm-runtime/" + name]?["sourcePath"] as? String == canonical)
            #expect(deployment.sourceFiles.contains(canonical))
            let contents = try RemoteWorkspaceProcess.run(executable: "/usr/bin/tar",
                arguments: ["-xzOf", "-", "npm-runtime/" + name], input: archive)
            #expect(contents.status == 0)
            #expect(contents.data == Data(canonical.utf8))
        }
        try Data("changed pinned npm security graph".utf8).write(to: root.appending(path: "remote/npm-runtime/package-lock.json"))
        #expect(try RemoteWorkspaceDeployment(root: root, kind: .host).fingerprint != deployment.fingerprint)
        #expect(throws: RemoteWorkspaceClientError.self) { try RemoteHostBundle.archive(root: root, deployment: deployment) }
    }

    @Test func progressStreamsBeforeExitAndFiltersRawOutput() throws {
        let state = ProgressState()
        let decoder = RemoteWorkspaceBuildProgress { state.append($0) }
        decoder.receive(Data("WM_PROGRESS buil".utf8))
        decoder.receive(Data("ding\nWM_PROGRESS building\nprivate installer output\n".utf8))
        #expect(state.messages == ["Building the workspace image…"])
        let acknowledgement = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: acknowledgement) }
        let result = try RemoteWorkspaceProcess.run(executable: "/bin/sh",
            arguments: ["-c", #"echo 'WM_PROGRESS ready' >&2; while [ ! -e "$1" ]; do sleep 0.02; done; echo done"#, "fixture", acknowledgement.path],
            timeLimit: 10, onProcessStarted: { state.pid = $0 }, onStandardError: { data in
                decoder.receive(data)
                #expect(kill(state.pid, 0) == 0)
                #expect(FileManager.default.createFile(atPath: acknowledgement.path, contents: Data()))
            })
        #expect(result.status == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "done")
        #expect(state.messages.last == "Workspace image ready.")
    }
}

private final class ProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var pid: pid_t = 0
    var messages: [String] { lock.withLock { values } }
    func append(_ value: String) { lock.withLock { values.append(value) } }
}

private final class LockedCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    var values: [String] { lock.withLock { commands } }
    func append(_ value: String) { lock.withLock { commands.append(value) } }
}
