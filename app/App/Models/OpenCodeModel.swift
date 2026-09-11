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
    private var quitting = false
    private var connectionGeneration = UUID()
    var startServerOnLaunch: Bool { didSet { defaults.set(startServerOnLaunch, forKey: "wovenmatter.opencode.start-on-launch") } }
    var stopServerOnQuit: Bool { didSet { defaults.set(stopServerOnQuit, forKey: "wovenmatter.opencode.stop-on-quit") } }
    var isInstalled: Bool { executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }
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

    private var connectionID: String { "local:" + registration.standardizedFileURL.path }
    var connected: Set<String> { isReady ? [connectionID] : [] }
    var hasServerRegistration: Bool { FileManager.default.fileExists(atPath: registration.path) }
    var canConnect: Bool { executable != nil || hasServerRegistration }

    init(store: DashboardStore, ownerDeviceID: UUID, defaults: UserDefaults) {
        startServerOnLaunch = defaults.object(forKey: "wovenmatter.opencode.start-on-launch") as? Bool ?? true
        stopServerOnQuit = defaults.bool(forKey: "wovenmatter.opencode.stop-on-quit")
        isEnabled = defaults.object(forKey: "wovenmatter.opencode.enabled") as? Bool ?? defaults.bool(forKey: "wovenmatter.opencode.local-connected")
        hiddenModels = Set(defaults.stringArray(forKey: "wovenmatter.opencode.hidden-models") ?? [])
        self.store = store; self.ownerDeviceID = ownerDeviceID; self.defaults = defaults
        coordinator = OpenCodeSessionCoordinator(database: store.database)
        // Honor a previously selected CLI, never an old custom/remote service.
        if let path = defaults.string(forKey: "wovenmatter.opencode.executable"), FileManager.default.isExecutableFile(atPath: path) { executable = URL(fileURLWithPath: path) }
        for link in (try? store.database.openCodeLinks()) ?? [] {
            links[link.conversationID] = link
            snapshots[link.conversationID] = try? store.database.openCodeSnapshot(conversationID: link.conversationID)
        }
        updateTask = Task { [weak self, coordinator] in
            for await update in coordinator.updates {
                guard let self, !Task.isCancelled else { return }
                guard update.status == "Disconnected" || (self.isEnabled && !self.serverStopped && !self.quitting) else { continue }
                if let snapshot = update.snapshot { self.snapshots[update.conversationID] = snapshot }
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

    func isLocalSession(_ id: String) -> Bool { links[id]?.connectionID == connectionID }

    func restore() async {
        quitting = false
        await resolveExecutable()
        guard defaults.object(forKey: "wovenmatter.opencode.enabled") as? Bool != false else { return }
        guard defaults.bool(forKey: "wovenmatter.opencode.local-connected") || links.values.contains(where: { $0.connectionID == connectionID }) else { return }
        do { try await connectLocal(allowStart: startServerOnLaunch) } catch { self.error = startServerOnLaunch ? error.localizedDescription : nil }
    }

    func resolveExecutable() async {
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
        if let connectionTask { return try await connectionTask.value }
        let generation = UUID(); connectionGeneration = generation
        serverStopped = false
        isConnecting = true; error = nil
        logger.info("Connecting to the local OpenCode service")
        let task = Task { @MainActor in
            if !isInstalled { await resolveExecutable() }
            try Task.checkCancellation()
            guard generation == connectionGeneration, !quitting else { throw CancellationError() }
            logger.info("Discovering or starting the local OpenCode service")
            let connection: OpenCodeConnection
            if allowStart { connection = try await OpenCodeServiceLauncher.ensure(executable: executable, registration: registration) }
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
            defaults.set(true, forKey: "wovenmatter.opencode.enabled")
            defaults.set(true, forKey: "wovenmatter.opencode.local-connected")
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
        guard !isInstalling, !isConnecting, !isControllingServer,
              !snapshots.values.contains(where: \.active) else { throw RuntimeMaintenanceError.busy }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let installed = try await OpenCodeServiceLauncher.install()
            executable = installed
            defaults.set(installed.path, forKey: "wovenmatter.opencode.executable")
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
        try await OpenCodeServiceLauncher.stop(registration: registration)
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
        if stopServerOnQuit { try await OpenCodeServiceLauncher.stop(registration: registration) }
    }

    func disable() async {
        connectionGeneration = UUID()
        connectionTask?.cancel(); connectionTask = nil; isConnecting = false
        isEnabled = false
        defaults.set(false, forKey: "wovenmatter.opencode.enabled")
        await coordinator.disconnect(connectionID: connectionID)
        isReady = false
    }

    func browserURL() throws -> URL {
        // Discover again so a service restart never hands the browser stale credentials.
        try OpenCodeConnection.discover(file: registration).browserURL
    }

    func create(workspace: URL) async throws -> String {
        guard isEnabled else { throw OpenCodeError.message("Enable OpenCode in Local Agent Workspace before creating a chat.") }
        guard !serverStopped else { throw OpenCodeError.message("Start OpenCode from its settings page before creating a chat.") }
        guard !busy else { throw OpenCodeError.message("A session is already being created.") }
        busy = true; defer { busy = false }
        try await connectLocal()
        let pendingKey = "wovenmatter.opencode.pending-create." + connectionID
        let pending = defaults.string(forKey: pendingKey)
        let id = pending ?? "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: pendingKey)
        do {
            let response = try await coordinator.createSession(connectionID: connectionID, id: id, workspace: workspace, recover: pending != nil)
            let localID = try await open(response["data"])
            defaults.removeObject(forKey: pendingKey)
            return localID
        } catch {
            if case OpenCodeError.http(let code) = error, [400, 401, 403, 404, 422].contains(code) { defaults.removeObject(forKey: pendingKey) }
            throw error
        }
    }

    private func open(_ session: OpenCodeValue) async throws -> String {
        let sessionID = session["id"].text
        guard sessionID.hasPrefix("ses") else { throw OpenCodeError.message("OpenCode did not return a session ID.") }
        let conversationID = try store.database.createLocalACPSession(runtimeKind: .opencode, title: session["title"].string ?? "New OpenCode chat", ownerDeviceID: ownerDeviceID, openCodeAssociation: (connectionID, sessionID))
        let link = OpenCodeSessionLink(conversationID: conversationID, connectionID: connectionID, sessionID: sessionID)
        links[conversationID] = link
        var initial = OpenCodeSessionSnapshot()
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
        defaults.set(hiddenModels.sorted(), forKey: "wovenmatter.opencode.hidden-models")
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
    }

    func metadata(_ id: String) -> LocalACPSessionMetadata? {
        guard let snapshot = snapshots[id], isLocalSession(id) else { return nil }
        return OpenCodeComposerMetadata.metadata(session: snapshot.info, models: models[id] ?? [], defaultModel: defaultModels[id] ?? .null, hiddenModels: hiddenModels)
    }

    func updateSelection(_ id: String, model: String? = nil, thinking: String? = nil) {
        guard updatingSessions.insert(id).inserted else { return }
        error = nil
        let task = Task { @MainActor in
            guard let key = model ?? self.metadata(id)?.model else {
                throw OpenCodeError.message("OpenCode has no default model. Choose an available model.")
            }
            let selection = try OpenCodeComposerMetadata.selection(model: key, thinking: thinking, models: self.models[id] ?? [])
            _ = try await self.sessionCall(id, "/model", method: "POST", body: selection)
            let confirmed = try await self.sessionCall(id)
            guard OpenCodeComposerMetadata.matchesSelection(confirmed["data"]["model"], selection["model"]) else {
                throw OpenCodeError.message("OpenCode has not confirmed the selected model. Select it again before sending.")
            }
            self.snapshots[id]?.info = confirmed["data"]
        }
        selectionTasks[id] = task
        Task {
            defer { self.updatingSessions.remove(id) }
            do { try await task.value }
            catch { self.error = error.localizedDescription }
        }
    }

    func send(_ id: String, input: AgentMessageInput) async throws {
        guard let link = links[id], isLocalSession(id) else { throw OpenCodeError.message("This saved transcript is read-only. Create a new OpenCode chat.") }
        guard isEnabled else { throw OpenCodeError.message("Enable OpenCode in Local Agent Workspace before sending.") }
        guard !serverStopped else { throw OpenCodeError.message("Start OpenCode from its settings page before sending.") }
        if !isReady { try await connectLocal() }
        // A failed selection remains a send barrier until the user selects again.
        if let selection = selectionTasks[id] { try await selection.value }
        try await coordinator.prompt(link, input: input)
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { error = nil; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
}
