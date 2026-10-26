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
        return root
    }

    @Test func fingerprintTracksContentAndPermissionsButNotTimestamps() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try RemoteWorkspaceDeployment(root: root).fingerprint
        let source = root.appending(path: "remote/src/service.mjs")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: source.path)
        #expect(try RemoteWorkspaceDeployment(root: root).fingerprint == original)
        try Data("changed service".utf8).write(to: source)
        let changed = try RemoteWorkspaceDeployment(root: root).fingerprint
        #expect(changed != original)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        #expect(try RemoteWorkspaceDeployment(root: root).fingerprint != changed)
        let beforeLock = try RemoteWorkspaceDeployment(root: root).fingerprint
        try Data("changed dependencies".utf8).write(to: root.appending(path: "default-agent/package-lock.json"))
        #expect(try RemoteWorkspaceDeployment(root: root).fingerprint != beforeLock)
    }

    @Test func securityRepairsAndNpmOverlayInvalidateCachedImage() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for path in ["remote/security/backports.json", "remote/security/patches/repair.patch", "remote/npm-runtime/package-lock.json"] {
            let before = try RemoteWorkspaceDeployment(root: root).fingerprint
            try Data("updated security input".utf8).write(to: root.appending(path: path))
            #expect(try RemoteWorkspaceDeployment(root: root).fingerprint != before)
        }
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

    @Test func reuseDoesNotUploadOrBuildAndUsesImmutableIdentity() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let image = "sha256:" + String(repeating: "a", count: 64)
        let client = RemoteWorkspaceSSHClient(runner: { _, command, input in
            #expect(command.contains(" -- inspect "))
            #expect(input == nil)
            return Data((image + "\n").utf8)
        }, scriptLoader: { Data() }, deploymentRoot: root, streamingRunner: { _, _, _, _ in
            Issue.record("A reusable image must not build or upload an archive")
            return Data()
        })
        #expect(try await client.deployService(hostName: "host", userName: nil) == image)
    }

    @Test func changedImageBuildsAndExplicitUpdateSkipsReuse() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let image = "sha256:" + String(repeating: "b", count: 64)
        for force in [false, true] {
            let client = RemoteWorkspaceSSHClient(runner: { _, command, input in
                #expect(!force)
                #expect(command.contains(" -- inspect "))
                #expect(input == nil)
                return Data("build\n".utf8)
            }, scriptLoader: { Data() }, deploymentRoot: root, streamingRunner: { _, command, input, progress in
                #expect(command.contains(" -- build "))
                #expect(command.hasSuffix(force ? " true" : " false"))
                #expect((input?.count ?? 0) > 0)
                progress(Data("WM_PROGRESS building\nWM_PROGRESS ready\n".utf8))
                return Data(image.utf8)
            })
            #expect(try await client.deployService(hostName: "host", userName: nil, forceRefresh: force) == image)
        }
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
        #expect(RemoteWorkspaceDeployment.imageID(Data("arbitrary output".utf8)) == nil)
    }
}

private final class ProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var pid: pid_t = 0
    var messages: [String] { lock.withLock { values } }
    func append(_ value: String) { lock.withLock { values.append(value) } }
}
