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
        // The window process only sends to bots.
        if !ownsExecution && bots.orderedSessions.isEmpty { return }
        // Look again only once the library changed, and every 30 seconds to
        // retry what could not be sent yet, rather than reading every note each pass.
        let revision = ownsExecution ? ((try? await libraryStore?.database.workspaceRevision()) ?? -1) : workspaceListRevision
        if let scan = pageTaskScan, scan.revision == revision, Date().timeIntervalSince(scan.at) < 30 { return }
        pageTaskScan = (revision, Date())
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
            if !details.isEmpty { lines += ["", "Instructions:", details] }
            lines += ["", "Page ID: \(pageID). Task component ID: \(componentID).",
                      "Read the Page with woven_pages_read for context. When you start, set the task's status to doing. When you finish, write what you did in the task's outcome and set status done. If you need more input from the person, write what you need in the outcome and set status blocked. If more work is needed, add follow-up tasks right after this one with woven_pages_add_component."]
            return lines.joined(separator: "\n")
        }
    }

    private func dispatchAgentTask(_ work: PageTaskWork, route: PageTaskRoute) async {
        var assignee = work.assignee
        guard let conversationID = assignee.conversationID, let uuid = UUID(uuidString: conversationID) else {
            assignee.state = .failed; assignee.message = "This assignment has no chat to start."
            return await writePageAssignee(work, assignee)
        }
        if workspaceOverview?.conversations.contains(where: { $0.id == conversationID }) != true {
            await refreshWorkspace()
        }
        let exists = workspaceOverview?.conversations.contains(where: { $0.id == conversationID }) == true
        if assignee.state == .stopping {
            // A chat that was never started has nothing to stop.
            if exists {
                do { _ = try await beginAgentStop(conversationID: conversationID).value } catch {
                    assignee.message = String(error.localizedDescription.prefix(500))
                }
            }
            assignee.state = .stopped
            return await writePageAssignee(work, assignee)
        }
        var created = false
        if !exists {
            let result: String?
            switch route {
            case .thisMac(let runtime):
                result = await createLocalACPSession(runtimeKind: runtime, requestedConversationID: uuid,
                                                     initialTitle: work.chatTitle, folderID: assignee.folderID)
            case .linux(let target):
                result = await createRemoteACPSession(target: target, requestedConversationID: uuid,
                                                      initialTitle: work.chatTitle, folderID: assignee.folderID)
            }
            guard result == conversationID else {
                assignee.state = .failed; assignee.message = localRunError ?? "The chat could not be started."
                return await writePageAssignee(work, assignee)
            }
            created = true
            await refreshWorkspace()
        }
        guard let conversation = workspaceOverview?.conversations.first(where: { $0.id == conversationID }) else {
            assignee.state = .failed; assignee.message = "The new chat is not available yet."
            return await writePageAssignee(work, assignee)
        }
        // A chat that already has messages was sent its task by an earlier pass
        // that stopped before recording it. A chat started just now has none.
        let alreadySent: Bool
        if created { alreadySent = false } else {
            alreadySent = (try? await libraryStore?.database.conversationHasMessages(conversationID)) ?? false
        }
        if !alreadySent {
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
                // nil: an earlier delivery was already accepted. Its thread is
                // kept by whichever write recorded it.
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

    /// Records where an assignee stands, only while it is still in the state this
    /// pass read: a Stop or another Mac's write made meanwhile wins, and the next
    /// pass acts on it. The background process writes the library directly; the
    /// window process edits through its draft, so an open Page keeps everything
    /// typed into it.
    private func writePageAssignee(_ work: PageTaskWork, _ assignee: BoardTaskAssignee) async {
        let edit = PageEdit(action: .updateAssignee, id: work.componentID, assignee: assignee,
                            expectedAssigneeState: work.assignee.state)
        if LocalExecutionRole.current.ownsExecution, let database = libraryStore?.database {
            do {
                let response = try await database.applyNoteEdits(
                    .init(command: .apply, noteID: work.pageID, operations: [.page(edit)]),
                    requestID: UUID().uuidString.lowercased())
                await adoptNoteEditingResponse(response)
            } catch NoteEditError.pageAssigneeChanged {
                return
            } catch { agentTools?.error = error.localizedDescription }
            return
        }
        guard let note = workspaceOverview?.notes.first(where: { $0.id == work.pageID }) else { return }
        var document = NoteDocument.decode(noteDraft(for: note).content)
        do {
            try document.applyPageEdit(edit)
            updateNoteDraft(note: note, content: try document.encoded())
            _ = await flushNoteDrafts()
        } catch NoteEditError.pageAssigneeChanged {
            return
        } catch { agentTools?.error = error.localizedDescription }
    }

    // MARK: Who a task can be assigned to

    /// The person, then agents by workspace as the sidebar names them (Local
    /// workspace, then remote workspaces by their display names), then bots.
    /// An agent starts in the Page's folder when its workspace owns it.
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
            let place = "Local workspace"
            for definition in orderedLocalACPRuntimeDefinitions {
                let runtime = definition.runtimeKind
                let ready = canStartCanonicalLocalSession(runtime)
                targets.append(.init(id: "\(own.id):\(runtime.rawValue)", group: .place(place),
                    assignee: BoardTaskAssignee(kind: .agent, name: definition.displayName, place: place, workspaceID: own.id,
                                                runtime: runtime.rawValue, folderID: folder(for: localOwner)),
                    ready: ready, detail: ready ? nil : "Not set up", folderOwner: localOwner))
            }
        }
        let configured = remoteWorkspaces.readyChatTargets
        for target in configured {
            let id = target.configuration.id.uuidString.lowercased()
            let owner = Self.remoteDatabaseSourceID(target.configuration.id)
            let place = workspaceDisplayName(target.configuration)
            targets.append(.init(id: "\(id):\(target.harness.id.rawValue)", group: .place(place),
                assignee: BoardTaskAssignee(kind: .agent, name: target.harness.id.displayName, place: place,
                                            workspaceID: id, runtime: target.harness.id.rawValue, folderID: folder(for: owner)),
                ready: true, detail: nil, folderOwner: owner))
        }
        // Other members' workspaces, one row per workspace and harness: a task
        // is assigned to a harness on a workspace, not to one member's agent,
        // so this needs no choice among agents. Those this Mac already offers
        // through a Linux host it manages are skipped; Macs first, then by name.
        var seen = Set(configured.map { $0.configuration.id.uuidString.lowercased() + ":" + $0.harness.id.rawValue })
        let peers = remoteWorkspaceAgents.compactMap { agent -> (workspace: ExecutionWorkspace, runtimeKind: AgentRuntimeKind)? in
            guard let workspace = peerAgentWorkspaces[agent.id], !workspace.deleted, workspace.kind == .mac || workspace.kind == .linux,
                  seen.insert(ExecutionWorkspace.displayID(workspace.id) + ":" + agent.runtimeKind.rawValue).inserted else { return nil }
            return (workspace, agent.runtimeKind)
        }.sorted {
            ($0.workspace.kind == .mac ? 0 : 1, $0.workspace.name.lowercased(), $0.runtimeKind.displayName)
                < ($1.workspace.kind == .mac ? 0 : 1, $1.workspace.name.lowercased(), $1.runtimeKind.displayName)
        }
        for peer in peers where peer.workspace.id != own?.id {
            let owner = peer.workspace.folderOwnerID ?? peer.workspace.id
            let place = workspaceDisplayName(peer.workspace)
            targets.append(.init(id: "\(peer.workspace.id):\(peer.runtimeKind.rawValue)", group: .place(place),
                assignee: BoardTaskAssignee(kind: .agent, name: peer.runtimeKind.displayName, place: place,
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
}
