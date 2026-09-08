import AppKit
import Foundation
import Observation
import Security
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

@MainActor @Observable
final class OpenCodeModel {
    struct Server: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var url: String
        var username: String
        var registration: String?
    }
    let store: DashboardStore
    let coordinator: OpenCodeSessionCoordinator
    let ownerDeviceID: UUID
    private let defaults: UserDefaults
    private var updateTask: Task<Void, Never>?
    var onChange: ((String) async -> Void)?
    var servers: [Server] = []
    var connected: Set<String> = []
    var selectedServerID: String = ""
    var links: [String: OpenCodeSessionLink] = [:]
    var snapshots: [String: OpenCodeSessionSnapshot] = [:]
    var statuses: [String: String] = [:]
    var errors: [String: String] = [:]
    var requestedConversationID: String?
    var error: String?
    var busy = false
    var sessions: [OpenCodeValue] = []
    var sessionsCursor: String?
    var directory: String
    var executablePath: String
    var registrationPath: String
    var delivery: [String: String] = [:]
    var serverFiles: [String: [OpenCodeValue]] = [:]
    var models: [String: [OpenCodeValue]] = [:]
    var agents: [String: [OpenCodeValue]] = [:]

    init(store: DashboardStore, ownerDeviceID: UUID, defaults: UserDefaults) {
        self.store = store; self.ownerDeviceID = ownerDeviceID; self.defaults = defaults
        coordinator = OpenCodeSessionCoordinator(database: store.database)
        directory = defaults.string(forKey: "wovenmatter.opencode.directory") ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".woven-matter").path
        registrationPath = defaults.string(forKey: "wovenmatter.opencode.registration") ?? OpenCodeConnection.registrationURL().path
        executablePath = defaults.string(forKey: "wovenmatter.opencode.executable") ?? LocalACPRuntimeResolver.resolveExecutable(named: "opencode2")?.path ?? ""
        if let data = defaults.data(forKey: "wovenmatter.opencode.servers"), let saved = try? JSONDecoder().decode([Server].self, from: data) { servers = saved }
        selectedServerID = defaults.string(forKey: "wovenmatter.opencode.selected-server") ?? servers.first?.id ?? ""
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
                await self.onChange?(update.conversationID)
            }
        }
    }
    var isReady: Bool { connected.contains(selectedServerID) }
    func savePreferences() {
        defaults.set(try? JSONEncoder().encode(servers), forKey: "wovenmatter.opencode.servers")
        defaults.set(selectedServerID, forKey: "wovenmatter.opencode.selected-server")
        defaults.set(directory, forKey: "wovenmatter.opencode.directory")
        defaults.set(registrationPath, forKey: "wovenmatter.opencode.registration")
        defaults.set(executablePath, forKey: "wovenmatter.opencode.executable")
    }
    func restore() async {
        for server in servers where defaults.bool(forKey: "wovenmatter.opencode.autoconnect." + server.id) {
            do { try await connect(server) } catch { self.error = error.localizedDescription }
        }
    }
    func connectLocal() async throws {
        let registration = URL(fileURLWithPath: registrationPath)
        let connection = try OpenCodeConnection.discover(file: registration)
        try await coordinator.connect(connection)
        let server = Server(id: connection.identity, name: "This Mac", url: connection.url.absoluteString,
                            username: "opencode", registration: registration.path)
        servers.removeAll { $0.id == server.id }; servers.insert(server, at: 0)
        selectedServerID = server.id; connected.insert(server.id)
        defaults.set(true, forKey: "wovenmatter.opencode.autoconnect." + server.id)
        savePreferences(); watchServer(server.id); try await listSessions()
    }
    func addRemote(name: String, url: String, username: String, password: String) async throws {
        let origin = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: origin) else { throw OpenCodeError.message("Enter the OpenCode server URL.") }
        let id = servers.first(where: { $0.registration == nil && $0.url == origin })?.id ?? UUID().uuidString
        let server = Server(id: id, name: name.isEmpty ? endpoint.host ?? "Remote" : name, url: origin, username: username, registration: nil)
        let connection = try OpenCodeConnection(identity: id, url: endpoint, username: username, password: password)
        try await coordinator.connect(connection)
        try savePassword(password, id: id)
        servers.removeAll { $0.id == id }; servers.append(server)
        selectedServerID = id; connected.insert(id)
        defaults.set(true, forKey: "wovenmatter.opencode.autoconnect." + id)
        savePreferences(); watchServer(id); try await listSessions()
    }
    func connect(_ server: Server) async throws {
        let connection: OpenCodeConnection
        if let registration = server.registration { connection = try .discover(file: URL(fileURLWithPath: registration)) }
        else {
            guard let url = URL(string: server.url) else { throw OpenCodeError.message("Invalid saved server URL.") }
            connection = try OpenCodeConnection(identity: server.id, url: url, username: server.username, password: loadPassword(id: server.id))
        }
        try await coordinator.connect(connection)
        connected.insert(server.id); watchServer(server.id)
        defaults.set(true, forKey: "wovenmatter.opencode.autoconnect." + server.id)
    }
    func disconnect(_ id: String) async {
        await coordinator.disconnect(connectionID: id); connected.remove(id)
        defaults.set(false, forKey: "wovenmatter.opencode.autoconnect." + id)
    }
    func watchServer(_ id: String) {
        for link in links.values where link.connectionID == id { Task { await coordinator.watch(link) } }
    }
    func listSessions(search: String = "", more: Bool = false) async throws {
        var query = ["limit": "50", "order": "desc", "search": search]
        if more, let sessionsCursor { query["cursor"] = sessionsCursor }
        let serverID = selectedServerID
        let result = try await coordinator.call(connectionID: serverID, path: "/api/session", query: query)
        guard selectedServerID == serverID else { return }
        sessions = more ? sessions + result["data"].array : result["data"].array
        var seen: Set<String> = []; sessions = sessions.filter { seen.insert($0["id"].text).inserted }
        sessionsCursor = result["data"].array.count == 50 ? result["cursor"]["next"].string : nil
    }
    func create() async throws -> String {
        guard directory.hasPrefix("/") else { throw OpenCodeError.message("Enter an absolute workspace path on the server's machine.") }
        savePreferences()
        guard !busy else { throw OpenCodeError.message("A session is already being created.") }
        busy = true; defer { busy = false }
        let serverID = selectedServerID
        let pendingKey = "wovenmatter.opencode.pending-create." + serverID
        if let pending = defaults.string(forKey: pendingKey) {
            let recovered = try await coordinator.call(connectionID: serverID, path: "/api/session/" + OpenCodeHTTPClient.segment(pending))
            let localID = try await open(recovered["data"], serverID: serverID)
            defaults.removeObject(forKey: pendingKey)
            return localID
        }
        let id = "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: pendingKey)
        do {
            let response = try await coordinator.call(connectionID: serverID, method: "POST", path: "/api/session",
                body: ["id": .string(id), "location": ["directory": .string(directory)]])
            let localID = try await open(response["data"], serverID: serverID)
            defaults.removeObject(forKey: pendingKey)
            return localID
        } catch {
            if case OpenCodeError.http(let code) = error, [400, 401, 403, 404, 422].contains(code) { defaults.removeObject(forKey: pendingKey) }
            throw error
        }
    }
    func open(_ session: OpenCodeValue, serverID: String? = nil) async throws -> String {
        let server = serverID ?? selectedServerID
        let sessionID = session["id"].text
        guard sessionID.hasPrefix("ses") else { throw OpenCodeError.message("OpenCode did not return a session ID.") }
        if let link = links.values.first(where: { $0.connectionID == server && $0.sessionID == sessionID }) {
            await coordinator.watch(link); return link.conversationID
        }
        let conversationID = try store.database.createLocalACPSession(runtimeKind: .opencode, title: session["title"].string ?? "New OpenCode chat", ownerDeviceID: ownerDeviceID, openCodeAssociation: (server, sessionID))
        let link = OpenCodeSessionLink(conversationID: conversationID, connectionID: server, sessionID: sessionID)
        links[conversationID] = link
        await coordinator.watch(link)
        await onChange?(conversationID)
        return conversationID
    }
    func sessionCall(_ id: String, _ suffix: String = "", method: String = "GET", body: OpenCodeValue? = nil, query: [String: String] = [:]) async throws -> OpenCodeValue {
        guard let link = links[id] else { throw OpenCodeError.message("This is a saved OpenCode v1 transcript. Start a new v2 session to continue working.") }
        let result = try await coordinator.call(connectionID: link.connectionID, method: method,
            path: "/api/session/" + OpenCodeHTTPClient.segment(link.sessionID) + suffix, query: query, body: body)
        if method != "GET" { try? await coordinator.refresh(link) }
        return result
    }
    func locationQuery(_ id: String?) -> [String: String] {
        let location = id.flatMap { snapshots[$0]?.info["location"] }
        var query = ["location[directory]": location?["directory"].string ?? directory]
        if let workspace = location?["workspaceID"].string { query["location[workspace]"] = workspace }
        return query
    }
    func resource(_ path: String, conversationID: String? = nil, method: String = "GET", body: OpenCodeValue? = nil, query: [String: String] = [:]) async throws -> OpenCodeValue {
        let server = conversationID.flatMap { links[$0]?.connectionID } ?? selectedServerID
        return try await coordinator.call(connectionID: server, method: method, path: "/api/" + path,
            query: locationQuery(conversationID).merging(query, uniquingKeysWith: { _, value in value }), body: body)
    }
    func refreshCatalog(_ id: String) async throws {
        async let modelList = resource("model", conversationID: id)
        async let agentList = resource("agent", conversationID: id)
        let result = try await (modelList, agentList)
        models[id] = result.0["data"].array.filter { $0["enabled"].bool }
        agents[id] = result.1["data"].array
    }
    func send(_ id: String, input: AgentMessageInput) async throws {
        guard let link = links[id] else { throw OpenCodeError.message("OpenCode v1 sessions are read-only. Create a new OpenCode v2 session.") }
        let pendingFiles = serverFiles[id] ?? []
        try await coordinator.prompt(link, input: input, delivery: delivery[id] ?? "queue", serverFiles: pendingFiles)
        serverFiles[id]?.removeAll { pendingFiles.contains($0) }
    }
    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { error = nil; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
    private var keychainService: String { (Bundle.main.bundleIdentifier ?? "com.wovenmatter") + ".opencode" }
    private func savePassword(_ password: String, id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: id]
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound, SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, v in v }) as CFDictionary, nil) == errSecSuccess else { throw OpenCodeError.message("Could not save the OpenCode password in Keychain.") }
    }
    private func loadPassword(id: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw OpenCodeError.message("Reconnect this server to restore its Keychain credentials.") }
        return String(decoding: data, as: UTF8.self)
    }
}
