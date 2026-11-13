import Foundation
import LibraryClient
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

/// Where an agent's `woven_sessions_create` lands. Workspaces are named by ID:
/// this Mac's own, a Linux host this Mac added that is not enrolled in the
/// library yet, or another member's workspace (a paired Mac or any enrolled
/// Linux host). Every one but this Mac is reached through its own server with
/// member-signed requests and its stream; SSH only installs and repairs a host.
/// The iPhone is never a destination; it runs only its own Quick Chats.
enum AgentToolDestination: Equatable {
    case thisMac
    case configured(UUID)
    case member(ExecutionWorkspace)
}

extension ApplicationModel {
    /// Every execution workspace agents may target, this Mac's first. A copied
    /// snapshot owner (`retainedHistory`) is history, never a destination, as
    /// on the iPhone.
    func agentToolWorkspaces() async throws -> (own: ExecutionWorkspace?, others: [ExecutionWorkspace]) {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let device = try await database.libraryIdentity().hostDeviceID
        let all = try await database.libraryExecutionWorkspaces().filter { !$0.deleted && $0.kind != .ios && $0.retainedHistory != true }
        let own = all.first { $0.kind == .mac && $0.executionDeviceID == device }
        let others = all.filter { $0.id != own?.id }.sorted {
            ($0.kind == .mac ? 0 : 1, $0.name.lowercased()) < ($1.kind == .mac ? 0 : 1, $1.name.lowercased())
        }
        return (own, others)
    }

    func resolveAgentToolDestination(_ raw: String?, callerWorkspace: UUID?) async throws -> AgentToolDestination {
        guard let raw else { return callerWorkspace.map(AgentToolDestination.configured) ?? .thisMac }
        let (own, others) = try await agentToolWorkspaces()
        let id = raw.lowercased()
        if let own, id == own.id { return .thisMac }
        // A Linux host this Mac added is a member like any other once it is enrolled.
        if let uuid = UUID(uuidString: id), remoteWorkspaces.configuration(id: uuid) != nil, !others.contains(where: { $0.id == id }) { return .configured(uuid) }
        if let member = others.first(where: { $0.id == id }) { return .member(member) }
        if let database = dashboardStore?.database,
           let named = try await database.libraryExecutionWorkspaces().first(where: { $0.id == id && !$0.deleted }) {
            if named.kind == .ios { throw WorkspaceToolError.invalid("An iPhone or iPad runs only its own Quick Chats. Choose a Mac or Linux workspace.") }
            if named.retainedHistory == true { throw WorkspaceToolError.invalid("\(named.name) is copied history in this snapshot and runs no sessions. Choose a Mac or Linux workspace.") }
        }
        let valid = ([own].compactMap { $0 } + others).map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
        throw WorkspaceToolError.invalid("Name the destination by workspace ID" + (valid.isEmpty ? "." : ": " + valid + "."))
    }

    /// Creates a session on another member's workspace and sends its first
    /// message. The destination applies its own saved defaults (model,
    /// permission, tools), exactly as for a session its own user starts. IDs
    /// derive from the caller and request, so a retry replays receipts.
    func createMemberToolSession(sourceID: String, requestID: String, workspace: ExecutionWorkspace,
                                 runtime: AgentRuntimeKind, title: String, text: String) async throws -> WovenMatterToolResponse {
        let client = try centralExecutionClient()
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let device = try await database.libraryIdentity().hostDeviceID
        let providers = try await client.providers(workspace: workspace)
        guard let provider = providers.first(where: { $0.runtimeKind == runtime.rawValue && $0.available && $0.canStart }) else {
            let ready = providers.filter { $0.available && $0.canStart }.map(\.runtimeKind)
            throw WorkspaceToolError.invalid("\(runtime.rawValue) is not ready on \(workspace.name)." + (ready.isEmpty ? "" : " Ready: " + ready.joined(separator: ", ") + "."))
        }
        let conversationID = Self.memberToolID(sourceID, requestID, "session")
        func command(_ kind: LibraryCommand.Kind, _ suffix: String, text: String? = nil, action: LibraryWorkspaceAction? = nil) -> LibraryCommand {
            .init(commandID: Self.memberToolID(sourceID, requestID, suffix), deviceID: device, kind: kind, conversationID: conversationID,
                  providerID: kind == .createSession ? provider.id : nil, runtimeKind: kind == .createSession ? runtime.rawValue : nil,
                  text: text, workspaceAction: action, libraryID: workspace.libraryID, workspaceID: workspace.id,
                  title: kind == .createSession ? title : nil)
        }
        _ = try await client.submit(command(.createSession, "create"), workspace: workspace)
        // Remembered so later status, send, stop and respond calls need only the ID.
        try await database.rememberMemberToolSession(id: conversationID, callerID: sourceID, workspaceID: workspace.id)
        _ = try? await client.submit(command(.workspace, "title", action: .conversation(id: conversationID, action: "rename", title: title, folderID: nil)), workspace: workspace)
        let receipt = try await client.submit(command(.send, "send", text: text), workspace: workspace)
        // Watched from now on: it wakes this caller when it finishes or asks a question.
        await observeMemberSession(callerID: sourceID, workspace: workspace, id: conversationID, state: "running",
            response: .init(result: .object(["session": .object(["title": .string(title), "harness": .string(runtime.rawValue)]),
                                             "receipt": .object(receipt.runID.map { ["runID": .string($0)] } ?? [:])])), created: true)
        return .init(result: .object([
            "session": .object(["id": .string(conversationID), "title": .string(title), "harness": .string(runtime.rawValue),
                                "workspace": .string(workspace.id), "workspaceName": .string(workspace.name),
                                "workspaceKind": .string(workspace.kind.rawValue)]),
            "receipt": .object(["commandID": .string(receipt.commandID), "status": .string(receipt.status.rawValue)]),
            // Sessions on other devices are not coordinated from here; their
            // history reaches this library as they run.
            "independent": .bool(true),
            "note": .string("Manage it with woven_sessions_status (state, pending questions and recent transcript), woven_sessions_send, woven_sessions_stop and woven_sessions_respond. It is not coordinated: wait for it with woven_sessions_wait, and you are woken with a short message when it finishes or asks a question while you are idle.")
        ]))
    }

    /// `woven_sessions_harnesses`: this Mac (its real workspace ID and name),
    /// then paired Macs, then Linux workspaces. A member that cannot be
    /// reached is listed once with `online: false`.
    func agentToolHarnessRows() async throws -> [JSONValue] {
        let (own, others) = try await agentToolWorkspaces()
        var rows: [JSONValue] = LocalACPRuntimeCatalog.definitions.map {
            .object(["harness": .string($0.runtimeKind.rawValue), "workspace": own.map { .string($0.id) } ?? .null,
                     "workspaceName": .string(own?.name ?? DevelopmentLaunch.deviceName()), "workspaceKind": .string("mac"),
                     "ready": .bool(isLocalACPAgentReady($0.runtimeKind))])
        }
        let configured = Set(remoteWorkspaces.workspaces.map { $0.id.uuidString.lowercased() })
        for workspace in others {
            if workspace.kind == .linux, let uuid = UUID(uuidString: workspace.id), configured.contains(workspace.id),
               let configuration = remoteWorkspaces.configuration(id: uuid) {
                rows += (remoteWorkspaces.harnesses[uuid] ?? []).map { harness in
                    .object(["harness": .string(harness.id.rawValue), "workspace": .string(workspace.id), "workspaceName": .string(workspace.name),
                             "workspaceKind": .string("linux"), "ready": .bool(remoteWorkspaces.isHarnessReady(harness.id, in: configuration))])
                }
                continue
            }
            let base: [String: JSONValue] = ["workspace": .string(workspace.id), "workspaceName": .string(workspace.name),
                                                    "workspaceKind": .string(workspace.kind.rawValue)]
            do {
                let providers = try await centralExecutionClient().providers(workspace: workspace)
                let kinds = Set(AgentRuntimeKind.allCases.map(\.rawValue))
                for provider in providers where kinds.contains(provider.runtimeKind) {
                    rows.append(.object(base.merging(["harness": .string(provider.runtimeKind),
                        "ready": .bool(provider.available && provider.canStart)]) { $1 }))
                }
            } catch {
                rows.append(.object(base.merging(["online": .bool(false), "error": .string(String(error.localizedDescription.prefix(256)))]) { $1 }))
            }
        }
        return rows
    }

    /// Peers that refused library sync with `update_required`, worded so the
    /// devices' "Versions don't match" notice offers Update everything.
    nonisolated static func libraryUpdateNotices(_ status: LibrarySyncStatus?) -> [String] {
        (status?.peers ?? []).filter { $0.state == .updateRequired }.map { peer in
            "\(peer.name) needs the same Woven Matter version to synchronize" + (peer.version.map { " (it runs \($0))." } ?? ".")
        }
    }

    /// A stable UUID for one step of one agent request.
    nonisolated static func memberToolID(_ sourceID: String, _ requestID: String, _ step: String) -> String {
        var bytes = Array(PortableSHA256.hash(data: Data("woven-member-tool-v1\0\(sourceID)\0\(requestID)\0\(step)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }
}

/// Managing sessions on other workspaces (docs/architecture/WOVEN_EVERYWHERE.md,
/// "Sessions across devices"), with the same semantics as Linux's
/// `remote/src/member-sessions.mjs`: each call is one or more signed requests
/// to the destination's execution API, and command IDs derive from the caller,
/// request, workspace and session, so a retry replays the destination's receipt.
extension ApplicationModel {
    /// `woven_sessions_status`, `_send`, `_stop`, `_respond` and `_list` for a
    /// session another member's workspace runs: one this caller created there,
    /// or one named with `workspace`. Nil when this Mac handles the call.
    /// `woven_sessions_wait` is always answered here, for this Mac's sessions too.
    func handleMemberSessionTool(callerID: String, command: WovenMatterToolCommand,
                                 request: WovenMatterToolRequest) async throws -> WovenMatterToolResponse? {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let readsAll = try await database.sessionTools(callerID).enabled.contains(.history)
        if command.action == "wait" { return try await memberSessionWait(callerID: callerID, command: command, readsAll: readsAll) }
        if command.action == "list" {
            let limit = try command.integer("limit", default: 100, range: 1...200)
            if let raw = command.options["workspace"] {
                guard case .member(let workspace) = try await resolveAgentToolDestination(raw, callerWorkspace: nil) else { return nil }
                return try await memberSessionList(callerID: callerID, workspace: workspace, readsAll: readsAll, limit: limit)
            }
            // A bot has no chat of its own: its list is every session it created elsewhere.
            guard WovenMCPCaller.parseBot(callerID) != nil else { return nil }
            return try await createdMemberSessions(callerID: callerID, limit: limit)
        }
        let id = try command.required("id", allowPositional: true)
        guard let workspace = try await memberSessionWorkspace(id: id, named: command.options["workspace"]) else { return nil }
        let client = try centralExecutionClient()
        switch command.action {
        case "status":
            let creator = try await database.memberToolSession(id: id)?.callerID
            guard readsAll || creator == callerID else {
                throw WorkspaceToolError.invalid("Read only the sessions you created, or enable Conversation history.")
            }
            let status = try await memberSessionStatus(client: client, workspace: workspace, id: id, before: command.options["before"])
            await observeMemberSession(callerID: callerID, workspace: workspace, id: id,
                state: status.result?.objectValue?["session"]?.objectValue?["state"]?.stringValue ?? "idle", response: status)
            return status
        case "send":
            let sent = try await memberSessionSend(client: client, workspace: workspace, callerID: callerID, requestID: request.requestID,
                                                   id: id, text: command.required("text"))
            await observeMemberSession(callerID: callerID, workspace: workspace, id: id, state: "running", response: sent)
            return sent
        case "stop":
            let stopped = try await memberSessionStop(client: client, workspace: workspace, callerID: callerID, requestID: request.requestID, id: id)
            // The caller stopped it: no wake-up for its end.
            if stopped.result?.objectValue?["stopped"] == .bool(true) {
                await observeMemberSession(callerID: callerID, workspace: workspace, id: id, state: "idle")
            }
            return stopped
        case "respond":
            let answered = try await memberSessionRespond(client: client, workspace: workspace, callerID: callerID, requestID: request.requestID,
                                                          id: id, interactionID: command.required("interaction"),
                                                          response: Self.interactionResponse(command))
            await observeMemberSession(callerID: callerID, workspace: workspace, id: id, state: "running", response: answered)
            return answered
        default: return nil
        }
    }

    /// The member workspace that runs session `id`: the one `named` names, or
    /// the one this Mac created it on. Nil for this Mac's own sessions (and a
    /// session this Mac did not create there), which this library holds.
    func memberSessionWorkspace(id: String, named: String?) async throws -> ExecutionWorkspace? {
        if let named {
            if case .member(let workspace) = try await resolveAgentToolDestination(named, callerWorkspace: nil) { return workspace }
            return nil
        }
        guard UUID(uuidString: id) != nil, let database = dashboardStore?.database,
              let record = try await database.memberToolSession(id: id) else { return nil }
        let (own, others) = try await agentToolWorkspaces()
        if record.workspaceID == own?.id { return nil }
        guard let workspace = others.first(where: { $0.id == record.workspaceID }), workspace.endpoint != nil else {
            throw WorkspaceToolError.invalid("The workspace that runs this session is no longer known here.")
        }
        return workspace
    }

    private func memberConversation(_ client: CentralExecutionClient, _ workspace: ExecutionWorkspace,
                                    _ id: String) async throws -> LibraryConversation {
        guard UUID(uuidString: id) != nil else { throw WorkspaceToolError.invalid("Name the session by its ID.") }
        guard let found = try await client.conversations(workspace: workspace).first(where: { $0.id.lowercased() == id.lowercased() }) else {
            throw WorkspaceToolError.notFound("No session \(id) runs on \(workspace.name).")
        }
        return found
    }

    nonisolated static func describeMemberSession(_ conversation: LibraryConversation, on workspace: ExecutionWorkspace) -> [String: JSONValue] {
        var value: [String: JSONValue] = [
            "id": .string(conversation.id), "title": .string(conversation.title),
            "harness": conversation.runtimeKind.map(JSONValue.string) ?? .null,
            "workspace": .string(workspace.id), "workspaceName": .string(workspace.name), "workspaceKind": .string(workspace.kind.rawValue),
            "state": .string(conversation.activeRunID == nil ? "idle" : "running")
        ]
        if let run = conversation.activeRunID { value["runID"] = .string(run) }
        if !conversation.updatedAt.isEmpty { value["updatedAt"] = .string(conversation.updatedAt) }
        if !conversation.preview.isEmpty { value["preview"] = .string(clip(conversation.preview, 512)) }
        return value
    }

    nonisolated private static func clip(_ text: String, _ size: Int) -> String { text.count > size ? String(text.prefix(size)) + "…" : text }

    /// State, pending questions and approvals, and the latest 20 messages
    /// (4000 characters each); `before` pages older ones.
    func memberSessionStatus(client: CentralExecutionClient, workspace: ExecutionWorkspace,
                                     id: String, before: String?) async throws -> WovenMatterToolResponse {
        let found = try await memberConversation(client, workspace, id)
        let transcript = try await client.transcript(workspace: workspace, conversationID: found.id, before: before)
        let pending = ((try? await client.pendingInteractions(workspace: workspace)) ?? [])
            .filter { $0.conversationID.lowercased() == found.id.lowercased() }
        let messages: [JSONValue] = transcript.messages.suffix(20).map { message in
            var value: [String: JSONValue] = ["id": .string(message.id), "role": .string(message.role),
                "createdAt": .string(message.createdAt), "content": .string(Self.clip(message.content, 4000))]
            if let run = message.runID { value["runID"] = .string(run) }
            if let status = message.status { value["status"] = .string(status) }
            return .object(value)
        }
        let questions: [JSONValue] = try pending.map { item in
            var value: [String: JSONValue] = ["id": .string(item.id), "kind": .string(item.kind.rawValue), "title": .string(item.title),
                "runID": item.runID.map(JSONValue.string) ?? .null,
                "options": try WovenMCPCatalog.json(item.options), "questions": try WovenMCPCatalog.json(item.questions)]
            if let detail = item.detail { value["detail"] = .string(Self.clip(detail, 2000)) }
            return .object(value)
        }
        var session = Self.describeMemberSession(found, on: workspace)
        if !pending.isEmpty { session["state"] = .string("needsInput") }
        var page: [String: JSONValue] = ["messages": .array(messages)]
        if let older = transcript.olderCursor { page["before"] = .string(older) }
        var result: [String: JSONValue] = ["session": .object(session), "pending": .array(questions), "transcript": .object(page)]
        if pending.contains(where: { $0.kind == .approval }) {
            result["note"] = .string("Permission approvals belong to the user unless this workspace’s user granted full access; answer questions with woven_sessions_respond.")
        }
        return .init(result: .object(result))
    }

    private func memberCommand(_ client: CentralExecutionClient, _ workspace: ExecutionWorkspace, callerID: String,
                               requestID: String, conversation: String, step: String, kind: LibraryCommand.Kind,
                               runID: String? = nil, text: String? = nil, interactionID: String? = nil,
                               response: InteractionResponse? = nil) async throws -> LibraryCommandReceipt {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let device = try await database.libraryIdentity().hostDeviceID
        let command = LibraryCommand(commandID: Self.memberToolID(callerID, requestID, workspace.id + ":" + conversation + ":" + step),
            deviceID: device, kind: kind, conversationID: conversation, runID: runID, text: text, interactionID: interactionID,
            response: response, libraryID: workspace.libraryID, workspaceID: workspace.id)
        return try await client.submit(command, workspace: workspace)
    }

    private static func receiptValue(_ receipt: LibraryCommandReceipt) -> JSONValue {
        var value: [String: JSONValue] = ["commandID": .string(receipt.commandID), "status": .string(receipt.status.rawValue)]
        if let run = receipt.runID { value["runID"] = .string(run) }
        return .object(value)
    }

    /// Sends to an idle session, or steers a running one when its harness can.
    private func memberSessionSend(client: CentralExecutionClient, workspace: ExecutionWorkspace, callerID: String,
                                   requestID: String, id: String, text: String) async throws -> WovenMatterToolResponse {
        let found = try await memberConversation(client, workspace, id)
        let receipt: LibraryCommandReceipt
        if let run = found.activeRunID {
            let capability = try? await client.capabilities(workspace: workspace, conversationID: found.id)
            guard capability?.canSteer == true else {
                throw WorkspaceToolError.invalid("\(found.title.isEmpty ? "The session" : found.title) is running and its harness cannot take a message mid-turn. Check woven_sessions_status and send when it is idle.")
            }
            receipt = try await memberCommand(client, workspace, callerID: callerID, requestID: requestID, conversation: found.id,
                                              step: "steer", kind: .steer, runID: run, text: text)
        } else {
            receipt = try await memberCommand(client, workspace, callerID: callerID, requestID: requestID, conversation: found.id,
                                              step: "send", kind: .send, text: text)
        }
        return .init(result: .object(["session": .object(Self.describeMemberSession(found, on: workspace)), "receipt": Self.receiptValue(receipt)]))
    }

    private func memberSessionStop(client: CentralExecutionClient, workspace: ExecutionWorkspace, callerID: String,
                                   requestID: String, id: String) async throws -> WovenMatterToolResponse {
        let found = try await memberConversation(client, workspace, id)
        let session = JSONValue.object(Self.describeMemberSession(found, on: workspace))
        guard let run = found.activeRunID else {
            return .init(result: .object(["session": session, "stopped": .bool(false), "message": .string("The session is not running.")]))
        }
        let receipt = try await memberCommand(client, workspace, callerID: callerID, requestID: requestID, conversation: found.id,
                                              step: "stop", kind: .stop, runID: run)
        return .init(result: .object(["session": session, "stopped": .bool([.accepted, .completed].contains(receipt.status)),
                                      "receipt": Self.receiptValue(receipt)]))
    }

    /// Answers one pending question (or approval) of the session's current run.
    private func memberSessionRespond(client: CentralExecutionClient, workspace: ExecutionWorkspace, callerID: String,
                                      requestID: String, id: String, interactionID: String,
                                      response: InteractionResponse) async throws -> WovenMatterToolResponse {
        let found = try await memberConversation(client, workspace, id)
        guard let pending = try await client.pendingInteractions(workspace: workspace).first(where: {
            $0.id == interactionID && $0.conversationID.lowercased() == found.id.lowercased()
        }) else { throw WorkspaceToolError.invalid("That question is no longer pending. Read woven_sessions_status again.") }
        try Self.validate(response, for: pending)
        let receipt = try await memberCommand(client, workspace, callerID: callerID, requestID: requestID, conversation: found.id,
                                              step: "respond", kind: .respond, runID: pending.runID, interactionID: pending.id, response: response)
        return .init(result: .object(["session": .object(Self.describeMemberSession(found, on: workspace)), "receipt": Self.receiptValue(receipt)]))
    }

    nonisolated static func interactionResponse(_ command: WovenMatterToolCommand) throws -> InteractionResponse {
        var answers: [String: [String]] = [:]
        if let raw = command.options["answers"] {
            guard let decoded = try? JSONDecoder().decode([String: [String]].self, from: Data(raw.utf8)) else {
                throw WorkspaceToolError.invalid("answers maps each question ID to a list of selected values.")
            }
            answers = decoded
        }
        return .init(optionID: command.options["option-id"], answers: answers, cancelled: command.options["cancelled"] != nil)
    }

    nonisolated static func validate(_ response: InteractionResponse, for pending: PendingInteraction) throws {
        if !response.cancelled, pending.kind == .approval, !pending.options.contains(where: { $0.id == response.optionID }) {
            throw WorkspaceToolError.invalid("Choose one of the offered options.")
        }
    }

    /// Sessions on one member workspace: all of them with Conversation
    /// history, otherwise only those this caller created.
    private func memberSessionList(callerID: String, workspace: ExecutionWorkspace, readsAll: Bool,
                                   limit: Int) async throws -> WovenMatterToolResponse {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let created = Set(try await database.memberToolSessions(callerID: callerID).map(\.id))
        let rows = try await centralExecutionClient().conversations(workspace: workspace).filter { readsAll || created.contains($0.id.lowercased()) }
        return .init(result: .object(["rows": .array(rows.prefix(limit).map { .object(Self.describeMemberSession($0, on: workspace)) }),
                                      "hasMore": .bool(rows.count > limit)]))
    }

    /// Every session `callerID` created on other workspaces, each with its live
    /// state; a workspace that does not answer marks its rows `online: false`.
    private func createdMemberSessions(callerID: String, limit: Int) async throws -> WovenMatterToolResponse {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let mine = try await database.memberToolSessions(callerID: callerID)
        let (_, others) = try await agentToolWorkspaces()
        var rows: [JSONValue] = []
        var order: [String] = [], byWorkspace: [String: [String]] = [:]
        for record in mine {
            if byWorkspace[record.workspaceID] == nil { order.append(record.workspaceID) }
            byWorkspace[record.workspaceID, default: []].append(record.id)
        }
        for workspaceID in order {
            let ids = byWorkspace[workspaceID] ?? []
            guard let workspace = others.first(where: { $0.id == workspaceID }), workspace.endpoint != nil else {
                rows += ids.map { .object(["id": .string($0), "workspace": .string(workspaceID), "online": .bool(false)]) }
                continue
            }
            do {
                let live = try await centralExecutionClient().conversations(workspace: workspace)
                for id in ids {
                    if let conversation = live.first(where: { $0.id.lowercased() == id }) {
                        rows.append(.object(Self.describeMemberSession(conversation, on: workspace)))
                    } else {
                        rows.append(.object(["id": .string(id), "workspace": .string(workspaceID), "workspaceName": .string(workspace.name), "state": .string("missing")]))
                    }
                }
            } catch {
                rows += ids.map { .object(["id": .string($0), "workspace": .string(workspaceID), "workspaceName": .string(workspace.name),
                                           "online": .bool(false), "error": .string(String(error.localizedDescription.prefix(256)))]) }
            }
        }
        return .init(result: .object(["rows": .array(Array(rows.prefix(limit))), "hasMore": .bool(rows.count > limit)]))
    }

    /// `woven_sessions_stop` and `_respond` for a session on this Mac: only one
    /// the caller created or coordinates, through this Mac's own execution
    /// commands, as another member's request would.
    func handleLocalSessionControl(callerID: String, command: WovenMatterToolCommand,
                                   request: WovenMatterToolRequest) async throws -> WovenMatterToolResponse {
        guard let database = dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
        let id = try command.required("id", allowPositional: true)
        let relationship = try await database.sessionRelationship(id)
        guard relationship.createdBy == callerID || relationship.coordinatorID == callerID else {
            throw WorkspaceToolError.invalid("Stop or answer only the sessions you created or coordinate.")
        }
        let device = try await database.libraryIdentity().hostDeviceID
        let commandID = Self.memberToolID(callerID, request.requestID, "local:" + id + ":" + command.action)
        if command.action == "stop" {
            guard let run = await canonicalActiveRunID(conversationID: id) else {
                return .init(result: .object(["id": .string(id), "stopped": .bool(false), "message": .string("The session is not running.")]))
            }
            let receipt = try await libraryCommands.execute(.init(commandID: commandID, deviceID: device, kind: .stop,
                conversationID: id, runID: run), deviceID: device)
            return .init(result: .object(["id": .string(id), "stopped": .bool([.accepted, .completed].contains(receipt.status)),
                                          "receipt": Self.receiptValue(receipt)]))
        }
        let interactionID = try command.required("interaction")
        guard let pending = await libraryCommands.pendingInteractions().first(where: {
            $0.id == interactionID && $0.conversationID.lowercased() == id.lowercased()
        }) else { throw WorkspaceToolError.invalid("That question is no longer pending. Read woven_sessions_status again.") }
        let response = try Self.interactionResponse(command)
        try Self.validate(response, for: pending)
        let receipt = try await libraryCommands.execute(.init(commandID: commandID, deviceID: device, kind: .respond,
            conversationID: id, runID: pending.runID, interactionID: pending.id, response: response), deviceID: device)
        return .init(result: .object(["id": .string(id), "receipt": Self.receiptValue(receipt)]))
    }
}
