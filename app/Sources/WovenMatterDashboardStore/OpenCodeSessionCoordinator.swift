import Foundation
import WovenMatterClient
import WovenMatterCore

public struct OpenCodeSessionUpdate: Sendable {
    public let conversationID: String
    public let snapshot: OpenCodeSessionSnapshot?
    public let status: String
    public let error: String?
}

public actor OpenCodeSessionCoordinator {
    public nonisolated let updates: AsyncStream<OpenCodeSessionUpdate>
    private let continuation: AsyncStream<OpenCodeSessionUpdate>.Continuation
    private let database: WorkspaceDatabase
    private let clientFactory: @Sendable (OpenCodeConnection) -> OpenCodeHTTPClient
    private var clients: [String: OpenCodeHTTPClient] = [:]
    private var connectionTokens: [String: UUID] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var snapshots: [String: OpenCodeSessionSnapshot] = [:]
    private var pendingCursors: [String: Int64] = [:]
    private var eventRefreshes: [String: Task<Void, Never>] = [:]
    private var eventRefreshTokens: [String: UUID] = [:]
    private var eventRefreshDirty: Set<String> = []
    private var refreshing: Set<String> = []
    private var sending: Set<String> = []

    public init(database: WorkspaceDatabase, clientFactory: @escaping @Sendable (OpenCodeConnection) -> OpenCodeHTTPClient = { OpenCodeHTTPClient(connection: $0) }) {
        self.clientFactory = clientFactory
        self.database = database
        let stream = AsyncStream<OpenCodeSessionUpdate>.makeStream(bufferingPolicy: .bufferingNewest(256))
        updates = stream.stream; continuation = stream.continuation
    }
    public func connect(_ connection: OpenCodeConnection) async throws {
        let token = UUID(); connectionTokens[connection.identity] = token
        let client = clientFactory(connection).recording(database.openCodeHistoryRecorder(connectionID: connection.identity))
        _ = try await client.health()
        try Task.checkCancellation()
        guard connectionTokens[connection.identity] == token else { throw CancellationError() }
        clients[connection.identity] = client
    }
    public func disconnect(connectionID: String) {
        connectionTokens.removeValue(forKey: connectionID)
        for link in (try? database.openCodeLinks()) ?? [] where link.connectionID == connectionID {
            workers.removeValue(forKey: link.conversationID)?.cancel()
            eventRefreshes.removeValue(forKey: link.conversationID)?.cancel()
            eventRefreshTokens.removeValue(forKey: link.conversationID)
            eventRefreshDirty.remove(link.conversationID)
            generations.removeValue(forKey: link.conversationID)
            pendingCursors.removeValue(forKey: link.conversationID)
            emit(link.conversationID, status: "Disconnected")
        }
        clients.removeValue(forKey: connectionID)
    }
    public func shutdown() { workers.values.forEach { $0.cancel() }; eventRefreshes.values.forEach { $0.cancel() }; workers.removeAll(); eventRefreshes.removeAll(); eventRefreshTokens.removeAll(); eventRefreshDirty.removeAll(); generations.removeAll(); clients.removeAll(); connectionTokens.removeAll(); pendingCursors.removeAll() }
    public func call(connectionID: String, method: String = "GET", path: String,
                     query: [String: String] = [:], body: OpenCodeValue? = nil) async throws -> OpenCodeValue {
        guard let client = clients[connectionID] else { throw OpenCodeError.message("Connect to the OpenCode service first.") }
        let token = connectionTokens[connectionID]
        let result = try await client.call(method, path, query: query, body: body)
        guard token == connectionTokens[connectionID] else { throw CancellationError() }
        return result
    }
    public func createSession(connectionID: String, id: String, workspace: URL, recover: Bool, title: String? = nil, nativeWorkspaceID: String? = nil) async throws -> OpenCodeValue {
        if recover {
            do { return try await call(connectionID: connectionID, path: "/api/session/" + OpenCodeHTTPClient.segment(id)) }
            catch OpenCodeError.http(404) {
                // Creation is idempotent by session ID in the native service.
                // Reuse that ID even if the first request is still finishing.
            }
        }
        var body: OpenCodeValue = ["id": .string(id), "location": ["directory": .string(workspace.path)], "metadata": ["wovenmatter": ["origin": "created"]]]
        if let nativeWorkspaceID { body["location"] = ["directory": .string(workspace.path), "workspaceID": .string(nativeWorkspaceID)] }
        if let title { body["title"] = .string(title) }
        return try await call(connectionID: connectionID, method: "POST", path: "/api/session", body: body)
    }
    /// A successful write is insufficient: the service must report the requested
    /// selection before session creation or its first instruction can continue.
    public func configureSelection(_ link: OpenCodeSessionLink, selection: OpenCodeValue) async throws -> OpenCodeValue {
        let path = "/api/session/" + OpenCodeHTTPClient.segment(link.sessionID)
        _ = try await call(connectionID: link.connectionID, method: "POST", path: path + "/model", body: selection)
        let confirmed = try await call(connectionID: link.connectionID, path: path)
        guard OpenCodeComposerMetadata.matchesSelection(confirmed["data"]["model"], selection["model"]) else {
            throw OpenCodeError.message("OpenCode has not confirmed the selected model. Select it again before sending.")
        }
        return confirmed["data"]
    }

    public func importableSessions(connectionID: String, cursor: String? = nil) async throws -> (sessions: [OpenCodeValue], next: String?) {
        guard let client = clients[connectionID] else { throw OpenCodeError.message("Connect to OpenCode first.") }
        let token = connectionTokens[connectionID]
        var excluded = try database.knownOpenCodeSessionIDs(connectionID: connectionID)
        var result: [OpenCodeValue] = []
        var next = cursor
        var visited: Set<String> = []
        repeat {
            var query = ["limit": String(25 - result.count)]
            if let next {
                guard visited.insert(next).inserted else { throw OpenCodeError.message("OpenCode returned a repeated session cursor.") }
                query["cursor"] = next
            } else { query["order"] = "desc" }
            let page = try await client.call("GET", "/api/session", query: query)
            try Task.checkCancellation()
            guard token == connectionTokens[connectionID] else { throw CancellationError() }
            guard case .array(let rows) = page["data"] else { throw OpenCodeError.message("OpenCode returned an invalid session page.") }
            for session in rows {
                let id = session["id"].text
                if !id.isEmpty, session["metadata"]["wovenmatter"]["origin"].text != "created", excluded.insert(id).inserted { result.append(session) }
            }
            next = page["data"].array.isEmpty ? nil : page["cursor"]["next"].string
        } while result.count < 25 && next != nil
        return (result, next)
    }

    public func completeImportSnapshot(connectionID: String, sessionID: String) async throws -> OpenCodeSessionSnapshot {
        guard let client = clients[connectionID] else { throw OpenCodeError.message("Connect to OpenCode first.") }
        let token = connectionTokens[connectionID]
        let path = "/api/session/" + OpenCodeHTTPClient.segment(sessionID)
        let info = try await client.call("GET", path)["data"]
        guard info["metadata"]["wovenmatter"]["origin"].text != "created",
              !(try database.knownOpenCodeSessionIDs(connectionID: connectionID)).contains(sessionID) else {
            throw OpenCodeError.message("This session is already in Woven Matter. Refresh the list.")
        }
        guard info["id"].text == sessionID, !info["location"]["directory"].text.isEmpty else {
            throw OpenCodeError.message("OpenCode did not return the session's original directory.")
        }
        var snapshot = OpenCodeSessionSnapshot()
        snapshot.info = info
        var descending: [OpenCodeValue] = []
        var cursor: String?
        var visited: Set<String> = []
        repeat {
            var query = ["limit": "100"]
            if let cursor {
                guard visited.insert(cursor).inserted else { throw OpenCodeError.message("OpenCode returned a repeated history cursor.") }
                query["cursor"] = cursor
            } else { query["order"] = "desc" }
            let page = try await client.call("GET", path + "/message", query: query)
            try Task.checkCancellation()
            guard token == connectionTokens[connectionID] else { throw CancellationError() }
            guard case .array(let messages) = page["data"], messages.allSatisfy({ !$0["id"].text.isEmpty }) else {
                throw OpenCodeError.message("OpenCode returned an incomplete history page.")
            }
            descending += messages
            cursor = messages.isEmpty ? nil : page["cursor"]["next"].string
        } while cursor != nil
        let latest = try await client.call("GET", path)["data"]
        guard token == connectionTokens[connectionID], latest == info else {
            throw OpenCodeError.message("This session changed during import. Please import it again.")
        }
        snapshot.mergeMessages(Array(descending.reversed()), replace: true)
        snapshot.olderCursor = nil
        return snapshot
    }

    public func readFile(connectionID: String, path: String, query: [String: String]) async throws -> (Data, String) {
        guard let client = clients[connectionID] else { throw OpenCodeError.message("OpenCode is disconnected.") }
        return try await client.readFile(path: path, query: query)
    }
    public func watch(_ link: OpenCodeSessionLink) {
        guard workers[link.conversationID] == nil, clients[link.connectionID] != nil else { return }
        snapshots[link.conversationID] = (try? database.openCodeSnapshot(conversationID: link.conversationID)) ?? OpenCodeSessionSnapshot()
        let generation = UUID(); generations[link.conversationID] = generation
        workers[link.conversationID] = Task { await self.follow(link, generation: generation) }
    }
    private func follow(_ link: OpenCodeSessionLink, generation: UUID) async {
        var failures = 0
        while !Task.isCancelled && generations[link.conversationID] == generation {
            let connectedAt = ContinuousClock.now
            do {
                guard var client = clients[link.connectionID] else { return }
                let token = connectionTokens[link.connectionID]
                if let registration = client.connection.registration {
                    client = clientFactory(try .discover(file: registration))
                    _ = try await client.health()
                    try Task.checkCancellation()
                    guard generations[link.conversationID] == generation, token == connectionTokens[link.connectionID] else { continue }
                    clients[link.connectionID] = client
                } else { _ = try await client.health() }
                try await refresh(link, generation: generation, recoverHistory: true)
                emit(link.conversationID, status: "Connected")
                let after = snapshots[link.conversationID]?.cursor
                var query = ["follow": "true"]
                if let after { query["after"] = String(after) }
                let streamClient = client, streamQuery = query
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await streamClient.events("/api/experimental/session/\(OpenCodeHTTPClient.segment(link.sessionID))/log", query: streamQuery) { event in
                            await self.logEvent(event, link: link, generation: generation)
                        }
                        throw OpenCodeError.message("OpenCode event connection ended.")
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            // Durable events trigger a coalesced authoritative
                            // refresh. Polling remains a low-frequency repair path.
                            try await Task.sleep(for: .milliseconds(2500))
                            try await self.refresh(link, generation: generation)
                        }
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } catch {
                guard !Task.isCancelled, generations[link.conversationID] == generation else { return }
                if error is CancellationError { continue }
                if case OpenCodeError.incompatible = error { emit(link.conversationID, status: "Unsupported version", error: error.localizedDescription); break }
                if case OpenCodeError.http(401) = error { emit(link.conversationID, status: "Authentication required", error: error.localizedDescription); break }
                if case OpenCodeError.http(404) = error { emit(link.conversationID, status: "Session unavailable", error: error.localizedDescription); break }
                emit(link.conversationID, status: "Reconnecting", error: error.localizedDescription)
                if connectedAt.duration(to: .now) > .seconds(30) { failures = 0 }
                failures = min(failures + 1, 6)
                do { try await Task.sleep(for: .seconds(min(30, pow(2, Double(failures - 1))))) }
                catch { return }
            }
        }
        if generations[link.conversationID] == generation { workers.removeValue(forKey: link.conversationID) }
    }
    private func logEvent(_ event: OpenCodeValue, link: OpenCodeSessionLink, generation: UUID) {
        guard generations[link.conversationID] == generation else { return }
        if let seq = event["durable"]["seq"].number ?? event["seq"].number,
           seq >= 0, seq <= 9_007_199_254_740_991, seq.rounded() == seq {
            let cursor = Int64(seq)
            guard cursor > (snapshots[link.conversationID]?.cursor ?? -1) else { return }
            pendingCursors[link.conversationID] = max(pendingCursors[link.conversationID] ?? -1, cursor)
        }
        let terminal = ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted",
                        "session.step.ended", "session.step.failed", "session.revert.committed"].contains(event["type"].text)
        eventRefreshDirty.insert(link.conversationID)
        guard eventRefreshes[link.conversationID] == nil else { return }
        scheduleEventRefresh(link, generation: generation, delay: !terminal)
    }
    func receiveLogEvent(_ event: OpenCodeValue, link: OpenCodeSessionLink) {
        if generations[link.conversationID] == nil {
            snapshots[link.conversationID] = (try? database.openCodeSnapshot(conversationID: link.conversationID)) ?? OpenCodeSessionSnapshot()
            generations[link.conversationID] = UUID()
        }
        guard let generation = generations[link.conversationID] else { return }
        logEvent(event, link: link, generation: generation)
    }
    private func scheduleEventRefresh(_ link: OpenCodeSessionLink, generation: UUID, delay: Bool = false) {
        guard eventRefreshes[link.conversationID] == nil else { return }
        let token = UUID()
        eventRefreshTokens[link.conversationID] = token
        eventRefreshes[link.conversationID] = Task {
            do {
                if delay { try await Task.sleep(for: .milliseconds(75)) }
                while self.eventRefreshDirty.remove(link.conversationID) != nil {
                    try await self.refresh(link, generation: generation)
                }
            } catch is CancellationError {
            } catch { self.emit(link.conversationID, status: "Reconnecting", error: error.localizedDescription) }
            guard self.eventRefreshTokens[link.conversationID] == token else { return }
            self.eventRefreshes[link.conversationID] = nil; self.eventRefreshTokens[link.conversationID] = nil
            if self.eventRefreshDirty.contains(link.conversationID) { self.scheduleEventRefresh(link, generation: generation) }
        }
    }
    public func refresh(_ link: OpenCodeSessionLink, generation: UUID? = nil, recoverHistory: Bool = false) async throws {
        let token = connectionTokens[link.connectionID]
        let capturedGeneration = generation ?? generations[link.conversationID]
        // History loads and refreshes share a lock so neither can overwrite
        // pages committed by the other while awaiting form state or pagination.
        // A post-mutation refresh must not be skipped behind an older snapshot.
        while refreshing.contains(link.conversationID) {
            try await Task.sleep(for: .milliseconds(25))
        }
        refreshing.insert(link.conversationID)
        defer { refreshing.remove(link.conversationID) }
        guard let client = clients[link.connectionID] else { throw OpenCodeError.message("OpenCode is disconnected.") }
        guard token != nil, token == connectionTokens[link.connectionID],
              capturedGeneration == generations[link.conversationID] else { throw CancellationError() }
        let acknowledged = pendingCursors[link.conversationID]
        let path = "/api/session/" + OpenCodeHTTPClient.segment(link.sessionID)
        async let info = client.call("GET", path)
        async let messages = client.call("GET", path + "/message", query: ["limit": "100", "order": "desc"])
        async let permissions = client.call("GET", path + "/permission")
        async let forms = client.call("GET", path + "/form")
        async let inbox = client.call("GET", path + "/inbox")
        async let active = client.call("GET", "/api/session/active")
        let responses = try await (info, messages, permissions, forms, inbox, active)
        try Task.checkCancellation()
        guard capturedGeneration == generations[link.conversationID], token == connectionTokens[link.connectionID] else { throw CancellationError() }
        var snapshot = snapshots[link.conversationID] ?? OpenCodeSessionSnapshot()
        snapshot.info = responses.0["data"]
        guard snapshot.info["id"].text == link.sessionID else { throw OpenCodeError.message("OpenCode returned a different session identity.") }
        // Continue through every missed page until the existing projection is
        // reached. A reconnect also refreshes all pages already held locally.
        let knownIDs = Set(snapshot.messages.map { $0["id"].text })
        let oldestKnownID = snapshot.messages.first?["id"].text
        var descending = responses.1["data"].array
        var cursor = descending.count == 100 ? responses.1["cursor"]["next"].string : nil
        var visited: Set<String> = []
        while let next = cursor,
              (!knownIDs.isEmpty && !descending.contains(where: { knownIDs.contains($0["id"].text) })
               || recoverHistory && oldestKnownID != nil && !descending.contains(where: { $0["id"].text == oldestKnownID })) {
            guard visited.insert(next).inserted else { throw OpenCodeError.message("OpenCode returned a repeated history cursor.") }
            let page = try await client.call("GET", path + "/message", query: ["limit": "100", "cursor": next])
            descending += page["data"].array
            cursor = page["data"].array.count == 100 ? page["cursor"]["next"].string : nil
            try Task.checkCancellation()
        }
        let incomingIDs = Set(descending.map { $0["id"].text })
        // Once the server's entire history has been read, it is authoritative.
        // Retaining a cached prefix here would resurrect removed first messages.
        let reachedHistoryStart = cursor == nil
        // The beta returns a next cursor for every nonempty page, including
        // the final page. Keep a previously established end of history.
        if snapshot.olderCursor == nil, let oldestKnownID, incomingIDs.contains(oldestKnownID) { cursor = nil }
        let keepsOlderPrefix = !reachedHistoryStart && (snapshot.messages.firstIndex { incomingIDs.contains($0["id"].text) } ?? 0) > 0
        snapshot.mergeMessages(Array(descending.reversed()), replace: reachedHistoryStart)
        if !keepsOlderPrefix { snapshot.olderCursor = cursor }
        snapshot.permissions = responses.2["data"].array
        // Session form list includes completed forms; query authoritative state.
        var pendingForms: [OpenCodeValue] = []
        for form in responses.3["data"].array {
            let state = try await client.call("GET", path + "/form/" + OpenCodeHTTPClient.segment(form["id"].text) + "/state")
            if state["data"]["status"].text == "pending" { pendingForms.append(form) }
        }
        snapshot.forms = pendingForms
        snapshot.inbox = responses.4["data"].array
        snapshot.active = !responses.5["data"][link.sessionID].isNull
        if let acknowledged { snapshot.cursor = max(snapshot.cursor ?? -1, acknowledged) }
        try Task.checkCancellation()
        guard capturedGeneration == generations[link.conversationID], token == connectionTokens[link.connectionID] else { throw CancellationError() }
        if snapshots[link.conversationID] != snapshot {
            try database.saveOpenCodeSnapshot(snapshot, conversationID: link.conversationID)
            snapshots[link.conversationID] = snapshot
            emit(link.conversationID, status: "Connected")
        }
        try await reconcileSubmissions(link, client: client, snapshot: snapshot, token: token)
        guard capturedGeneration == generations[link.conversationID], token == connectionTokens[link.connectionID] else { throw CancellationError() }
        emit(link.conversationID, status: "Connected")
    }
    public func loadOlder(_ link: OpenCodeSessionLink) async throws {
        let token = connectionTokens[link.connectionID]
        let generation = generations[link.conversationID]
        while refreshing.contains(link.conversationID) { try await Task.sleep(for: .milliseconds(25)) }
        guard token != nil, token == connectionTokens[link.connectionID], generation == generations[link.conversationID] else { throw CancellationError() }
        refreshing.insert(link.conversationID)
        defer { refreshing.remove(link.conversationID) }
        guard let client = clients[link.connectionID], let cursor = snapshots[link.conversationID]?.olderCursor else { return }
        let page = try await client.call("GET", "/api/session/\(OpenCodeHTTPClient.segment(link.sessionID))/message", query: ["cursor": cursor, "limit": "100"])
        try Task.checkCancellation()
        guard generation == generations[link.conversationID], token == connectionTokens[link.connectionID],
              snapshots[link.conversationID]?.olderCursor == cursor else { return }
        var snapshot = snapshots[link.conversationID] ?? OpenCodeSessionSnapshot()
        snapshot.mergeMessages(Array(page["data"].array.reversed()), older: true)
        snapshot.olderCursor = page["data"].array.count == 100 ? page["cursor"]["next"].string : nil
        try database.saveOpenCodeSnapshot(snapshot, conversationID: link.conversationID)
        snapshots[link.conversationID] = snapshot; emit(link.conversationID, status: "Connected")
    }
    public func prompt(_ link: OpenCodeSessionLink, input: AgentMessageInput, discovery: String? = nil) async throws {
        try await submit(link, input: input, command: nil, discovery: discovery)
    }
    public func command(_ link: OpenCodeSessionLink, name: String, input: AgentMessageInput, discovery: String? = nil) async throws {
        try await submit(link, input: input, command: name, discovery: discovery)
    }
    private func submit(_ link: OpenCodeSessionLink, input: AgentMessageInput, command: String?, discovery: String?) async throws {
        guard sending.insert(link.conversationID).inserted else { throw OpenCodeError.message("The previous input is still being submitted.") }
        defer { sending.remove(link.conversationID) }
        guard let client = clients[link.connectionID] else { throw OpenCodeError.message("Connect to OpenCode before sending input.") }
        guard try database.openCodeUncertainSubmissions(conversationID: link.conversationID).isEmpty else {
            throw OpenCodeError.message("Resolve the uncertain input in session controls before sending another message.")
        }
        let deliveryText = (discovery.map { $0 + "\n\n" } ?? "") + input.textWithReferenceContext
        let id = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var files: [OpenCodeValue] = []
        for file in input.files {
            let bytes = try Data(contentsOf: file.localURL)
            guard bytes.count <= AgentMessageAttachmentLimits.maximumFileBytes else { throw OpenCodeError.message("Attachment exceeds Woven Matter's size limit.") }
            files.append(["uri": .string("data:\(file.mimeType);base64," + bytes.base64EncodedString()), "name": .string(file.fileName)])
        }
        if let command {
            // Native commands return 204 and do not accept a caller message ID.
            // Never journal or retry them as idempotent prompt submissions.
            var commandPayload: [String: OpenCodeValue] = ["command": .string(command),
                "text": .string(deliveryText), "files": .array(files)]
            if input.historyDeliveryID != nil { commandPayload["delivery"] = .string("steer") }
            let payload = OpenCodeValue.object(commandPayload)
            if let deliveryID = input.historyDeliveryID {
                try database.markToolDeliveryTransportStarted(id: deliveryID, targetID: link.conversationID, nativeCommand: command)
            }
            do {
                _ = try await client.call("POST", "/api/session/\(OpenCodeHTTPClient.segment(link.sessionID))/command", body: payload)
            } catch {
                if case OpenCodeError.http(let code) = error, [400, 401, 403, 404, 422].contains(code) {
                    if let deliveryID = input.historyDeliveryID { try database.setToolDeliveryStatus(id: deliveryID, status: "failed") }
                    throw error
                }
                try? await refresh(link)
                throw OpenCodeError.message("OpenCode did not confirm the command outcome. Check the session before running it again; Woven Matter has not retried it.")
            }
            if let deliveryID = input.historyDeliveryID { try database.setToolDeliveryStatus(id: deliveryID, status: "accepted") }
            try? await refresh(link)
            return
        }
        var promptPayload: [String: OpenCodeValue] = ["id": .string(id), "text": .string(deliveryText), "files": .array(files)]
        if input.historyDeliveryID != nil { promptPayload["delivery"] = .string("steer") }
        let payload = OpenCodeValue.object(promptPayload)
        try database.saveOpenCodeSubmission(conversationID: link.conversationID, id: id, payload: payload, status: "sending", visibleText: input.text, deliveryID: input.historyDeliveryID)
        do {
            let result = try await client.call("POST", "/api/session/\(OpenCodeHTTPClient.segment(link.sessionID))/prompt", body: payload)
            guard result["data"]["id"].text == id else { throw OpenCodeError.uncertain(id) }
            try database.saveOpenCodeSubmission(conversationID: link.conversationID, id: id, payload: payload, status: "accepted")
        } catch {
            if case OpenCodeError.http(let code) = error, [400, 401, 403, 404, 422].contains(code) {
                try database.saveOpenCodeSubmission(conversationID: link.conversationID, id: id, payload: payload, status: "rejected")
                if let deliveryID = input.historyDeliveryID { try database.setToolDeliveryStatus(id: deliveryID, status: "failed") }
                throw error
            }
            try database.saveOpenCodeSubmission(conversationID: link.conversationID, id: id, payload: payload, status: "uncertain")
            try? await refresh(link)
            if try database.openCodeUncertainSubmissions(conversationID: link.conversationID).isEmpty { return }
            throw OpenCodeError.uncertain(id)
        }
        try? await refresh(link)
    }
    private func reconcileSubmissions(_ link: OpenCodeSessionLink, client: OpenCodeHTTPClient, snapshot: OpenCodeSessionSnapshot, token: UUID?) async throws {
        for item in try database.openCodeUncertainSubmissions(conversationID: link.conversationID) {
            let id = item["id"].text
            var accepted = snapshot.containsInput(id)
            if !accepted {
                let message = try? await client.call("GET", "/api/session/\(OpenCodeHTTPClient.segment(link.sessionID))/message/\(OpenCodeHTTPClient.segment(id))")
                accepted = message?["data"]["id"].text == id
            }
            try Task.checkCancellation()
            guard token == connectionTokens[link.connectionID] else { throw CancellationError() }
            if accepted { try database.saveOpenCodeSubmission(conversationID: link.conversationID, id: id, payload: item["payload"], status: "accepted") }
        }
    }
    private func emit(_ id: String, status: String, error: String? = nil) {
        continuation.yield(OpenCodeSessionUpdate(conversationID: id, snapshot: snapshots[id], status: status, error: error))
    }
}
