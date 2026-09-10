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
    var onChange: ((String) async -> Void)?
    var links: [String: OpenCodeSessionLink] = [:]
    var snapshots: [String: OpenCodeSessionSnapshot] = [:]
    var statuses: [String: String] = [:]
    var errors: [String: String] = [:]
    var error: String?
    private(set) var isReady = false
    private(set) var isConnecting = false
    private(set) var busy = false
    private(set) var updatingSessions: Set<String> = []
    private var models: [String: [OpenCodeValue]] = [:]

    private var connectionID: String { "local:" + registration.standardizedFileURL.path }
    var connected: Set<String> { isReady ? [connectionID] : [] }
    var canConnect: Bool { executable != nil || FileManager.default.fileExists(atPath: registration.path) }

    init(store: DashboardStore, ownerDeviceID: UUID, defaults: UserDefaults) {
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
                if let snapshot = update.snapshot { self.snapshots[update.conversationID] = snapshot }
                self.statuses[update.conversationID] = update.status
                self.errors[update.conversationID] = update.error
                if self.isLocalSession(update.conversationID) {
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
        await resolveExecutable()
        guard defaults.bool(forKey: "wovenmatter.opencode.local-connected") || links.values.contains(where: { $0.connectionID == connectionID }) else { return }
        do { try await connectLocal() } catch { self.error = error.localizedDescription }
    }

    private func resolveExecutable() async {
        // Login-shell discovery runs a subprocess. Never do it in a computed
        // property read by SwiftUI, where its run loop can reenter rendering.
        if let resolved = await Task.detached(priority: .utility, operation: {
            LocalACPRuntimeResolver.resolveExecutable(named: "opencode2")
        }).value { executable = resolved }
    }

    /// One local service using OpenCode's standard registration/environment.
    /// Concurrent New Chat/Connect requests share a single startup.
    func connectLocal() async throws {
        if let connectionTask { return try await connectionTask.value }
        isConnecting = true; error = nil
        logger.info("Connecting to the local OpenCode service")
        let task = Task { @MainActor in
            if executable == nil { await resolveExecutable() }
            logger.info("Discovering or starting the local OpenCode service")
            let connection = try await OpenCodeServiceLauncher.ensure(executable: executable, registration: registration)
            logger.info("Local OpenCode service is available")
            try await coordinator.connect(connection)
            isReady = true
            defaults.set(true, forKey: "wovenmatter.opencode.local-connected")
            for link in links.values where link.connectionID == connectionID { await coordinator.watch(link) }
        }
        connectionTask = task
        defer { connectionTask = nil; isConnecting = false }
        do { try await task.value }
        catch { logger.error("Local OpenCode connection failed: \(error.localizedDescription)"); isReady = false; self.error = error.localizedDescription; throw error }
    }

    func create(workspace: URL) async throws -> String {
        guard !busy else { throw OpenCodeError.message("A session is already being created.") }
        busy = true; defer { busy = false }
        try await connectLocal()
        let pendingKey = "wovenmatter.opencode.pending-create." + connectionID
        if let pending = defaults.string(forKey: pendingKey) {
            let recovered = try await coordinator.call(connectionID: connectionID, path: "/api/session/" + OpenCodeHTTPClient.segment(pending))
            let localID = try await open(recovered["data"])
            defaults.removeObject(forKey: pendingKey)
            return localID
        }
        let id = "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: pendingKey)
        do {
            let response = try await coordinator.call(connectionID: connectionID, method: "POST", path: "/api/session",
                body: ["id": .string(id), "location": ["directory": .string(workspace.path)]])
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

    func refreshCatalog(_ id: String) async throws {
        guard isLocalSession(id) else { return }
        let result = try await coordinator.call(connectionID: connectionID, path: "/api/model", query: locationQuery(id))
        models[id] = result["data"].array.filter { $0["enabled"].bool }
    }

    func metadata(_ id: String) -> LocalACPSessionMetadata? {
        guard let snapshot = snapshots[id], isLocalSession(id) else { return nil }
        return OpenCodeComposerMetadata.metadata(session: snapshot.info, models: models[id] ?? [])
    }

    func updateSelection(_ id: String, model: String? = nil, thinking: String? = nil) {
        guard updatingSessions.insert(id).inserted else { return }
        perform {
            defer { self.updatingSessions.remove(id) }
            guard let key = model ?? self.metadata(id)?.model else { return }
            let selection = try OpenCodeComposerMetadata.selection(model: key, thinking: thinking, models: self.models[id] ?? [])
            _ = try await self.sessionCall(id, "/model", method: "POST", body: selection)
        }
    }

    func send(_ id: String, input: AgentMessageInput) async throws {
        guard let link = links[id], isLocalSession(id) else { throw OpenCodeError.message("This saved transcript is read-only. Create a new OpenCode chat.") }
        if !isReady { try await connectLocal() }
        try await coordinator.prompt(link, input: input)
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { error = nil; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
}
