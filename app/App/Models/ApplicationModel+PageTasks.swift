import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

/// Sends Page tasks to the agents and bots they are assigned to, and stops them.
///
/// Exactly one place sends each agent's task, so a chat is never started twice:
/// the Mac whose agent it is starts it on itself, and a Linux workspace's agent is
/// started by the Mac that added that workspace. The background process does this,
/// since it owns execution. Bots are reached from the window process, which holds
/// their connections; a bot accepts one delivery once, whichever Mac sends it.
extension ApplicationModel {
    enum PageTaskRoute {
        case thisMac(AgentRuntimeKind)
        case linux(RemoteHarnessChatTarget)
    }

    /// Checks every two seconds, in the background process for agents and in
    /// the window process for bots.
    func startPageTaskDispatch() {
        pageTaskDispatchTask?.cancel()
        pageTaskDispatchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runPageTaskDispatch()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    /// One pass over Pages whose assignees wait to be sent or stopped.
    func runPageTaskDispatch() async {
        let ownsExecution = LocalExecutionRole.current.ownsExecution
        let pages: [(id: String, title: String, content: String)]
        if ownsExecution {
            guard let database = libraryStore?.database else { return }
            do { pages = try await database.pagesAwaitingTaskDispatch() } catch { return }
        } else {
            pages = (workspaceOverview?.notes ?? []).filter {
                $0.content.contains("\"state\":\"sending\"") || $0.content.contains("\"state\":\"stopping\"")
            }.map { ($0.id, $0.title, $0.content) }
        }
        guard !pages.isEmpty else { return }
        let own = ownsExecution ? (try? await agentToolWorkspaces().own) : nil
        for page in pages {
            let document = NoteDocument.decode(page.content).materializedPage()
            guard document.kind == .canvas else { continue }
            for block in document.blocks {
                guard let task = document.boardItems?[block.id]?.task else { continue }
                for assignee in task.assignees where assignee.state == .sending || assignee.state == .stopping {
                    guard !pageTaskInFlight.contains(assignee.id) else { continue }
                    let work = PageTaskWork(pageID: page.id, pageTitle: page.title, componentID: block.id,
                                            title: block.plainText, details: task.details, assignee: assignee)
                    switch assignee.kind {
                    case .agent:
                        guard ownsExecution, let route = pageTaskRoute(assignee, own: own) else { continue }
                        pageTaskInFlight.insert(assignee.id)
                        await dispatchAgentTask(work, route: route)
                        pageTaskInFlight.remove(assignee.id)
                    case .bot:
                        // Only the window process connects to bots.
                        guard let machineID = assignee.machineID, let client = bots.session(for: machineID)?.connectedClient else { continue }
                        pageTaskInFlight.insert(assignee.id)
                        await dispatchBotTask(work, client: client)
                        pageTaskInFlight.remove(assignee.id)
                    case .user:
                        // The person needs no chat; a stray request settles where it is.
                        guard ownsExecution else { continue }
                        var settled = assignee
                        settled.state = assignee.state == .stopping ? .stopped : .assigned
                        await writePageAssignee(work, settled)
                    }
                }
            }
        }
    }

    /// The route when this Mac is the one that sends this agent its task.
    func pageTaskRoute(_ assignee: BoardTaskAssignee, own: ExecutionWorkspace?) -> PageTaskRoute? {
        guard let workspaceID = assignee.workspaceID?.lowercased(), let raw = assignee.runtime,
              let runtime = AgentRuntimeKind(rawValue: raw) else { return nil }
        if let own, workspaceID == own.id { return .thisMac(runtime) }
        guard let uuid = UUID(uuidString: workspaceID), let configuration = remoteWorkspaces.configuration(id: uuid),
              let harness = remoteWorkspaces.harnesses[uuid]?.first(where: { $0.id == runtime }) else { return nil }
        return .linux(.init(configuration: configuration, harness: harness))
    }

    struct PageTaskWork {
        let pageID: String
        let pageTitle: String
        let componentID: String
        let title: String
        let details: String
        let assignee: BoardTaskAssignee

        var chatTitle: String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Task" : String(trimmed.prefix(200))
        }

        /// The first message: the task, and how to report back on the Page.
        var prompt: String {
            var lines = ["You are assigned a task on the Page “\(pageTitle.isEmpty ? "Untitled Page" : pageTitle)”.", "",
                         "Task: \(chatTitle)"]
            let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !details.isEmpty { lines += ["", details] }
            lines += ["", "Page ID: \(pageID). Task component ID: \(componentID).",
                      "Read the Page with woven_pages_read for context. While you work, set the task's status to doing. Write your result in the task's outcome, then set status done, or blocked if you need the person. If more work is needed, add follow-up tasks right after this one with woven_pages_add_component."]
            return lines.joined(separator: "\n")
        }
    }

    private func dispatchAgentTask(_ work: PageTaskWork, route: PageTaskRoute) async {
        var assignee = work.assignee
        guard let conversationID = assignee.conversationID, let uuid = UUID(uuidString: conversationID) else {
            assignee.state = .failed; assignee.message = "This assignment has no chat to start."
            return await writePageAssignee(work, assignee)
        }
        if assignee.state == .stopping {
            if workspaceOverview?.conversations.contains(where: { $0.id == conversationID }) == true {
                _ = try? await beginAgentStop(conversationID: conversationID).value
            }
            assignee.state = .stopped; assignee.message = nil
            return await writePageAssignee(work, assignee)
        }
        if workspaceOverview?.conversations.contains(where: { $0.id == conversationID }) != true {
            await refreshWorkspace()
        }
        if workspaceOverview?.conversations.contains(where: { $0.id == conversationID }) != true {
            let created: String?
            switch route {
            case .thisMac(let runtime):
                created = await createLocalACPSession(runtimeKind: runtime, requestedConversationID: uuid,
                                                      initialTitle: work.chatTitle, folderID: assignee.folderID)
            case .linux(let target):
                created = await createRemoteACPSession(target: target, requestedConversationID: uuid,
                                                       initialTitle: work.chatTitle, folderID: assignee.folderID)
            }
            guard created == conversationID else {
                assignee.state = .failed; assignee.message = localRunError ?? "The chat could not be started."
                return await writePageAssignee(work, assignee)
            }
            await refreshWorkspace()
        }
        guard let conversation = workspaceOverview?.conversations.first(where: { $0.id == conversationID }) else {
            assignee.state = .failed; assignee.message = "The new chat is not available yet."
            return await writePageAssignee(work, assignee)
        }
        // A chat that already has messages was sent its task before this pass.
        if conversation.lastMessageAt == nil {
            guard await sendAgentMessage(conversation: conversation, input: AgentMessageInput(text: work.prompt)) else {
                assignee.state = .failed
                assignee.message = conversationError(for: conversationID) ?? "The task could not be sent."
                return await writePageAssignee(work, assignee)
            }
        }
        assignee.state = .sent; assignee.message = nil
        await writePageAssignee(work, assignee)
    }

    private func dispatchBotTask(_ work: PageTaskWork, client: PiBotClient) async {
        var assignee = work.assignee
        guard let botID = assignee.botID else { return }
        do {
            if assignee.state == .stopping {
                if let raw = assignee.conversationID, let thread = Int(raw) {
                    try? await client.abort(botID: botID, conversationID: thread)
                    try await client.send(botID: botID, conversationID: thread,
                                          text: "This task is no longer needed: “\(work.chatTitle)”. Stop working on it.",
                                          deliveryID: assignee.id + ":stop")
                }
                assignee.state = .stopped; assignee.message = nil
            } else {
                // nil: an earlier pass's delivery was already accepted.
                if let thread = try await client.startThread(botID: botID, text: work.prompt, deliveryID: assignee.id) {
                    assignee.conversationID = String(thread)
                }
                assignee.state = .sent; assignee.message = nil
            }
        } catch {
            assignee.state = assignee.state == .stopping ? .stopped : .failed
            assignee.message = String(error.localizedDescription.prefix(500))
        }
        await writePageAssignee(work, assignee)
    }

    /// Records where an assignee stands. The background process writes the
    /// library directly; the window process edits through its draft, so an
    /// open Page keeps everything typed into it.
    private func writePageAssignee(_ work: PageTaskWork, _ assignee: BoardTaskAssignee) async {
        let edit = PageEdit(action: .updateAssignee, id: work.componentID, assignee: assignee)
        if LocalExecutionRole.current.ownsExecution, let database = libraryStore?.database {
            do {
                let response = try await database.applyNoteEdits(
                    .init(command: .apply, noteID: work.pageID, operations: [.page(edit)]),
                    requestID: UUID().uuidString.lowercased())
                await adoptNoteEditingResponse(response)
            } catch { agentTools?.error = error.localizedDescription }
            return
        }
        guard let note = workspaceOverview?.notes.first(where: { $0.id == work.pageID }) else { return }
        var document = NoteDocument.decode(noteDraft(for: note).content)
        do {
            try document.applyPageEdit(edit)
            updateNoteDraft(note: note, content: try document.encoded())
            _ = await flushNoteDrafts()
        } catch { agentTools?.error = error.localizedDescription }
    }

    // MARK: Who a task can be assigned to

    /// The person, this Mac's agents, other Macs' and Linux workspaces' agents,
    /// then bots. An agent starts in the Page's folder when its workspace owns it.
    func pageAssignTargets(pageFolderID: String?) async -> [PageAssignTarget] {
        let folders = workspaceOverview?.folders ?? []
        let pageFolder = pageFolderID.flatMap { id in folders.first { $0.id == id } }
        func folder(for owner: String?) -> String? {
            guard let owner, let pageFolder, let bound = pageFolder.executionWorkspaceID else { return nil }
            return PairedWorkspaceSidebarModel.canonicalID(bound) == PairedWorkspaceSidebarModel.canonicalID(owner) ? pageFolder.id : nil
        }
        var targets = [PageAssignTarget(id: "me", group: .me, assignee: BoardTaskAssignee(kind: .user), ready: true,
                                        detail: nil, folderOwner: nil)]
        let own = try? await agentToolWorkspaces().own
        var localOwner = own?.folderOwnerID
        if localOwner == nil { localOwner = try? await executionWorkspaceIdentity(workspaceID: nil) }
        if let own {
            let place = own.name
            for definition in orderedLocalACPRuntimeDefinitions {
                let runtime = definition.runtimeKind
                let ready = canStartCanonicalLocalSession(runtime)
                targets.append(.init(id: "\(own.id):\(runtime.rawValue)", group: .place("\(place) (this Mac)"),
                    assignee: BoardTaskAssignee(kind: .agent, name: definition.displayName, place: place, workspaceID: own.id,
                                                runtime: runtime.rawValue, folderID: folder(for: localOwner)),
                    ready: ready, detail: ready ? nil : "Not set up", folderOwner: localOwner))
            }
        }
        let configured = remoteWorkspaces.readyChatTargets
        for target in configured {
            let id = target.configuration.id.uuidString.lowercased()
            let owner = Self.remoteDatabaseSourceID(target.configuration.id)
            targets.append(.init(id: "\(id):\(target.harness.id.rawValue)", group: .place(target.configuration.name),
                assignee: BoardTaskAssignee(kind: .agent, name: target.harness.id.displayName, place: target.configuration.name,
                                            workspaceID: id, runtime: target.harness.id.rawValue, folderID: folder(for: owner)),
                ready: true, detail: nil, folderOwner: owner))
        }
        for peer in NewChatPeerTarget.resolve(agents: remoteWorkspaceAgents, peerWorkspaces: peerAgentWorkspaces,
                                              configured: configured, folderOwnerID: nil) where peer.workspace.id != own?.id {
            let owner = peer.workspace.folderOwnerID ?? peer.workspace.id
            targets.append(.init(id: "\(peer.workspace.id):\(peer.runtimeKind.rawValue)", group: .place(peer.workspace.name),
                assignee: BoardTaskAssignee(kind: .agent, name: peer.runtimeKind.displayName, place: peer.workspace.name,
                                            workspaceID: peer.workspace.id, runtime: peer.runtimeKind.rawValue, folderID: folder(for: owner)),
                ready: true, detail: peer.workspace.kind == .mac ? nil : "Linux", folderOwner: owner))
        }
        for session in bots.orderedSessions {
            let machine = bots.botMachines.first { $0.id == session.machineID }
            for bot in session.bots {
                targets.append(.init(id: "bot:\(session.machineID):\(bot.id)", group: .bots,
                    assignee: BoardTaskAssignee(kind: .bot, name: bot.name, place: machine?.name, botID: bot.id, machineID: session.machineID),
                    ready: session.connectedClient != nil, detail: machine?.name, folderOwner: nil))
            }
        }
        return targets
    }

    /// Starts a new chat with one agent or bot right away and sends it `text`.
    /// Returns what the chat callback opens: a conversation ID, or a bot thread link.
    func startAgentChat(_ assignee: BoardTaskAssignee, title: String, text: String) async throws -> String {
        struct Failure: LocalizedError { let errorDescription: String? }
        switch assignee.kind {
        case .user:
            throw Failure(errorDescription: "Choose an agent or a bot.")
        case .bot:
            guard let machine = assignee.machineID, let bot = assignee.botID,
                  let client = bots.session(for: machine)?.connectedClient else {
                throw Failure(errorDescription: "\(assignee.name) can't be reached right now.")
            }
            let thread = try await client.startThread(botID: bot, text: text, deliveryID: UUID().uuidString.lowercased())
            return BotTarget(machineID: machine, botID: bot, conversationID: thread).pageTaskLink
        case .agent:
            guard let workspaceID = assignee.workspaceID, let runtime = assignee.runtime.flatMap(AgentRuntimeKind.init(rawValue:)) else {
                throw Failure(errorDescription: "Choose an agent.")
            }
            let requested = UUID()
            let own = try? await agentToolWorkspaces().own
            let created: String?
            if workspaceID == own?.id {
                created = await createLocalACPSession(runtimeKind: runtime, requestedConversationID: requested,
                                                      initialTitle: title, folderID: assignee.folderID)
            } else if let uuid = UUID(uuidString: workspaceID), let target = remoteWorkspaces.readyChatTargets.first(where: {
                $0.configuration.id == uuid && $0.harness.id == runtime }) {
                created = await createRemoteACPSession(target: target, requestedConversationID: requested,
                                                       initialTitle: title, folderID: assignee.folderID)
            } else if let peer = remoteWorkspaceAgents.first(where: {
                peerAgentWorkspaces[$0.id]?.id == workspaceID && $0.runtimeKind == runtime }) {
                created = try await createPairedMacSession(agentID: peer.id, conversationID: requested, folderID: assignee.folderID)
            } else {
                throw Failure(errorDescription: "\(assignee.name) on \(assignee.place ?? "that workspace") isn't available.")
            }
            guard let created else { throw Failure(errorDescription: localRunError ?? "The chat could not be started.") }
            await refreshWorkspace()
            guard let conversation = workspaceOverview?.conversations.first(where: { $0.id == created }) else {
                throw Failure(errorDescription: "The new chat is not available yet.")
            }
            guard await sendAgentMessage(conversation: conversation, input: AgentMessageInput(text: text)) else {
                throw Failure(errorDescription: conversationError(for: created) ?? "The message could not be sent.")
            }
            return created
        }
    }
}
