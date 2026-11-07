import Foundation

/// One WebSocket to a Pi Bot server, with request correlation and reconnects. All of
/// Woven's bot UI runs over it: the sidebar, conversations, and Settings.
public actor PiBotClient {
    public enum ConnectionState: String, Sendable { case connecting, open, closed }
    public enum Event: Sendable {
        case state(ConnectionState)
        case hello(PiBotHealth)
        case botsChanged
        case groupsChanged
        case threadsChanged(botID: String)
        case memoryChanged(botID: String)
        case conversation(botID: String, conversationID: Int, PiBotStreamEvent)
        case login(loginID: String, PiBotLoginEvent)
    }

    public struct RemoteError: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let socketURL: URL
    private let onEvent: @Sendable (Event) -> Void
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<GatewayJSONValue, any Error>] = [:]
    private var stopped = true
    private var attempt = 0
    private var reconnect: Task<Void, Never>?
    private var generation = 0
    private var expectingRestart = false
    public private(set) var state = ConnectionState.closed

    public init(baseURL: URL, onEvent: @escaping @Sendable (Event) -> Void) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        components.query = nil
        socketURL = components.url!
        self.onEvent = onEvent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func connect() {
        stopped = false
        guard task == nil else { return }
        open()
    }

    public func close() {
        stopped = true
        reconnect?.cancel(); reconnect = nil
        generation += 1
        task?.cancel(with: .goingAway, reason: nil); task = nil
        failPending("Connection closed.")
        update(.closed)
    }

    /// Closes the session as well, for a client that will not be reused.
    public func invalidate() {
        close()
        session.invalidateAndCancel()
    }

    private func open() {
        generation += 1
        let current = generation
        update(.connecting)
        let socket = session.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 16 * 1024 * 1024
        task = socket
        socket.resume()
        Task { await self.receive(socket, generation: current) }
    }

    private func receive(_ socket: URLSessionWebSocketTask, generation current: Int) async {
        while generation == current {
            do {
                let message = try await socket.receive()
                guard generation == current else { return }
                if case .string(let text) = message { handle(text) }
                else if case .data(let data) = message { handle(String(decoding: data, as: UTF8.self)) }
            } catch {
                guard generation == current else { return }
                disconnected()
                return
            }
        }
    }

    private func disconnected() {
        task = nil
        failPending("Connection lost.")
        update(.closed)
        guard !stopped else { return }
        // A deliberate restart comes back quickly, so don't back off from it.
        let delay = expectingRestart ? 0.5 : min(0.5 * pow(2, Double(attempt)), 10)
        attempt += 1
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.reopen()
        }
    }

    /// The server was told to restart: keep retrying promptly until it is back.
    public func expectRestart() { expectingRestart = true }

    private func reopen() {
        guard !stopped, task == nil else { return }
        open()
    }

    private func failPending(_ reason: String) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: RemoteError(message: reason)) }
    }

    private func update(_ next: ConnectionState) {
        guard state != next else { return }
        state = next
        onEvent(.state(next))
    }

    private func handle(_ text: String) {
        guard let value = try? JSONDecoder().decode(GatewayJSONValue.self, from: Data(text.utf8)),
              let object = value.objectValue, let type = object["type"]?.stringValue else { return }
        switch type {
        case "hello":
            attempt = 0
            expectingRestart = false
            update(.open)
            if let data = try? JSONEncoder().encode(value),
               let hello = try? JSONDecoder().decode(PiBotHello.self, from: data) {
                onEvent(.hello(PiBotHealth(ok: true, version: hello.version, protocol: hello.protocol,
                    installationId: hello.installationId, capabilities: hello.capabilities)))
            }
        case "result":
            guard let id = object["id"]?.intValue, let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(returning: object["data"] ?? .null)
        case "error":
            guard let id = object["id"]?.intValue, let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(throwing: RemoteError(message: object["message"]?.stringValue ?? "Pi Bot returned an error."))
        case "bots.changed": onEvent(.botsChanged)
        case "groups.changed": onEvent(.groupsChanged)
        case "threads.changed":
            if let botID = object["botId"]?.stringValue { onEvent(.threadsChanged(botID: botID)) }
        case "memory.changed":
            if let botID = object["botId"]?.stringValue { onEvent(.memoryChanged(botID: botID)) }
        case "event":
            if let botID = object["botId"]?.stringValue, let conversationID = object["conversationId"]?.intValue,
               let event = object["event"].flatMap(PiBotStreamEvent.init(json:)) {
                onEvent(.conversation(botID: botID, conversationID: conversationID, event))
            }
        case "login":
            if let loginID = object["loginId"]?.stringValue, let event = object["event"].flatMap(PiBotLoginEvent.init(json:)) {
                onEvent(.login(loginID: loginID, event))
            }
        default: break
        }
    }

    private func call(_ type: String, _ fields: [String: GatewayJSONValue] = [:], timeout: Duration = .seconds(30)) async throws -> GatewayJSONValue {
        guard let socket = task, state == .open else { throw RemoteError(message: "Pi Bot is not connected.") }
        let id = nextID
        nextID += 1
        var body = fields
        body["id"] = .number(Double(id))
        body["type"] = .string(type)
        let text = String(decoding: try JSONEncoder().encode(GatewayJSONValue.object(body)), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await socket.send(.string(text)) }
                catch { self.resolveFailure(id: id, error) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.resolveFailure(id: id, RemoteError(message: "\(type) timed out."))
            }
        }
    }

    private func resolveFailure(id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func decode<T: Decodable>(_ value: GatewayJSONValue, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private struct BotsResult: Decodable { let bots: [PiBotSummary] }
    private struct BotResult: Decodable { let bot: PiBotSummary }
    private struct ThreadsResult: Decodable { let threads: [PiBotThread] }
    private struct GroupsResult: Decodable { let groups: [PiBotGroup] }
    private struct GroupResult: Decodable { let group: PiBotGroup }
    private struct ThreadResult: Decodable { let thread: PiBotThread }
    private struct DeletedResult: Decodable { let bots: [PiBotDeletedBot] }
    private struct RestoredResult: Decodable { let restored: Bool; let bot: PiBotSummary? }
    private struct FactsResult: Decodable { let facts: [String] }
    private struct NotesResult: Decodable { let notes: String }
    private struct LoginResult: Decodable { let loginId: String }
    private struct RolesResult: Decodable { let roles: PiBotRoles }
    private struct SshKeyResult: Decodable { let sshKey: PiBotSshKey }

    public func bots() async throws -> [PiBotSummary] { try decode(try await call("bots.list"), as: BotsResult.self).bots }
    public func threads(botID: String) async throws -> [PiBotThread] {
        try decode(try await call("threads.list", ["botId": .string(botID)]), as: ThreadsResult.self).threads
    }
    public func groups() async throws -> [PiBotGroup] { try decode(try await call("groups.list"), as: GroupsResult.self).groups }
    @discardableResult public func createBot(name: String) async throws -> PiBotSummary {
        try decode(try await call("bots.create", ["name": .string(name)]), as: BotResult.self).bot
    }
    public func renameBot(id: String, name: String) async throws {
        _ = try await call("bots.rename", ["botId": .string(id), "name": .string(name)])
    }
    public func deleteBot(id: String) async throws { _ = try await call("bots.delete", ["botId": .string(id)]) }
    public func setPinned(botID: String, conversationID: Int, pinned: Bool) async throws {
        _ = try await call("thread.setPinned", ["botId": .string(botID), "conversationId": .number(Double(conversationID)), "pinned": .bool(pinned)])
    }
    @discardableResult public func createGroup(name: String) async throws -> PiBotGroup {
        try decode(try await call("groups.create", ["name": .string(name)]), as: GroupResult.self).group
    }
    public func renameGroup(id: String, name: String) async throws {
        _ = try await call("groups.rename", ["groupId": .string(id), "name": .string(name)])
    }
    public func deleteGroup(id: String) async throws { _ = try await call("groups.delete", ["groupId": .string(id)]) }
    public func reorderGroups(ids: [String]) async throws {
        _ = try await call("groups.reorder", ["groupIds": .array(ids.map(GatewayJSONValue.string))])
    }
    public func setGroup(botID: String, groupID: String?) async throws {
        _ = try await call("bots.setGroup", ["botId": .string(botID), "groupId": groupID.map(GatewayJSONValue.string) ?? .null])
    }
    public func wovenStatus() async throws -> PiBotWovenStatus { try decode(try await call("woven.status")) }
    public func wovenConnect(endpointURL: String, bearerToken: String) async throws -> PiBotWovenStatus {
        try decode(try await call("woven.connect", ["endpointURL": .string(endpointURL), "bearerToken": .string(bearerToken)]))
    }
    public func wovenDisconnect() async throws -> PiBotWovenStatus { try decode(try await call("woven.disconnect")) }
    /// `deliveryID` makes a retry after a lost acknowledgement safe. `context` is what is open
    /// beside the bot right now, for this message only.
    public func send(botID: String, conversationID: Int? = nil, text: String, context: String? = nil, deliveryID: String? = nil) async throws {
        var fields: [String: GatewayJSONValue] = ["botId": .string(botID), "text": .string(text)]
        if let conversationID { fields["conversationId"] = .number(Double(conversationID)) }
        if let context { fields["context"] = .string(context) }
        if let deliveryID { fields["deliveryId"] = .string(deliveryID) }
        _ = try await call("message.send", fields)
    }

    // MARK: Conversations

    public func openConversation(botID: String, conversationID: Int?) async throws -> PiBotConversationSnapshot {
        var fields: [String: GatewayJSONValue] = ["botId": .string(botID)]
        if let conversationID { fields["conversationId"] = .number(Double(conversationID)) }
        return try decode(try await call("conversation.open", fields))
    }
    public func closeConversation(botID: String, conversationID: Int, subscriptionID: GatewayJSONValue?) async throws {
        var fields: [String: GatewayJSONValue] = ["botId": .string(botID), "conversationId": .number(Double(conversationID))]
        if let subscriptionID { fields["subscriptionId"] = subscriptionID }
        _ = try await call("conversation.close", fields)
    }
    /// Stops the running reply and drops queued follow-ups; resolves once the conversation is idle.
    public func abort(botID: String, conversationID: Int) async throws {
        _ = try await call("conversation.abort", ["botId": .string(botID), "conversationId": .number(Double(conversationID))], timeout: .seconds(120))
    }
    public func forkThread(botID: String, conversationID: Int, entryID: Int) async throws -> PiBotThread {
        try decode(try await call("thread.fork", [
            "botId": .string(botID), "conversationId": .number(Double(conversationID)), "entryId": .number(Double(entryID)),
        ]), as: ThreadResult.self).thread
    }

    // MARK: Onboarding and accounts

    public func onboardingStatus() async throws -> PiBotOnboardingStatus { try decode(try await call("onboarding.status")) }
    public func setOnboardingMainModel(_ model: String) async throws { _ = try await call("onboarding.setMainModel", ["model": .string(model)]) }
    public func accounts() async throws -> PiBotAccountsResult { try decode(try await call("settings.accounts")) }
    public func setCredential(accountID: String, key: String) async throws {
        _ = try await call("credentials.set", ["accountId": .string(accountID), "key": .string(key)])
    }
    public func removeCredential(accountID: String) async throws { _ = try await call("credentials.remove", ["accountId": .string(accountID)]) }
    public func startLogin(accountID: String, method: String? = nil) async throws -> String {
        var fields: [String: GatewayJSONValue] = ["accountId": .string(accountID)]
        if let method { fields["method"] = .string(method) }
        return try decode(try await call("login.start", fields), as: LoginResult.self).loginId
    }
    public func respondToLogin(loginID: String, promptID: String, value: String) async throws {
        _ = try await call("login.respond", ["loginId": .string(loginID), "promptId": .string(promptID), "value": .string(value)])
    }
    public func cancelLogin(loginID: String) async throws { _ = try await call("login.cancel", ["loginId": .string(loginID)]) }
    public func accountNotes() async throws -> String { try decode(try await call("account.notes"), as: NotesResult.self).notes }
    public func setAccountNotes(_ notes: String) async throws { _ = try await call("account.setNotes", ["notes": .string(notes)]) }

    // MARK: Models and profiles

    public func modelCatalog() async throws -> PiBotModelCatalog { try decode(try await call("models.catalog")) }
    public func setRoles(_ roles: PiBotRoles) async throws -> PiBotRoles {
        try decode(try await call("models.setRoles", ["titles": .string(roles.titles), "titlesReasoning": .string(roles.titlesReasoning)]), as: RolesResult.self).roles
    }
    public func profiles() async throws -> PiBotProfilesList { try decode(try await call("profiles.list")) }
    public func saveProfile(_ draft: PiBotProfileDraft, create: Bool) async throws -> PiBotProfilesList {
        try decode(try await call("profiles.save", ["create": .bool(create), "profile": draft.wire]))
    }
    public func deleteProfile(id: String) async throws -> PiBotProfilesList { try decode(try await call("profiles.delete", ["profileId": .string(id)])) }
    public func setDefaultProfile(id: String) async throws -> PiBotProfilesList { try decode(try await call("profiles.setDefault", ["profileId": .string(id)])) }

    // MARK: Roles, teams, and deleted bots

    public func setProfile(botID: String, profileID: String?) async throws {
        _ = try await call("bots.setProfile", ["botId": .string(botID), "profileId": profileID.map(GatewayJSONValue.string) ?? .null])
    }
    public func setManager(botID: String, manager: Bool) async throws {
        _ = try await call("bots.setManager", ["botId": .string(botID), "manager": .bool(manager)])
    }
    public func setTeam(botID: String, managerID: String?) async throws {
        _ = try await call("bots.setTeam", ["botId": .string(botID), "managerId": managerID.map(GatewayJSONValue.string) ?? .null])
    }
    public func setOrchestrator(botID: String?) async throws {
        _ = try await call("bots.setOrchestrator", ["botId": botID.map(GatewayJSONValue.string) ?? .null])
    }
    public func replaceManager(managerID: String, newManagerID: String) async throws {
        _ = try await call("bots.replaceManager", ["managerId": .string(managerID), "newManagerId": .string(newManagerID)])
    }
    public func deletedBots() async throws -> [PiBotDeletedBot] { try decode(try await call("bots.listDeleted"), as: DeletedResult.self).bots }
    /// The restored bot, or nil when the server could not restore it.
    @discardableResult public func restoreBot(id: String) async throws -> PiBotSummary? {
        let result = try decode(try await call("bots.restore", ["botId": .string(id)]), as: RestoredResult.self)
        return result.restored ? result.bot : nil
    }
    /// Removing a bot's container and workspace can take a while.
    public func purgeBot(id: String) async throws -> PiBotPurgeResult {
        try decode(try await call("bots.purge", ["botId": .string(id)], timeout: .seconds(180)))
    }

    // MARK: Memory

    public func memory(botID: String) async throws -> [String] { try decode(try await call("memory.list", ["botId": .string(botID)]), as: FactsResult.self).facts }
    public func addMemory(botID: String, text: String) async throws -> [String] {
        try decode(try await call("memory.add", ["botId": .string(botID), "text": .string(text)]), as: FactsResult.self).facts
    }
    public func updateMemory(botID: String, fact: String, text: String) async throws -> [String] {
        try decode(try await call("memory.update", ["botId": .string(botID), "fact": .string(fact), "text": .string(text)]), as: FactsResult.self).facts
    }
    public func deleteMemory(botID: String, fact: String) async throws -> [String] {
        try decode(try await call("memory.delete", ["botId": .string(botID), "fact": .string(fact)]), as: FactsResult.self).facts
    }

    // MARK: Config and server

    public func config() async throws -> PiBotConfigDocument { try decode(try await call("config.get")) }
    public func validateConfig(text: String) async throws -> PiBotConfigValidation { try decode(try await call("config.validate", ["text": .string(text)])) }
    public func saveConfig(text: String, baseRevision: String?) async throws {
        var fields: [String: GatewayJSONValue] = ["text": .string(text)]
        if let baseRevision { fields["baseRevision"] = .string(baseRevision) }
        _ = try await call("config.save", fields)
    }
    public func updateConfig(edits: [PiBotConfigEdit]) async throws { _ = try await call("config.update", ["edits": .array(edits.map(\.wire))]) }
    public func restartServer() async throws -> PiBotRestart { try decode(try await call("server.restart")) }

    // MARK: GitHub

    public func github() async throws -> PiBotGitHubStatus { try decode(try await call("github.get")) }
    public func setSSHKey(privateKey: String) async throws { _ = try await call("github.setSshKey", ["privateKey": .string(privateKey)]) }
    public func generateSSHKey(comment: String) async throws { _ = try await call("github.generateSshKey", ["comment": .string(comment)]) }
    public func removeSSHKey() async throws { _ = try await call("github.removeSshKey") }
    public func setGitIdentity(name: String, email: String) async throws {
        _ = try await call("github.setIdentity", ["name": .string(name), "email": .string(email)])
    }
}

private struct PiBotHello: Decodable {
    let version: String
    let `protocol`: Int?
    let installationId: String?
    let capabilities: [String]?
}
