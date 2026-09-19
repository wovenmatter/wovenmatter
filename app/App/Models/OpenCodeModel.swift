import Foundation
import Observation
import OSLog
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

@MainActor @Observable
final class OpenCodeModel {
    private let logger = Logger(subsystem: "wovenmatter.desktop", category: "OpenCode")
    let store: DashboardStore
    let coordinator: OpenCodeSessionCoordinator
    let ownerDeviceID: UUID
    let remoteConfiguration: RemoteWorkspaceConfiguration?
    private weak var remoteWorkspaces: RemoteWorkspacesModel?
    var workspaceName: String { remoteConfiguration?.name ?? "Local agent workspace" }
    var isRemote: Bool { remoteConfiguration != nil }
    private let defaults: UserDefaults
    private let registration = OpenCodeConnection.registrationURL()
    private var updateTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Error>?
    private var executable: URL?
    var runtimeExecutable: URL? { executable }
    var onChange: ((String) async -> Void)?
    var links: [String: OpenCodeSessionLink] = [:]
    var snapshots: [String: OpenCodeSessionSnapshot] = [:]
    var statuses: [String: String] = [:]
    var errors: [String: String] = [:]
    var error: String?
    private(set) var isInstalling = false
    private(set) var installationFailures = 0
    private(set) var installationInventory: RuntimeInventory?
    var installationDiagnostic: String {
        RuntimeMaintenance.diagnostic(inventory: installationInventory, kind: .opencode,
            attempts: installationFailures, failure: "The pinned OpenCode v2 install could not be verified. Raw installer output omitted.")
    }
    private(set) var isControllingServer = false
    private var serverStopped = false
    var canRestoreAutomatically: Bool { !serverStopped && !quitting }
    private var quitting = false
    private var connectionGeneration = UUID()
    var startServerOnLaunch: Bool { didSet { defaults.set(startServerOnLaunch, forKey: preference("start-on-launch")) } }
    var stopServerOnQuit: Bool { didSet { defaults.set(stopServerOnQuit, forKey: preference("stop-on-quit")) } }
    var isInstalled: Bool {
        if let configuration = remoteConfiguration {
            return remoteWorkspaces?.runtimeMaintenance[configuration.id]?.first { $0.id == .opencode }?.installed == true
        }
        return executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
    }
    private(set) var isEnabled = false
    private(set) var isReady = false
    private(set) var isConnecting = false
    private(set) var busy = false
    private(set) var updatingSessions: Set<String> = []
    private(set) var hiddenModels: Set<String> = []
    private(set) var settingsModels: [OpenCodeValue] = []
    private var selectionTasks: [String: Task<Void, Error>] = [:]
    private var defaultModels: [String: OpenCodeValue] = [:]
    private var models: [String: [OpenCodeValue]] = [:]
    private var commands: [String: [OpenCodeValue]] = [:]

    private var connectionID: String {
        remoteConfiguration.map { "remote-workspace:" + $0.id.uuidString.lowercased() }
            ?? "local:" + registration.standardizedFileURL.path
    }
    private func preference(_ suffix: String) -> String {
        "wovenmatter.opencode." + (remoteConfiguration.map { "remote." + $0.id.uuidString.lowercased() + "." } ?? "") + suffix
    }
    var connected: Set<String> { isReady ? [connectionID] : [] }
    var hasServerRegistration: Bool {
        if let configuration = remoteConfiguration {
            guard remoteWorkspaces?.isCredentialAccessEnabled == true,
                  remoteWorkspaces?.configuration(id: configuration.id) == configuration else { return false }
            let status = remoteWorkspaces?.workspaceInstances[configuration.id]?[.opencode]
            return isReady || status?.state == "running" || status?.pid != nil
        }
        return FileManager.default.fileExists(atPath: registration.path)
    }
    var canConnect: Bool {
        if let configuration = remoteConfiguration { return remoteWorkspaces?.isRuntimeEnabled(.opencode, in: configuration) == true }
        return executable != nil || hasServerRegistration
    }

    init(store: DashboardStore, ownerDeviceID: UUID, defaults: UserDefaults,
         remoteConfiguration: RemoteWorkspaceConfiguration? = nil, remoteWorkspaces: RemoteWorkspacesModel? = nil) {
        self.remoteConfiguration = remoteConfiguration
        self.remoteWorkspaces = remoteWorkspaces
        let preference: (String) -> String = { suffix in
            "wovenmatter.opencode." + (remoteConfiguration.map { "remote." + $0.id.uuidString.lowercased() + "." } ?? "") + suffix
        }
        startServerOnLaunch = defaults.object(forKey: preference("start-on-launch")) as? Bool ?? true
        stopServerOnQuit = defaults.bool(forKey: preference("stop-on-quit"))
        isEnabled = defaults.object(forKey: preference("enabled")) as? Bool ?? defaults.bool(forKey: preference("local-connected"))
        hiddenModels = Set(defaults.stringArray(forKey: preference("hidden-models")) ?? [])
        self.store = store; self.ownerDeviceID = ownerDeviceID; self.defaults = defaults
        coordinator = OpenCodeSessionCoordinator(database: store.database)
        // Honor a previously selected CLI, never an old custom/remote service.
        if remoteConfiguration == nil, let path = defaults.string(forKey: preference("executable")), FileManager.default.isExecutableFile(atPath: path) { executable = URL(fileURLWithPath: path) }
        let identity = remoteConfiguration.map { "remote-workspace:" + $0.id.uuidString.lowercased() }
            ?? "local:" + registration.standardizedFileURL.path
        for link in (try? store.database.openCodeLinks()) ?? [] where link.connectionID == identity {
            links[link.conversationID] = link
            if let snapshot = try? store.database.openCodeSnapshot(conversationID: link.conversationID) {
                snapshots[link.conversationID] = try? store.database.openCodeDisplaySnapshot(snapshot, conversationID: link.conversationID)
            }
        }
        updateTask = Task { [weak self, coordinator] in
            for await update in coordinator.updates {
                guard let self, !Task.isCancelled else { return }
                guard update.status == "Disconnected" || (self.isEnabled && !self.serverStopped && !self.quitting) else { continue }
                if let snapshot = update.snapshot { self.snapshots[update.conversationID] = try? store.database.openCodeDisplaySnapshot(snapshot, conversationID: update.conversationID) }
                self.statuses[update.conversationID] = update.status
                self.errors[update.conversationID] = update.error
                if self.isEnabled, !self.serverStopped, !self.isControllingServer, self.isLocalSession(update.conversationID) {
                    if update.status == "Connected" { self.isReady = true }
                    else if ["Reconnecting", "Unsupported version", "Authentication required"].contains(update.status) { self.isReady = false }
                    if update.status == "Reconnecting", !self.isConnecting {
                        do { try await self.connectLocal() } catch { self.error = error.localizedDescription }
                    }
                }
                await self.onChange?(update.conversationID)
            }
        }
    }

    isolated deinit {
        updateTask?.cancel()
        connectionTask?.cancel()
    }

    func isLocalSession(_ id: String) -> Bool { links[id]?.connectionID == connectionID }

    func restore() async {
        quitting = false
        if let configuration = remoteConfiguration {
            guard remoteWorkspaces?.isRuntimeEnabled(.opencode, in: configuration) == true else {
                await suspendConnection()
                return
            }
            isEnabled = true
            if isReady { return }
            do { try await connectLocal(allowStart: startServerOnLaunch) }
            catch { self.error = error.localizedDescription }
            return
        }
        await resolveExecutable()
        guard defaults.object(forKey: preference("enabled")) as? Bool != false else { return }
        guard defaults.bool(forKey: preference("local-connected")) || links.values.contains(where: { $0.connectionID == connectionID }) else { return }
        do { try await connectLocal(allowStart: startServerOnLaunch) } catch { self.error = startServerOnLaunch ? error.localizedDescription : nil }
    }

    func resolveExecutable() async {
        guard !isRemote else { return }
        // Login-shell discovery runs a subprocess. Never do it in a computed
        // property read by SwiftUI, where its run loop can reenter rendering.
        if !isInstalled { executable = nil }
        if executable != nil { return }
        if let resolved = await Task.detached(priority: .utility, operation: {
            LocalACPRuntimeResolver.resolveExecutable(named: "opencode2")
        }).value { executable = resolved }
    }

    /// One local service using OpenCode's standard registration/environment.
    /// Concurrent New Chat/Connect requests share a single startup.
    func connectLocal(allowStart: Bool = true) async throws {
        guard !quitting else { throw CancellationError() }
        if let configuration = remoteConfiguration,
           remoteWorkspaces?.isRuntimeEnabled(.opencode, in: configuration) != true {
            throw OpenCodeError.message("Enable OpenCode for this remote workspace before connecting.")
        }
        if let connectionTask { return try await connectionTask.value }
        let generation = UUID(); connectionGeneration = generation
        serverStopped = false
        isConnecting = true; error = nil
        logger.info("Connecting to the local OpenCode service")
        let task = Task { @MainActor in
            if !isInstalled, !isRemote { await resolveExecutable() }
            try Task.checkCancellation()
            guard generation == connectionGeneration, !quitting else { throw CancellationError() }
            logger.info("Discovering or starting the local OpenCode service")
            let connection: OpenCodeConnection
            if let configuration = remoteConfiguration {
                guard let remoteWorkspaces else { throw OpenCodeError.message("The remote workspace is unavailable.") }
                connection = try await remoteWorkspaces.prepareOpenCodeConnection(for: configuration, allowStart: allowStart)
                _ = try await OpenCodeHTTPClient(connection: connection).health()
            } else if allowStart { connection = try await OpenCodeServiceLauncher.ensure(executable: executable, registration: registration) }
            else {
                connection = try OpenCodeConnection.discover(file: registration)
                _ = try await OpenCodeHTTPClient(connection: connection).health()
            }
            try Task.checkCancellation()
            guard generation == connectionGeneration, !quitting else { throw CancellationError() }
            logger.info("Local OpenCode service is available")
            try await coordinator.connect(connection)
            try Task.checkCancellation()
            guard generation == connectionGeneration, !quitting else { throw CancellationError() }
            isReady = true
            isEnabled = true
            defaults.set(true, forKey: preference("enabled"))
            defaults.set(true, forKey: preference("local-connected"))
            for link in links.values where link.connectionID == connectionID { await coordinator.watch(link) }
        }
        connectionTask = task
        defer { if generation == connectionGeneration { connectionTask = nil; isConnecting = false } }
        do { try await task.value }
        catch {
            if generation == connectionGeneration {
                isReady = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            throw error
        }
    }

    func download() async throws {
        guard !isRemote else { throw OpenCodeError.message("Install OpenCode from this remote workspace's runtime row.") }
        guard !isInstalling, !isConnecting, !isControllingServer,
              !snapshots.values.contains(where: \.active) else { throw RuntimeMaintenanceError.busy }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let installed = try await OpenCodeServiceLauncher.install()
            executable = installed
            defaults.set(installed.path, forKey: preference("executable"))
            installationInventory = await RuntimeMaintenance.inspect(.opencode, checkLatest: true, selectedOpenCode: installed)
            guard installationInventory?.isInstalled == true else { throw RuntimeMaintenanceError.verification }
            installationFailures = 0
        } catch {
            installationFailures += 1
            installationInventory = await RuntimeMaintenance.inspect(.opencode, checkLatest: false, selectedOpenCode: executable)
            throw RuntimeMaintenanceError.verification
        }
    }

    func stopServer() async throws {
        guard !isControllingServer, !isConnecting else { throw OpenCodeError.message("Wait for the current server operation to finish.") }
        isControllingServer = true
        serverStopped = true
        defer { isControllingServer = false }
        await coordinator.disconnect(connectionID: connectionID)
        isReady = false
        if let configuration = remoteConfiguration {
            guard let remoteWorkspaces else { throw OpenCodeError.message("The remote workspace is unavailable.") }
            try await remoteWorkspaces.stopOpenCode(for: configuration)
        } else { try await OpenCodeServiceLauncher.stop(registration: registration) }
    }

    func restartServer() async throws {
        try await stopServer()
        try await connectLocal()
    }

    func prepareToQuit() async throws {
        quitting = true
        serverStopped = true
        if let connectionTask { _ = try? await connectionTask.value }
        while isControllingServer { try await Task.sleep(for: .milliseconds(25)) }
        serverStopped = true
        await coordinator.shutdown()
        isReady = false
        if stopServerOnQuit {
            if let configuration = remoteConfiguration {
                guard remoteWorkspaces?.isRuntimeEnabled(.opencode, in: configuration) == true else { return }
                guard let remoteWorkspaces else { throw OpenCodeError.message("The remote workspace is unavailable.") }
                try await remoteWorkspaces.stopOpenCode(for: configuration)
            } else { try await OpenCodeServiceLauncher.stop(registration: registration) }
        }
    }

    func suspendConnection() async {
        connectionGeneration = UUID()
        connectionTask?.cancel(); connectionTask = nil; isConnecting = false
        isEnabled = false
        await coordinator.disconnect(connectionID: connectionID)
        isReady = false
    }

    func disable() async {
        guard !isRemote else { await suspendConnection(); return }
        connectionGeneration = UUID()
        connectionTask?.cancel(); connectionTask = nil; isConnecting = false
        isEnabled = false
        defaults.set(false, forKey: preference("enabled"))
        await coordinator.disconnect(connectionID: connectionID)
        isReady = false
    }

    func browserURL() throws -> URL {
        guard !isRemote else { throw OpenCodeError.message("Remote OpenCode uses the authenticated workspace connection inside Woven Matter.") }
        // Discover again so a service restart never hands the browser stale credentials.
        return try OpenCodeConnection.discover(file: registration).browserURL
    }

    func create(workspace: URL, requestedConversationID: UUID? = nil, title: String? = nil) async throws -> String {
        guard isEnabled else { throw OpenCodeError.message("Enable OpenCode for this workspace before creating a chat.") }
        guard !serverStopped else { throw OpenCodeError.message("Start OpenCode from its settings page before creating a chat.") }
        guard !busy else { throw OpenCodeError.message("A session is already being created.") }
        busy = true; defer { busy = false }
        try await connectLocal()
        let pendingKey = "wovenmatter.opencode.pending-create." + connectionID + (requestedConversationID.map { "." + $0.uuidString.lowercased() } ?? "")
        let pending = defaults.string(forKey: pendingKey)
        let id = pending ?? "ses_" + (requestedConversationID ?? UUID()).uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: pendingKey)
        do {
            let response = try await coordinator.createSession(connectionID: connectionID, id: id, workspace: workspace, recover: pending != nil || requestedConversationID != nil, title: title)
            let localID = try await open(response["data"], requestedConversationID: requestedConversationID)
            defaults.removeObject(forKey: pendingKey)
            return localID
        } catch {
            if case OpenCodeError.http(let code) = error, [400, 401, 403, 404, 422].contains(code) { defaults.removeObject(forKey: pendingKey) }
            throw error
        }
    }

    func importableSessions(cursor: String? = nil) async throws -> (sessions: [OpenCodeValue], next: String?) {
        guard isReady, !isRemote else { throw OpenCodeError.message("Connect to local OpenCode first.") }
        return try await coordinator.importableSessions(connectionID: connectionID, cursor: cursor)
    }

    func importSession(_ session: OpenCodeValue) async throws {
        guard isReady, !isRemote, !busy else { throw OpenCodeError.message("OpenCode is not ready to import.") }
        let id = session["id"].text
        guard !(try store.database.knownOpenCodeSessionIDs(connectionID: connectionID)).contains(id) else {
            throw OpenCodeError.message("This session is already in Woven Matter. Refresh the list.")
        }
        busy = true
        defer { busy = false }
        let snapshot = try await coordinator.completeImportSnapshot(connectionID: connectionID, sessionID: id)
        _ = try await open(snapshot.info, importedSnapshot: snapshot)
    }

    private func open(_ session: OpenCodeValue, importedSnapshot: OpenCodeSessionSnapshot? = nil, requestedConversationID: UUID? = nil) async throws -> String {
        let sessionID = session["id"].text
        guard sessionID.hasPrefix("ses") else { throw OpenCodeError.message("OpenCode did not return a session ID.") }
        let conversationID: String
        if let configuration = remoteConfiguration {
            conversationID = try store.database.createRemoteACPSession(runtimeKind: .opencode,
                remoteWorkspaceID: configuration.id, remoteWorkspaceName: configuration.name,
                title: session["title"].string ?? "New OpenCode chat", ownerDeviceID: ownerDeviceID,
                openCodeAssociation: (connectionID, sessionID), requestedConversationID: requestedConversationID)
        } else {
            conversationID = try store.database.createLocalACPSession(runtimeKind: .opencode,
                title: session["title"].string ?? "New OpenCode chat", ownerDeviceID: ownerDeviceID,
                openCodeAssociation: (connectionID, sessionID), importedOpenCodeSnapshot: importedSnapshot, requestedConversationID: requestedConversationID)
        }
        let link = OpenCodeSessionLink(conversationID: conversationID, connectionID: connectionID, sessionID: sessionID)
        links[conversationID] = link
        var initial = importedSnapshot ?? OpenCodeSessionSnapshot()
        initial.info = session
        snapshots[conversationID] = initial
        do { try await refreshCatalog(conversationID) }
        catch { self.error = error.localizedDescription }
        await coordinator.watch(link)
        await onChange?(conversationID)
        return conversationID
    }

    func sessionCall(_ id: String, _ suffix: String = "", method: String = "GET", body: OpenCodeValue? = nil) async throws -> OpenCodeValue {
        guard let link = links[id], isLocalSession(id) else { throw OpenCodeError.message("This is a saved transcript. Start a new OpenCode chat to continue.") }
        let result = try await coordinator.call(connectionID: connectionID, method: method,
            path: "/api/session/" + OpenCodeHTTPClient.segment(link.sessionID) + suffix, body: body)
        if method != "GET" { try? await coordinator.refresh(link) }
        return result
    }

    func locationQuery(_ id: String) -> [String: String] {
        let location = snapshots[id]?.info["location"] ?? .null
        var query = ["location[directory]": location["directory"].text]
        if let workspace = location["workspaceID"].string { query["location[workspace]"] = workspace }
        return query
    }

    func setModelVisible(_ key: String, visible: Bool) {
        if visible { hiddenModels.remove(key) } else { hiddenModels.insert(key) }
        defaults.set(hiddenModels.sorted(), forKey: preference("hidden-models"))
    }

    func refreshSettingsModels(workspace: String) async throws {
        let result = try await coordinator.call(connectionID: connectionID, path: "/api/model",
            query: ["location[directory]": workspace])
        settingsModels = result["data"].array.filter { $0["enabled"].bool }.sorted {
            if $0["providerID"].text != $1["providerID"].text { return $0["providerID"].text < $1["providerID"].text }
            return $0["name"].text.localizedCaseInsensitiveCompare($1["name"].text) == .orderedAscending
        }
    }

    func refreshCatalog(_ id: String) async throws {
        guard isLocalSession(id) else { return }
        let result = try await coordinator.call(connectionID: connectionID, path: "/api/model", query: locationQuery(id))
        let fallback = try await coordinator.call(connectionID: connectionID, path: "/api/model/default", query: locationQuery(id))
        models[id] = result["data"].array.filter { $0["enabled"].bool }
        defaultModels[id] = fallback["data"]
        commands[id] = []
        let catalog = try await coordinator.call(connectionID: connectionID, path: "/api/command", query: locationQuery(id))
        commands[id] = catalog["data"].array
    }

    func metadata(_ id: String) -> LocalACPSessionMetadata? {
        guard let snapshot = snapshots[id], isLocalSession(id) else { return nil }
        return OpenCodeComposerMetadata.metadata(session: snapshot.info, models: models[id] ?? [], defaultModel: defaultModels[id] ?? .null, hiddenModels: hiddenModels, commands: commands[id] ?? [])
    }

    @discardableResult
    func updateSelection(_ id: String, model: String? = nil, thinking: String? = nil) -> Task<Void, Error>? {
        guard updatingSessions.insert(id).inserted else { return nil }
        error = nil
        let task = Task { @MainActor in
            guard let key = model ?? self.metadata(id)?.model else {
                throw OpenCodeError.message("OpenCode has no default model. Choose an available model.")
            }
            let selection = try OpenCodeComposerMetadata.selection(model: key, thinking: thinking, models: self.models[id] ?? [])
            guard let link = self.links[id], self.isLocalSession(id) else {
                throw OpenCodeError.message("This saved transcript cannot change its model.")
            }
            let confirmed = try await self.coordinator.configureSelection(link, selection: selection)
            self.snapshots[id]?.info = confirmed
            try? await self.coordinator.refresh(link)
        }
        selectionTasks[id] = task
        Task {
            defer { self.updatingSessions.remove(id) }
            do { try await task.value }
            catch { self.error = error.localizedDescription }
        }
        return task
    }

    func confirmCreationSelection(_ id: String, model: String?, thinking: String?) async throws {
        // Opening a native session can succeed before its model catalog arrives.
        // Creation retries must retry that discovery instead of accepting defaults.
        try await refreshCatalog(id)
        guard let task = updateSelection(id, model: model, thinking: thinking) else {
            throw OpenCodeError.message("A model selection is already in progress. Retry session creation after it completes.")
        }
        try await task.value
    }

    func send(_ id: String, input: AgentMessageInput, discovery: String? = nil) async throws {
        guard let link = links[id], isLocalSession(id) else { throw OpenCodeError.message("This saved transcript is read-only. Create a new OpenCode chat.") }
        guard isEnabled else { throw OpenCodeError.message("Enable OpenCode for this workspace before sending.") }
        if let configuration = remoteConfiguration,
           remoteWorkspaces?.isRuntimeEnabled(.opencode, in: configuration) != true {
            throw OpenCodeError.message("OpenCode is disabled for this remote workspace.")
        }
        guard !serverStopped else { throw OpenCodeError.message("Start OpenCode from its settings page before sending.") }
        if !isReady { try await connectLocal() }
        // A failed selection remains a send barrier until the user selects again.
        if let selection = selectionTasks[id] { try await selection.value }
        if let command = OpenCodeComposerMetadata.invocation(input.text, commands: commands[id] ?? []) {
            try await coordinator.command(link, name: command.name,
                input: AgentMessageInput(text: command.arguments, attachments: input.attachments, historyDeliveryID: input.historyDeliveryID), discovery: discovery)
        } else {
            try await coordinator.prompt(link, input: input, discovery: discovery)
        }
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { error = nil; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
}
