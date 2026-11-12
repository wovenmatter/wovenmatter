import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

private final class HostInspectionFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var commands: [String] = []

    func setReady(_ value: Bool) { lock.withLock { ready = value } }
    var calls: [String] { lock.withLock { commands } }

    func run(destination: String, command: String) throws -> Data {
        try lock.withLock {
            commands.append(command)
            if command.contains("'status'") {
                return Data(#"{"id":"fixture","name":"Fixture","state":"exited","running":false,"startedAt":"","image":"fixture","memoryBytes":0,"swapBytes":0,"hostPort":7337,"persistentVolume":"fixture","capabilities":{"memory":false,"swap":false},"storageKind":"fixture","hostStorageLow":false,"legacyStorage":false}"#.utf8)
            }
            if command.contains("'prepare'") { ready = true }
            let value: [String: Any] = [
                "ready": ready, "runtime": "docker", "version": ready ? "29.9.2" : "",
                "architecture": "x86_64", "capabilities": ["memory": ready, "swap": ready],
                "limitations": [], "hostStorageLow": false,
                "canPrepare": !ready, "preparationRequired": !ready,
                "preparationActions": ready ? [] : ["Start Docker."],
                "blockingIssues": []
            ]
            return try JSONSerialization.data(withJSONObject: value)
        }
    }
    var client: RemoteWorkspaceSSHClient {
        RemoteWorkspaceSSHClient(runner: { [self] destination, command, _ in
            try run(destination: destination, command: command)
        }, scriptLoader: { Data("fixture".utf8) })
    }
}

@MainActor struct RemoteWorkspaceHostTests {
    @Test func fullRootWorkspaceOverridesOldChatDefaultsAndCalendarPermissionsForEveryFolder() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        var host = fixture.remote
        host.kind = .host; host.accessMode = .fullRoot
        host.dataRoot = "/home/trey/.local/share/wovenmatter"
        host.workspaceRoot = "/home/trey/.local/share/wovenmatter/workspace"
        let status = try #require(fixture.model.remoteWorkspaces.statuses[host.id])
        let harnesses = try #require(fixture.model.remoteWorkspaces.harnesses[host.id])
        let maintenance = try #require(fixture.model.remoteWorkspaces.runtimeMaintenance[host.id])
        fixture.model.remoteWorkspaces.configureFacadeFixture(host, status: status, harnesses: harnesses, maintenance: maintenance)
        let scope = ApplicationModel.remoteDatabaseSourceID(host.id)
        fixture.model.sessionSelectionPreferences.saveDefaults(.init(permission: "read-only"), harness: "codex", workspace: scope)
        let target = RemoteHarnessChatTarget(configuration: host, harness: try #require(harnesses.first { $0.id == .codex }))
        let folderless = try #require(await fixture.model.createRemoteACPSession(target: target))
        #expect(try await fixture.database.localACPSession(conversationID: folderless).permission == "agent-full-access")
        #expect(await fixture.recorder.configurations.last?.selections.permission == "agent-full-access")
        #expect(try fixture.model.defaultToolWorkingDirectory(workspaceID: host.id) == host.workspaceRoot)
        let calendar = fixture.model.calendarTaskDefaults(runtime: .codex, workspaceID: host.id)
        #expect(calendar.configuration.permission == "agent-full-access")
        #expect(calendar.configuration.usesProductPermissionDefault == false)

        // A previously captured restrictive selection also yields to the
        // workspace policy when an existing chat is recovered.
        fixture.model.sessionSelectionPreferences.stageCalendarSelections(id: folderless, harness: "codex", workspace: scope,
            selections: .init(permission: "read-only"), usesProductPermissionDefault: true)
        try await fixture.model.applyStagedSessionSelections(conversationID: folderless)
        #expect(await fixture.recorder.configurations.last?.selections.permission == "agent-full-access")

        let external = "/home/trey/projects/existing-repository"
        let folderID = try await fixture.store.createFolder(name: "Linked repository", location: .init(workspaceID: scope, rootPath: external, managed: false))
        let linked = try #require(await fixture.model.createRemoteACPSession(target: target, folderID: folderID))
        #expect(try await fixture.database.localACPSession(conversationID: linked).permission == "agent-full-access")
        #expect(await fixture.recorder.configurations.last?.directory == external)
        #expect(try await fixture.model.folderWorkingDirectory(folderID: folderID, workspaceID: host.id).path == external)

        host.accessMode = .user
        fixture.model.remoteWorkspaces.configureFacadeFixture(host, status: status, harnesses: harnesses, maintenance: maintenance)
        #expect(fixture.model.calendarTaskDefaults(runtime: .codex, workspaceID: host.id).configuration.permission == "read-only")
    }

    private func makeModel(_ fixture: HostInspectionFixture) -> RemoteWorkspacesModel {
        let defaults = UserDefaults(suiteName: "host-setup-test-" + UUID().uuidString)!
        return RemoteWorkspacesModel(defaults: defaults, backendProjection: false, sshClient: fixture.client)
    }

    private func settled(_ model: RemoteWorkspacesModel) async throws {
        let idle = try await pollUntil(attempts: 300, interval: .milliseconds(10)) { !model.isCheckingHost && !model.isCreating }
        if !idle { Issue.record("Host operation did not settle") }
    }

    @Test func nativeReadinessIsBoundToWorkspaceKindAndAccessLevel() async throws {
        let fixture = HostInspectionFixture(); fixture.setReady(true)
        let model = makeModel(fixture)
        model.checkHost(hostName: "native.invalid", userName: "trey", kind: .host, accessMode: .fullRoot)
        try await settled(model)
        #expect(model.preflight(hostName: "native.invalid", userName: "trey", kind: .host, accessMode: .fullRoot)?.ready == true)
        #expect(model.preflight(hostName: "native.invalid", userName: "trey", kind: .host, accessMode: .user) == nil)
        #expect(model.preflight(hostName: "native.invalid", userName: "trey", kind: .container, accessMode: .fullRoot) == nil)
        #expect(fixture.calls.count == 1)
        #expect(fixture.calls.first?.contains("'fullRoot'") == true)
    }

    @Test func aWorkspaceAddedToABotsOnlyHostReusesItsServerRecord() async throws {
        let placeholder = RemoteWorkspaceConfiguration(name: "box", workspaceID: RemoteHostInstallMode.botsOnlyWorkspaceID,
            hostName: "native.invalid", userName: "trey", remotePort: 7400, kind: .host, accessMode: .user)
        let converted = try RemoteWorkspacesModel.addingWorkspace(to: placeholder, name: "Studio", workspaceID: "studio", accessMode: .user)
        // Same record (id, so the same Keychain token), host, port and access level; the real name and id.
        #expect(converted.id == placeholder.id && converted.remotePort == 7400 && converted.accessMode == .user)
        #expect(converted.name == "Studio" && converted.workspaceID == "studio")
        #expect(throws: (any Error).self) {
            try RemoteWorkspacesModel.addingWorkspace(to: placeholder, name: "Studio", workspaceID: "studio", accessMode: .fullRoot)
        }
        #expect(throws: (any Error).self) {
            try RemoteWorkspacesModel.addingWorkspace(to: placeholder, name: "Studio", workspaceID: "bots", accessMode: .user)
        }
        #expect(throws: (any Error).self) {
            try RemoteWorkspacesModel.addingWorkspace(to: converted, name: "Other", workspaceID: "other", accessMode: .user)
        }

        // Through the create flow: the placeholder is found instead of refusing a second host workspace.
        let fixture = HostInspectionFixture(); fixture.setReady(true)
        let suite = "native-host-bots-placeholder-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([placeholder]), forKey: "wovenmatter.remote-workspaces.v1")
        let model = RemoteWorkspacesModel(defaults: defaults, backendProjection: false, sshClient: fixture.client)
        model.checkHost(hostName: placeholder.hostName, userName: "trey", kind: .host, accessMode: .fullRoot)
        try await settled(model)
        model.create(name: "Studio", workspaceID: "studio", hostName: placeholder.hostName, userName: "trey",
            port: 7448, kind: .host, accessMode: .fullRoot)
        #expect(model.errorMessage?.contains("same access level") == true)
        #expect(!model.isCreating && model.workspaces == [placeholder])
    }

    @Test func nativeWorkspaceCannotBeConfiguredTwiceForTheSameHostAndUser() async throws {
        let fixture = HostInspectionFixture(); fixture.setReady(true)
        let suite = "native-host-duplicate-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = RemoteWorkspaceConfiguration(name: "Native", workspaceID: "native", hostName: "native.invalid", userName: "trey", kind: .host, accessMode: .fullRoot)
        defaults.set(try JSONEncoder().encode([existing]), forKey: "wovenmatter.remote-workspaces.v1")
        let model = RemoteWorkspacesModel(defaults: defaults, backendProjection: false, sshClient: fixture.client)
        model.checkHost(hostName: existing.hostName, userName: "trey", kind: .host, accessMode: .fullRoot)
        try await settled(model)
        model.create(name: "Another", workspaceID: "another", hostName: existing.hostName, userName: "trey",
            port: 7448, kind: .host, accessMode: .fullRoot)
        #expect(model.errorMessage?.contains("already configured for this host and user") == true)
        #expect(!model.isCreating && model.workspaces == [existing])
        #expect(fixture.calls.count == 1)
    }

    @Test func hostPreparationRequiresReviewAndNeverCreatesAWorkspace() async throws {
        let fixture = HostInspectionFixture()
        let model = makeModel(fixture)
        let originalWorkspaces = model.workspaces
        model.create(name: "Fixture", workspaceID: "fixture", hostName: "fixture.invalid",
                     userName: "", port: 7337)
        #expect(model.errorMessage?.contains("inspect a ready host") == true)
        model.prepareHost(hostName: "fixture.invalid", userName: "")
        #expect(model.pendingHostPreparation == nil)
        #expect(fixture.calls.isEmpty)
        model.checkHost(hostName: "fixture.invalid", userName: "")
        try await settled(model)
        let service = BackendRemoteWorkspaceService(model: model)
        let command = BackendRemoteWorkspaceCommand.prepareHost(hostName: "fixture.invalid", userName: "")
        let decoded = try JSONDecoder().decode(BackendRemoteWorkspaceCommand.self, from: JSONEncoder().encode(command))
        _ = try await service.execute(decoded)
        #expect(model.pendingHostPreparation?.hostName == "fixture.invalid")
        #expect(fixture.calls.count == 1)
        model.authorizeHostPreparation()
        try await settled(model)
        #expect(model.preflight(hostName: "fixture.invalid", userName: "")?.ready == true)
        #expect(fixture.calls.count == 4)
        #expect(fixture.calls.filter { $0.contains("'prepare'") }.count == 1)
        #expect(!fixture.calls.contains { $0.contains("'create'") })
        #expect(model.workspaces == originalWorkspaces)
        #expect(model.pendingHostPreparation == nil)
    }

    @Test func deprecatedContainersNeverReconnectOrRunLifecycleCommands() async throws {
        let fixture = HostInspectionFixture()
        let suite = "deprecated-remote-container-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = RemoteWorkspaceConfiguration(name: "Legacy", workspaceID: "legacy", hostName: "fixture.invalid")
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "wovenmatter.remote-workspaces.v1")
        let model = RemoteWorkspacesModel(defaults: defaults, backendProjection: false, sshClient: fixture.client)
        #expect(model.workspaces.isEmpty)
        model.refreshRuntimeMaintenanceAtStartup()
        model.reconnect(legacy)
        model.lifecycle(.start, configuration: legacy)
        model.updateContainer(legacy)
        model.delete(legacy, removePersistentData: true)
        model.checkHost(hostName: legacy.hostName, userName: "", kind: .container)
        model.prepareHost(hostName: legacy.hostName, userName: "", kind: .container)
        model.create(name: "Legacy", workspaceID: "legacy", hostName: legacy.hostName, userName: "",
            port: 7337, kind: .container)
        #expect(model.errorMessage?.contains("deprecated") == true)
        #expect(fixture.calls.isEmpty)
        #expect(!model.isCreating)
    }

    @Test func startupChecksConnectionWithoutStartingStoppedWorkspace() async throws {
        let fixture = HostInspectionFixture()
        let suite = "remote-startup-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = RemoteWorkspaceConfiguration(name: "Fixture", workspaceID: "fixture", hostName: "fixture.invalid", kind: .host)
        defaults.set(try JSONEncoder().encode([workspace]), forKey: "wovenmatter.remote-workspaces.v1")
        let model = RemoteWorkspacesModel(defaults: defaults, backendProjection: false, sshClient: fixture.client)
        model.refreshRuntimeMaintenanceAtStartup()
        _ = try await pollUntil(attempts: 300, interval: .milliseconds(10)) { !model.busyWorkspaceIDs.contains(workspace.id) }
        #expect(model.statuses[workspace.id]?.running == false)
        #expect(model.errorMessage == nil)
        #expect(fixture.calls.count == 1)
        #expect(fixture.calls.first?.contains("'status'") == true)
        #expect(model.harnesses.isEmpty)
    }

    /// A Linux host that is a workspace first gets bots from the app: the server's own
    /// `bots.state` decides, and an update with the `bots` role turns them on.
    @Test func installingBotsOnAWorkspaceHostAddsTheBotsRoleToItsServer() async throws {
        let root = try BotsHostFixture.deploymentRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "native-host-add-bots-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = RemoteWorkspaceConfiguration(name: "Studio", workspaceID: "studio", hostName: "studio.invalid", userName: "trey",
                                                    remotePort: 7400, kind: .host, accessMode: .fullRoot)
        defaults.set(try JSONEncoder().encode([existing]), forKey: "wovenmatter.remote-workspaces.v1")
        let host = BotsHostFixture(root: root, installation: #"{"id":"studio","port":7400,"accessMode":"fullRoot","roles":{"workspace":true,"bots":false}}"#)
        let model = RemoteWorkspacesModel(defaults: defaults, backendProjection: false, sshClient: host.client)
        var steps: [String] = []
        let result = try await model.installBotsHost(hostName: "studio.invalid", userName: "trey") { steps.append($0) }
        #expect(result?.id == existing.id && model.workspaces.count == 1)
        let sent = host.commands
        #expect(sent.count == 4)
        #expect(sent[0].contains("'inspect' 'fullRoot'"))
        #expect(sent[1].contains("'inspect' 'fullRoot' 'workspace,bots'"), "preparation covers the roles it will have")
        #expect(sent[2].contains("'prepare' 'AUTHORIZED' 'fullRoot' 'workspace,bots'"))
        #expect(sent[3].contains("'update' 'studio' '7400' 'fullRoot' '") && sent[3].hasSuffix(" 'bots'"), "roles only grow: the workspace stays")
        #expect(host.tokens == [""], "the server keeps its own bearer")
        #expect(steps.first == "Checking studio.invalid…" && steps.contains("Preparing studio.invalid…"))

        // Once the server says bots are ready, installing again changes nothing.
        host.botsState = "bots_ready"
        #expect(try await model.installBotsHost(hostName: "studio.invalid", userName: "trey")?.id == existing.id)
        #expect(host.commands.count == 5)

        // A server another Mac added: the same update, with no record kept here.
        let other = BotsHostFixture(root: root, installation: #"{"id":"lab","port":7500,"accessMode":"user","roles":{"workspace":true,"bots":false}}"#)
        let unrelated = RemoteWorkspacesModel(defaults: try #require(UserDefaults(suiteName: suite + "-other")), backendProjection: false, sshClient: other.client)
        defer { UserDefaults().removePersistentDomain(forName: suite + "-other") }
        #expect(try await unrelated.installBotsHost(hostName: "lab.invalid", userName: nil) == nil)
        #expect(other.commands.last?.contains("'update' 'lab' '7500' 'user' '") == true && unrelated.workspaces.isEmpty)

        // A record whose server is gone is reported, not reinstalled over.
        let gone = BotsHostFixture(root: root, installation: nil)
        let stale = RemoteWorkspacesModel(defaults: defaults, backendProjection: false, sshClient: gone.client)
        await #expect(throws: (any Error).self) { try await stale.installBotsHost(hostName: "studio.invalid", userName: "trey") }
        #expect(gone.commands.count == 1)
    }

}

/// A Linux peer for `remote-host.sh` commands, with a deployment root that carries the
/// library host for x86_64.
private final class BotsHostFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    private var streamed: [String] = []
    private var state = "server_without_bots"
    let root: URL
    let installation: String?

    init(root: URL, installation: String?) { self.root = root; self.installation = installation }

    var commands: [String] { lock.withLock { sent } }
    var tokens: [String] { lock.withLock { streamed } }
    var botsState: String { get { lock.withLock { state } } set { lock.withLock { state = newValue } } }

    static func deploymentRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "bots-host-root-" + UUID().uuidString)
        let files: [String: String] = [
            "remote/package.json": "{}", "remote/src/server.mjs": "fixture", "remote/npm-runtime/package.json": "{}",
            "remote/npm-runtime/package-lock.json": "{}", "remote/host/build-bundle.sh": "fixture",
            "remote/host/runtime-versions.json": #"{"nodeVersion":"26.12.1","playwrightVersion":"1.64.1"}"#,
            "remote/host/library/linux-x86_64/wovenmatter-library.gz": "fixture",
            "remote/host/library/linux-x86_64/wovenmatter-library.sha256": String(repeating: "0", count: 64) + "  wovenmatter-library\n",
            "harnesses/catalog.json": "{}", "default-agent/package.json": "{}", "default-agent/src/agent.mjs": "fixture",
            "default-agent/package-lock.json": #"{"packages":{"node_modules/playwright-core":{"version":"1.64.1"}}}"#,
            "default-agent/.node-version": "26.12.1\n", "scripts/remote-host.sh": "fixture",
        ]
        for (path, content) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        return root
    }

    private func inspect() -> Data {
        let installation = installation.map { #","installation":"# + $0 } ?? ""
        return Data((#"{"ready":true,"runtime":"host","version":"","architecture":"amd64","capabilities":{"memory":false,"swap":false},"limitations":[],"hostStorageLow":false,"blockingIssues":[],"preparationRequired":true,"bots":{"state":""# + botsState + #"","blockingIssues":[]}"# + installation + "}").utf8)
    }

    var client: RemoteWorkspaceSSHClient {
        RemoteWorkspaceSSHClient(runner: { [self] _, command, _ in
            lock.withLock { sent.append(command) }
            return inspect()
        }, scriptLoader: { Data("container-lifecycle".utf8) }, deploymentRoot: root,
        streamingRunner: { [self] _, command, input, progress in
            lock.withLock {
                sent.append(command)
                streamed.append(input.flatMap { $0.split(separator: 10, maxSplits: 1, omittingEmptySubsequences: false).first.map { String(decoding: $0, as: UTF8.self) } } ?? "")
            }
            progress(Data("WM_PROGRESS bots-engine\n".utf8))
            return Data(#"{"id":"studio","name":"Studio","state":"running","running":true,"startedAt":"","image":"native","memoryBytes":0,"swapBytes":0,"hostPort":7400,"persistentVolume":"/home/trey/.local/share/wovenmatter","capabilities":{"memory":false,"swap":false},"storageKind":"host","hostStorageLow":false,"legacyStorage":false,"kind":"host"}"#.utf8)
        }, hostScriptLoader: { Data("host-lifecycle".utf8) })
    }
}
