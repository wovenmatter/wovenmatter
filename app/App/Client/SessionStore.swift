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
    var isOwnerReachable: Bool { isFollowing && server?.isConnected == true }
    /// A turn is running on the owner.
    var isRunning: Bool { run == .running }
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
    @ObservationIgnored private weak var server: ServerConnection?
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

    /// Subscribes to the owner's live view until the task is cancelled. Only
    /// this Mac's server is connected so far, so another machine's chat shows
    /// its saved items.
    func follow() async {
        guard let server else { return }
        await server.follow(
            SubscribeSession(sessionID: sessionID),
            reply: { [weak self] snapshot in self?.apply(snapshot) },
            event: { [weak self] event in self?.apply(event) },
            failure: { [weak self] failure in
                guard let self else { return }
                isFollowing = false
                if failure.code == .notOwner { Task { await self.refresh() } } else { error = failure.message }
            })
        isFollowing = false
    }

    /// Reads the finished items again.
    func refresh() async {
        guard let server else { return }
        do {
            items = try await server.call(SessionItems(sessionID: sessionID))
            project()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Pages in older messages. Returns whether any arrived.
    @discardableResult
    func loadOlderMessages() async -> Bool { false }

    func send(_ input: AgentMessageInput) async throws {
        guard let server, isOwnerReachable else { throw ClientError.notConnected }
        guard input.attachments.isEmpty else { throw ClientError.notOffered("Attachments") }
        error = nil
        _ = try await server.call(SendTurn(sessionID: sessionID, text: input.text))
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
        let choices = { (options: [PromptOption]) in options.map { SessionChoice(id: $0.id, label: $0.name, detail: $0.detail) } }
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
        throw ClientError.notOffered("Goals")
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

    private func command(_ body: (ServerConnection) async throws -> Void) async {
        guard let server, server.isConnected else { return error = ClientError.notConnected.localizedDescription }
        do {
            try await body(server)
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
        case .toolActivity(let itemID, let call):
            if let index = inProgress.firstIndex(where: { $0.id == itemID }) { inProgress[index].content = .toolCall(call) }
        case .itemDropped(let itemID):
            inProgress.removeAll { $0.id == itemID }
        case .itemFinished(let item):
            inProgress.removeAll { $0.id == item.id }
            if !items.contains(where: { $0.id == item.id }) { items.append(item) }
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
        let entries = items.sorted { $0.sequence < $1.sequence }.map { (id: $0.id, date: $0.createdAt, content: $0.content, live: false) }
            + inProgress.map { (id: $0.id, date: Date(), content: $0.content, live: true) }
        let formatter = ISO8601DateFormatter()

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
                messages.append(WorkspaceMessageRecord(
                    id: entry.id, conversationID: sessionID, role: .user, content: text, status: .complete, createdAt: entry.date,
                    attachments: attachments.map {
                        SessionMessageAttachment(id: $0.digest, kind: $0.mimeType.hasPrefix("image/") ? .image : .file,
                                                 fileName: $0.name, mimeType: $0.mimeType, sizeBytes: $0.size, contentHash: $0.digest)
                    }))
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
                        rawInputJSON: call.input, rawOutputJSON: call.output),
                    createdAt: formatter.string(from: entry.date), sequence: Int64(position)))
            case .notice(let notice):
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
        self.messages = messages
        self.runs = runs
        runActivities = activities
        interactions = prompts.map(interaction)
    }
}
