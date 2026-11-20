import Foundation
import Observation
import WovenProtocol

/// One open chat, fed by the owning machine's server: its finished items, the
/// item in progress, run state, questions and approvals, settings, goal and
/// task progress. Commands send, stop, answer, change settings and page back.
@MainActor
@Observable
final class SessionStore {
    let sessionID: String
    let transcriptState = ConversationTranscriptState()

    /// Messages in order, the item in progress last while it streams.
    private(set) var messages: [WorkspaceMessageRecord] = []
    private(set) var runs: [WorkspaceRunRecord] = []
    private(set) var runActivities: [WorkspaceRunActivityRecord] = []
    private(set) var messagePresentations: [String: MessagePresentation] = [:]
    private(set) var runPresentations: [String: RunPresentation] = [:]
    private(set) var taskProgress: ConversationTaskProgress?
    private(set) var hasOlderMessages = false
    private(set) var isLoadingOlderMessages = false

    /// False while the owning machine cannot be reached: its saved items show and sending is disabled.
    var isOwnerReachable: Bool { isFollowing && owner?.isConnected == true }
    /// A turn is running on the owner.
    var isRunning: Bool { run == .running }
    /// The runtime no longer has this chat's native session: it can only be read.
    var isNativeSessionGone: Bool { run == .nativeSessionGone }
    /// The notice that says so, which offers a new session.
    private(set) var goneNoticeID: String?
    /// Questions, approvals and forms the running turn waits on.
    private(set) var interactions: [SessionInteraction] = []
    /// The runtime's settings, once the owner has reported them.
    private(set) var settings: SessionSettings?
    private(set) var isLoadingSettings = false
    private(set) var isUpdatingSettings = false
    private(set) var goal: WorkspaceGoal?
    /// A macOS permission the owning Mac is missing for this session.
    private(set) var macAccessNotice: MacAccessSessionNotice?
    private(set) var error: String?

    private var isFollowing = false
    private var run: RunState = .idle
    @ObservationIgnored private var items: [SessionItem] = []
    @ObservationIgnored private var inProgress: [LiveItem] = []
    @ObservationIgnored private var prompts: [Prompt] = []
    /// This Mac's server, which answers `SessionItems` from its synced library.
    @ObservationIgnored private weak var server: ServerConnection?
    /// The owning machine's server, which runs the session and streams it.
    private var owner: ServerConnection?
    /// The owner a `notOwner` refusal named, when the library said otherwise.
    @ObservationIgnored private var namedOwnerID: String?
    @ObservationIgnored private weak var workspace: WorkspaceStore?

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func attach(_ server: ServerConnection?, workspace: WorkspaceStore) {
        self.server = server
        self.workspace = workspace
    }

    var hasUserMessage: Bool { messages.contains { $0.role == .user } }

    func setError(_ error: String?) {
        self.error = error
    }

    // MARK: Commands

    /// Follows the owner's live view until the task is cancelled, over the
    /// UI's own connection to the owning machine's server. While that
    /// connection is down the saved items from this Mac's server show and
    /// sending is disabled; when it returns the live view resumes on its own.
    func follow() async {
        while !Task.isCancelled {
            guard let owner = ownerConnection() else {
                self.owner = nil
                await showSaved()
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            self.owner = owner
            let live = Task { [weak self, sessionID] in
                await owner.follow(
                    SubscribeSession(sessionID: sessionID),
                    reply: { [weak self] snapshot in self?.apply(snapshot) },
                    event: { [weak self] event in self?.apply(event) },
                    failure: { [weak self] failure in
                        guard let self else { return }
                        isFollowing = false
                        if failure.code == .notOwner, let machineID = failure.machineID {
                            namedOwnerID = machineID
                        } else {
                            error = failure.message
                        }
                    })
            }
            // Until the owner's connection is replaced; saved items while it is down.
            while !Task.isCancelled, ownerConnection() === owner {
                if !owner.isConnected { await showSaved() }
                try? await Task.sleep(for: .milliseconds(500))
            }
            live.cancel()
        }
        isFollowing = false
    }

    /// The owner's connection: the machine the library names, or the one a refusal named.
    private func ownerConnection() -> ServerConnection? {
        workspace?.ownerConnection(ofSession: sessionID, ownerID: namedOwnerID)
    }

    /// Leaves the live view for the saved items, once each time the owner is lost.
    private func showSaved() async {
        guard isFollowing || items.isEmpty && !hasReadSaved else { return }
        isFollowing = false
        hasReadSaved = true
        inProgress = []
        prompts = []
        run = .idle
        await refresh()
    }
    @ObservationIgnored private var hasReadSaved = false

    /// The most finished items read in one page.
    private static let pageSize = 200

    /// Reads the newest finished items again.
    func refresh() async {
        guard let server else { return }
        do {
            items = try await server.call(SessionItems(sessionID: sessionID, beforeSequence: .max, limit: Self.pageSize))
            project()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Pages in older messages from this Mac's server. Returns whether any arrived.
    @discardableResult
    func loadOlderMessages() async -> Bool {
        guard let server, let oldest = items.map(\.sequence).min(), oldest > 1, !isLoadingOlderMessages else { return false }
        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }
        do {
            let older = try await server.call(SessionItems(sessionID: sessionID, beforeSequence: oldest, limit: Self.pageSize))
            let known = Set(items.map(\.id))
            items = older.filter { !known.contains($0.id) } + items
            if older.isEmpty { noOlderItems = true }
            project()
            return !older.isEmpty
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    /// A page back found nothing, though the sequence suggested more.
    @ObservationIgnored private var noOlderItems = false

    /// Sends a turn to the owner. Attachments go into the owner's content store
    /// first, since the turn refers to them by digest.
    func send(_ input: AgentMessageInput) async throws {
        guard let owner, isOwnerReachable else { throw ClientError.notConnected }
        // `/goal OBJECTIVE` sets the session's goal, which the owner works toward on every runtime.
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.attachments.isEmpty, text.lowercased().hasPrefix("/goal ") {
            error = nil
            applyGoal(try await owner.call(SetGoal(sessionID: sessionID, goal: String(text.dropFirst(6)))).goal)
            return
        }
        var attachments: [Attachment] = []
        for draft in input.attachments {
            guard case .file(let file) = draft else { throw ClientError.notOffered("Attaching notes and chats") }
            if owner !== server {
                let data = try await Task.detached { try Data(contentsOf: file.localURL) }.value
                _ = try await owner.call(PutContent(data: data))
            }
            attachments.append(Attachment(name: file.fileName, mimeType: file.mimeType, digest: file.contentHash, size: file.sizeBytes))
        }
        error = nil
        _ = try await owner.call(SendTurn(sessionID: sessionID, text: input.text, attachments: attachments))
    }

    func stop() async {
        await command { _ = try await $0.call(InterruptTurn(sessionID: self.sessionID)) }
    }

    func answer(_ interactionID: String, with response: SessionInteractionResponse) async {
        guard let prompt = prompts.first(where: { $0.id == interactionID }) else { return }
        let answer: PromptAnswer
        switch response {
        case .option(let id): answer = .option(id)
        case .answers(let answers):
            switch answers.values.first {
            case .single(let id): answer = .option(id)
            case .multiple(let ids): answer = .values([prompt.fields.first?.id ?? "answer": .array(ids.map(JSONValue.string))])
            case nil: answer = .declined
            }
        case .formValues(let values):
            if prompt.fields.isEmpty, case .string(let text)? = values[Self.freeTextField] {
                answer = .text(text)
            } else {
                answer = .values(values.mapValues(Self.json))
            }
        case .cancelled: answer = .declined
        }
        await command { _ = try await $0.call(AnswerPrompt(sessionID: self.sessionID, promptID: interactionID, answer: answer)) }
    }

    /// A child task as the transcript's subagent row shows it.
    private static func child(_ call: ToolCall, id: String, live: Bool) -> AgentRunSubagent {
        let task = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(call.input.utf8)))
            .flatMap { input -> String? in
                if case .string(let text)? = input["prompt"] ?? input["description"] { text } else { nil }
            }
        return AgentRunSubagent(
            id: id, name: call.title, task: task, modelID: nil, provider: nil, connectionID: nil, connectionLabel: nil,
            accessKind: nil, thinking: nil, state: live ? "running" : call.failed ? "failed" : "completed",
            executionStatus: nil, result: call.output, detail: nil, activity: nil, history: nil, sourceID: nil,
            nativeSessionID: nil, nativeConversationID: nil)
    }

    /// The one field of a question answered in free text.
    private static let freeTextField = "answer"

    private static func json(_ value: SessionFormValue) -> JSONValue {
        switch value {
        case .string(let text): .string(text)
        case .strings(let values): .array(values.map(JSONValue.string))
        case .number(let number): number.rounded() == number && abs(number) < 1e15 ? .integer(Int64(number)) : .double(number)
        case .boolean(let flag): .bool(flag)
        }
    }

    private static func formValue(_ value: JSONValue?) -> SessionFormValue? {
        switch value {
        case .string(let text): .string(text)
        case .array(let values): .strings(values.compactMap { if case .string(let text) = $0 { text } else { nil } })
        case .integer(let number): .number(Double(number))
        case .double(let number): .number(number)
        case .bool(let flag): .boolean(flag)
        default: nil
        }
    }

    /// A prompt in the one card shape the chat shows.
    private func interaction(_ prompt: Prompt) -> SessionInteraction {
        let choices = { (options: [PromptOption]) in options.map { SessionChoice(id: $0.id, label: $0.name, detail: $0.detail, allowsOnce: $0.allowsOnce) } }
        let request: SessionInteraction.Request
        switch prompt.kind {
        case .approval:
            request = .approval(title: prompt.text, options: choices(prompt.options))
        case .question where !prompt.options.isEmpty:
            request = .questions(title: nil, questions: [SessionQuestion(id: prompt.fields.first?.id ?? Self.freeTextField,
                                                                         prompt: prompt.text, options: choices(prompt.options),
                                                                         allowsMultiple: false)])
        case .question, .form:
            let fields = prompt.fields.isEmpty
                ? [PromptField(id: Self.freeTextField, title: "Answer", multiline: true)] : prompt.fields
            request = .form(message: prompt.text, fields: fields.map { field in
                let kind: SessionFormField.Kind = switch field.kind {
                case .text: .text
                case .choice: .singleChoice
                case .choices: .multipleChoice
                case .number: .number
                case .integer: .integer
                case .boolean: .boolean
                }
                let counted = field.kind == .text || field.kind == .choices
                return SessionFormField(
                    id: field.id, title: field.title, detail: field.detail, kind: kind, required: field.required,
                    options: choices(field.options), initialValue: Self.formValue(field.initial), placeholder: field.placeholder,
                    multiline: field.multiline, minimum: counted ? nil : field.minimum, maximum: counted ? nil : field.maximum,
                    minimumLength: counted ? field.minimum.map { Int($0) } : nil,
                    maximumLength: counted ? field.maximum.map { Int($0) } : nil)
            })
        }
        return SessionInteraction(id: prompt.id, sessionID: sessionID, request: request)
    }

    func updateSettings(_ change: SessionSettingsChange) async {
        isUpdatingSettings = true
        defer { isUpdatingSettings = false }
        await command { server in
            let configuration = try await server.call(ConfigureSession(
                sessionID: self.sessionID, model: change.model, thinking: change.thinking, permission: change.permission))
            self.apply(configuration)
        }
    }

    func refreshSettings() async {}

    func updateGoal(_ mutation: WorkspaceGoalMutation) async throws {
        guard let owner, isOwnerReachable else { throw ClientError.notConnected }
        switch mutation {
        case .clear: applyGoal(try await owner.call(SetGoal(sessionID: sessionID, goal: nil)).goal)
        }
    }

    private func applyGoal(_ objective: String?) {
        let value = objective.map { WorkspaceGoal(id: sessionID, objective: $0) }
        if value != goal { goal = value }
    }

    /// Moves a chat with no messages yet to another folder of its machine.
    func chooseFolder(_ folderID: String?) async throws {
        guard let workspace else { throw ClientError.notConnected }
        try await workspace.mutateConversation(id: sessionID, mutation: .moveToFolder(folderID))
    }

    /// One activity's complete record, when the transcript's copy omits its details.
    func activityDetails(runID: String, activityID: String) async throws -> AgentRunActivity? {
        runActivities.first { $0.runID == runID && $0.activity.id == activityID }?.activity
    }

    func subagentHistory(_ request: SubagentArchiveRequest) async throws -> SubagentArchivePage {
        throw ClientError.notOffered("Subagent history")
    }

    /// Runs `body` on the owner's connection.
    private func command(_ body: (ServerConnection) async throws -> Void) async {
        guard let owner, owner.isConnected else { return error = ClientError.notConnected.localizedDescription }
        do {
            try await body(owner)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: The live view

    private func apply(_ snapshot: SessionSnapshot) {
        isFollowing = true
        items = snapshot.items
        inProgress = snapshot.inProgress
        prompts = snapshot.prompts
        run = snapshot.run
        applyGoal(snapshot.session.goal)
        apply(snapshot.configuration)
        project()
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case .itemStarted(let item):
            inProgress.removeAll { $0.id == item.id }
            inProgress.append(item)
        case .text(let itemID, let delta):
            if let index = inProgress.firstIndex(where: { $0.id == itemID }),
               case .assistantMessage(let text) = inProgress[index].content {
                inProgress[index].content = .assistantMessage(text: text + delta)
            }
        case .toolActivity(let itemID, var call):
            if let index = inProgress.firstIndex(where: { $0.id == itemID }) {
                if call.output?.isEmpty ?? true, case .toolCall(let previous) = inProgress[index].content { call.output = previous.output }
                inProgress[index].content = .toolCall(call)
            }
        case .toolOutput(let itemID, let delta):
            if let index = inProgress.firstIndex(where: { $0.id == itemID }), case .toolCall(var call) = inProgress[index].content {
                call.output = (call.output ?? "") + delta
                inProgress[index].content = .toolCall(call)
            }
        case .itemDropped(let itemID):
            inProgress.removeAll { $0.id == itemID }
        case .itemFinished(let item):
            inProgress.removeAll { $0.id == item.id }
            if !items.contains(where: { $0.id == item.id }) { items.append(item) }
            if case .notice(let notice) = item.content, notice.kind == .goalMet { applyGoal(nil) }
        case .runState(let state):
            run = state
        case .awaiting(let prompt):
            prompts.removeAll { $0.id == prompt.id }
            prompts.append(prompt)
        case .answered(let promptID):
            prompts.removeAll { $0.id == promptID }
        case .configuration(let configuration):
            apply(configuration)
        }
        project()
    }

    private func apply(_ configuration: SessionConfiguration) {
        func metadata(_ options: [SessionOption]) -> [String: SessionOptionMetadata] {
            Dictionary(options.map { ($0.id, SessionOptionMetadata(name: $0.name, description: $0.detail)) },
                       uniquingKeysWith: { first, _ in first })
        }
        settings = SessionSettings(
            model: configuration.model, thinking: configuration.thinking, permission: configuration.permission,
            modelOptions: configuration.models.map(\.id), thinkingLevels: configuration.thinkingLevels.map(\.id),
            permissionOptions: configuration.permissionModes.map(\.id),
            modelOptionMetadata: metadata(configuration.models),
            thinkingOptionMetadata: metadata(configuration.thinkingLevels),
            permissionOptionMetadata: metadata(configuration.permissionModes),
            slashCommands: configuration.commands.map { SessionSlashCommand(name: $0.name, detail: $0.detail, argumentHint: $0.hint) })
    }

    /// Rebuilds what the transcript draws: each user message starts a run, and
    /// the assistant messages and tool calls after it belong to that run.
    private func project() {
        var messages: [WorkspaceMessageRecord] = []
        var runs: [WorkspaceRunRecord] = []
        var activities: [WorkspaceRunActivityRecord] = []
        let entries = items.sorted { $0.sequence < $1.sequence }.map {
            (id: $0.id, date: $0.createdAt, content: $0.content, live: false, author: $0.author)
        } + inProgress.map { (id: $0.id, date: Date(), content: $0.content, live: true, author: ItemAuthor?.none) }
        let formatter = ISO8601DateFormatter()
        var goneNotice: String?

        func currentRun(at date: Date) -> Int {
            if runs.isEmpty {
                runs.append(WorkspaceRunRecord(id: "run-start-\(sessionID)", conversationID: sessionID, status: .completed,
                                               startedAt: date, completedAt: date))
            }
            return runs.count - 1
        }

        for (position, entry) in entries.enumerated() {
            switch entry.content {
            case .userMessage(let text, let attachments):
                // A goal's turns and a timer's or wake-up's prompts are marked as such.
                let sender: WorkspaceSessionDeliveryKind? = switch entry.author?.source {
                case .goal: .goal
                case .timer, .wakeUp: .timer
                default: nil
                }
                messages.append(WorkspaceMessageRecord(
                    id: entry.id, conversationID: sessionID, role: .user, content: text, status: .complete, createdAt: entry.date,
                    attachments: attachments.map {
                        SessionMessageAttachment(id: $0.digest, kind: $0.mimeType.hasPrefix("image/") ? .image : .file,
                                                 fileName: $0.name, mimeType: $0.mimeType, sizeBytes: $0.size, contentHash: $0.digest)
                    }, senderKind: sender, senderSessionID: sender == nil ? nil : sessionID))
                runs.append(WorkspaceRunRecord(id: "run-\(entry.id)", conversationID: sessionID, status: .completed,
                                               userMessageID: entry.id, startedAt: entry.date, completedAt: entry.date))
            case .assistantMessage(let text):
                let run = currentRun(at: entry.date)
                messages.append(WorkspaceMessageRecord(id: entry.id, conversationID: sessionID, role: .assistant, content: text,
                                                       status: entry.live ? .streaming : .complete, createdAt: entry.date))
                runs[run].assistantMessageID = entry.id
                runs[run].completedAt = entry.date
            case .toolCall(let call):
                let run = currentRun(at: entry.date)
                activities.append(WorkspaceRunActivityRecord(
                    id: entry.id, runID: runs[run].id, conversationID: sessionID,
                    activity: AgentRunActivity(
                        id: entry.id, kind: call.kind == .thinking ? .thought : call.kind == .plan ? .plan : .tool,
                        title: call.title ?? call.name, status: entry.live ? "running" : call.failed ? "failed" : "completed",
                        toolName: call.name, content: call.kind == .thinking ? call.output : nil, position: position,
                        planEntries: (call.plan ?? []).map { AgentRunPlanEntry(content: $0.text, status: $0.status.rawValue) },
                        rawInputJSON: call.input, rawOutputJSON: call.output,
                        subagents: call.kind == .task ? [Self.child(call, id: entry.id, live: entry.live)] : nil),
                    createdAt: formatter.string(from: entry.date), sequence: Int64(position)))
            case .notice(let notice):
                if notice.kind == .nativeSessionGone { goneNotice = entry.id }
                if notice.kind == .failure, !runs.isEmpty {
                    runs[runs.count - 1].status = .failed
                    runs[runs.count - 1].error = notice.text
                } else {
                    messages.append(WorkspaceMessageRecord(id: entry.id, conversationID: sessionID, role: .system,
                                                           content: notice.text, status: .complete, createdAt: entry.date))
                }
            }
        }
        if run == .running, let last = runs.indices.last {
            runs[last].status = .running
            runs[last].completedAt = nil
            // Work before the first words of the reply shows under a reply that is still arriving.
            if runs[last].assistantMessageID == nil || messages.last?.role == .user {
                let id = "reply-\(runs[last].id)"
                messages.append(WorkspaceMessageRecord(id: id, conversationID: sessionID, role: .assistant, content: "",
                                                       status: .streaming, createdAt: Date()))
                runs[last].assistantMessageID = id
            }
        }
        if goneNotice != goneNoticeID { goneNoticeID = goneNotice }
        let older = !noOlderItems && (items.map(\.sequence).min() ?? 1) > 1
        if older != hasOlderMessages { hasOlderMessages = older }
        self.messages = messages
        self.runs = runs
        runActivities = activities
        interactions = prompts.map(interaction)
    }
}
