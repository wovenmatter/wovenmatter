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
    /// The runtime's settings, once the owner has reported them, with the
    /// choices the owner has not answered yet over them.
    var settings: SessionSettings? {
        guard var settings = reported else { return nil }
        settings.model = requested.model ?? settings.model
        settings.thinking = requested.thinking ?? settings.thinking
        settings.permission = requested.permission ?? settings.permission
        return settings
    }
    private var reported: SessionSettings?
    /// Choices sent to the owner that it has not answered yet.
    private var requested = SessionSettingsChange()
    /// The last change sent; each waits for the one before, and a send waits for all.
    @ObservationIgnored private var settingsChanges: Task<Void, Never>?
    /// Changes sent so far, and the latest one of each setting, which alone clears it.
    @ObservationIgnored private var changesSent = 0
    @ObservationIgnored private var latestChange = (model: 0, thinking: 0, permission: 0)
    private(set) var goal: WorkspaceGoal?
    private(set) var error: String?
    /// Its first view has arrived, or could not, so a chat switched to it shows it whole.
    private(set) var hasLoaded = false

    private var isFollowing = false
    private var run: RunState = .idle
    @ObservationIgnored private var items: [SessionItem] = []
    @ObservationIgnored private var inProgress: [LiveItem] = []
    /// Where the drawn part of each streaming reply or thinking trace ends, in UTF-8 bytes.
    @ObservationIgnored private var readyEnds: [String: Int] = [:]
    /// Each text item in progress: the reply that shows it, and that reply's text before it.
    @ObservationIgnored private var liveReplies: [String: (messageID: String, before: String)] = [:]
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
        if !hasLoaded {
            // A slow owner, or one that never answers, must not keep the chat from showing.
            Task { [weak self] in await self?.showSavedUnlessLive() }
        }
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
                        // Its saved items show, not an empty chat.
                        if !hasLoaded { Task { await self.showSaved() } }
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

    /// Shows the saved items after a second if the owner's snapshot has not
    /// come by then. They are read meanwhile, so they show at that moment.
    private func showSavedUnlessLive() async {
        let deadline = ContinuousClock.now + .seconds(1)
        let saved = try? await server?.call(SessionItems(sessionID: sessionID, beforeSequence: .max, limit: Self.pageSize))
        try? await Task.sleep(until: deadline)
        guard !hasLoaded else { return }
        if !isFollowing, let saved {
            items = items.joined(withNewer: saved)
            project()
        }
        hasLoaded = true
    }

    /// The most finished items read in one page.
    private static let pageSize = 200

    /// Reads the newest finished items again.
    func refresh() async {
        guard let server else { return }
        do {
            let saved = try await server.call(SessionItems(sessionID: sessionID, beforeSequence: .max, limit: Self.pageSize))
            // The owner's live snapshot, if it arrived meanwhile, is newer than the library's copy.
            guard !isFollowing else { return }
            items = items.joined(withNewer: saved)
            project()
        } catch {
            self.error = error.localizedDescription
        }
        hasLoaded = true
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
        // The choices made before it apply to it.
        await settingsChanges?.value
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
            switch draft {
            case .file(let file):
                if owner !== server {
                    let data = try await Task.detached { try Data(contentsOf: file.localURL) }.value
                    _ = try await owner.call(PutContent(data: data))
                }
                attachments.append(Attachment(name: file.fileName, mimeType: file.mimeType, digest: file.contentHash, size: file.sizeBytes))
            case .reference(let reference):
                guard let workspace else { throw ClientError.notConnected }
                let (data, attachment) = try await workspace.referenceAttachment(reference)
                if owner !== server { _ = try await owner.call(PutContent(data: data)) }
                attachments.append(attachment)
            }
        }
        error = nil
        _ = try await owner.call(SendTurn(sessionID: sessionID, text: input.text, attachments: attachments,
                                            context: input.visibleWorkspace?.promptContext))
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
            case .options(let ids) where prompt.fields.first?.kind == .choices:
                answer = .values([prompt.fields.first?.id ?? Self.freeTextField: .array(ids.map(JSONValue.string))])
            case .options(let ids): answer = ids.first.map(PromptAnswer.option) ?? .declined
            case .text(let text): answer = .text(text)
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
            executionStatus: nil, result: call.output, detail: nil, activity: nil, history: nil)
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
                                                                         allowsMultiple: false,
                                                                         acceptsOwnAnswer: prompt.fields.first?.ownAnswer ?? false)])
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
                    options: choices(field.options), acceptsOwnAnswer: field.ownAnswer,
                    initialValue: Self.formValue(field.initial), placeholder: field.placeholder,
                    multiline: field.multiline, minimum: counted ? nil : field.minimum, maximum: counted ? nil : field.maximum,
                    minimumLength: counted ? field.minimum.map { Int($0) } : nil,
                    maximumLength: counted ? field.maximum.map { Int($0) } : nil)
            })
        }
        return SessionInteraction(id: prompt.id, sessionID: sessionID, request: request)
    }

    /// Shows the choice at once and sends it to the owner after any sent
    /// before it. When the owner refuses it, what is in effect shows again.
    func updateSettings(_ change: SessionSettingsChange) async {
        changesSent += 1
        let number = changesSent
        if change.model != nil { requested.model = change.model; latestChange.model = number }
        if change.thinking != nil { requested.thinking = change.thinking; latestChange.thinking = number }
        if change.permission != nil { requested.permission = change.permission; latestChange.permission = number }
        let previous = settingsChanges
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await command { server in
                let configuration = try await server.call(ConfigureSession(
                    sessionID: self.sessionID, model: change.model, thinking: change.thinking, permission: change.permission))
                self.apply(configuration)
            }
            // A later choice of the same setting still waits for its answer.
            if latestChange.model == number { requested.model = nil }
            if latestChange.thinking == number { requested.thinking = nil }
            if latestChange.permission == number { requested.permission = nil }
        }
        settingsChanges = task
        await task.value
    }

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
        error = nil
        // Older pages the reader brought in stay above the snapshot's newest items.
        items = items.joined(withNewer: snapshot.items)
        inProgress = snapshot.inProgress
        readyEnds = [:]
        prompts = snapshot.prompts
        run = snapshot.run
        applyGoal(snapshot.session.goal)
        apply(snapshot.configuration)
        project()
        hasLoaded = true
    }

    private func apply(_ event: SessionEvent) {
        if updateInPlace(event) { return }
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
            readyEnds[itemID] = nil
        case .itemFinished(let item):
            inProgress.removeAll { $0.id == item.id }
            readyEnds[item.id] = nil
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
            applyGoal(configuration.goal)
        }
        project()
    }

    /// Streamed text and tool output change only the item in progress, so
    /// they update its message or activity where it is drawn, without
    /// rebuilding the transcript. Returns false when it is not drawn yet.
    /// A streaming reply is drawn a stable chunk at a time, so a delta that
    /// completes no chunk changes nothing the transcript reads, and streamed
    /// thinking and tool output are bounded the same way.
    private func updateInPlace(_ event: SessionEvent) -> Bool {
        switch event {
        case .text(let itemID, let delta):
            guard let index = inProgress.firstIndex(where: { $0.id == itemID }),
                  case .assistantMessage(let earlier) = inProgress[index].content,
                  let reply = liveReplies[itemID],
                  let shown = messages.lastIndex(where: { $0.id == reply.messageID }) else { return false }
            let text = earlier + delta
            inProgress[index].content = .assistantMessage(text: text)
            if readyGrew(itemID, in: text) { messages[shown].content = reply.before + text }
            return true
        case .toolOutput(let itemID, let delta):
            guard let index = inProgress.firstIndex(where: { $0.id == itemID }),
                  case .toolCall(var call) = inProgress[index].content,
                  let shown = runActivities.lastIndex(where: { $0.id == itemID }) else { return false }
            call.output = (call.output ?? "") + delta
            inProgress[index].content = .toolCall(call)
            let record = runActivities[shown]
            // Thinking shows a ready chunk at a time and tool output a line at
            // a time; the first words show at once.
            let drawn = record.activity.kind == .thought ? record.activity.content : record.activity.rawOutputJSON
            let grew = call.kind == .thinking ? readyGrew(itemID, in: call.output ?? "") : delta.contains(where: \.isNewline)
            guard grew || drawn?.isEmpty != false else { return true }
            runActivities[shown] = WorkspaceRunActivityRecord(
                id: record.id, runID: record.runID, conversationID: record.conversationID,
                activity: Self.activity(call, id: itemID, live: true, position: record.activity.position ?? 0),
                createdAt: record.createdAt, sequence: record.sequence)
            return true
        default:
            return false
        }
    }

    /// Whether the ready part of `text` now ends past where it was drawn, as
    /// `AssistantStreamingText` decides; the scan resumes at the last end.
    private func readyGrew(_ itemID: String, in text: String) -> Bool {
        let drawn = min(readyEnds[itemID] ?? 0, text.utf8.count)
        let origin = text.utf8.index(text.startIndex, offsetBy: drawn)
        let end = AssistantStreamingText.readyEnd(of: text, from: origin).map { text.utf8.distance(from: text.startIndex, to: $0) } ?? 0
        readyEnds[itemID] = end
        return end > drawn
    }

    private static func activity(_ call: ToolCall, id: String, live: Bool, position: Int) -> AgentRunActivity {
        let script = call.kind == .code
        let calls = script ? codeCalls(call.calls ?? [], live: live) : nil
        let questions = call.kind == .question
            ? (call.questions ?? []).enumerated().map { AgentRunQuestion(id: $0, title: $1.title, text: $1.text, answer: $1.answer) }
            : nil
        return AgentRunActivity(
            id: id, kind: call.kind == .thinking ? .thought : call.kind == .plan ? .plan : .tool,
            title: script ? (live ? "Running code" : call.failed ? "Code failed" : "Ran code")
                : questions.map { questionTitle($0, live: live, failed: call.failed) } ?? call.title ?? call.name,
            // The tools it called, each once; or what the questions were about.
            detail: questions.flatMap { questions in
                let names = questions.map { $0.title?.nonempty ?? $0.text }.filter { !$0.isEmpty }
                return names.isEmpty ? nil : names.joined(separator: ", ")
            } ?? calls.flatMap { calls in
                let names = calls.filter { $0.status != nil }.map(\.name).reduce(into: [String]()) { names, name in
                    if !names.contains(name) { names.append(name) }
                }
                return names.isEmpty ? nil : names.joined(separator: ", ")
            },
            status: live ? "running" : call.failed ? "failed" : "completed",
            toolName: call.name, content: call.kind == .thinking ? call.output : nil, position: position,
            planEntries: (call.plan ?? []).map { AgentRunPlanEntry(content: $0.text, status: $0.status.rawValue) },
            rawInputJSON: call.input, rawOutputJSON: call.output,
            subagents: call.kind == .task ? [child(call, id: id, live: live)] : nil,
            codeCalls: calls, questions: questions)
    }

    /// "Asking 2 questions" while they wait, then "Asked 2 questions"; or,
    /// when none was answered (dismissed, or the turn ended on them), "not
    /// answered". Before the questions arrive it is "a question".
    private static func questionTitle(_ questions: [AgentRunQuestion], live: Bool, failed: Bool) -> String {
        let several = questions.count > 1
        if failed { return several ? "Questions failed" : "Question failed" }
        if !live, !questions.isEmpty, questions.allSatisfy({ $0.answer == nil }) { return several ? "Questions not answered" : "Question not answered" }
        return (live ? "Asking " : "Asked ") + (several ? "\(questions.count) questions" : "a question")
    }

    /// A script's tool calls as its card lists them. One without output that
    /// has not failed is running while the script runs, and done after.
    private static func codeCalls(_ calls: [ToolCall], live: Bool) -> [AgentRunCodeCall] {
        calls.enumerated().map { index, call in
            // The entry that says how many more calls there were has no name.
            guard !call.name.isEmpty else { return AgentRunCodeCall(id: index, name: call.title ?? "", status: nil) }
            let status: AgentRunCodeCall.Status = call.failed ? .failed : live && call.output == nil ? .running
                : call.kind == .visualReply ? .shownInChat : .completed
            return AgentRunCodeCall(id: index, name: readableToolName(call.name), status: status,
                                    error: call.failed ? call.output : nil)
        }
    }

    /// A tool's name without the Woven server's prefix, as a script calls
    /// it (`woven.render_html`, `mcp__woven__render_html`).
    private static func readableToolName(_ name: String) -> String {
        for prefix in ["mcp__woven__", "mcp.woven.", "woven.", "woven_", "woven/"] where name.lowercased().hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    private static let timestamps = ISO8601DateFormatter()

    /// The one reply of a run.
    private static func replyID(_ runID: String) -> String { "reply-" + runID }

    private func apply(_ configuration: SessionConfiguration) {
        func metadata(_ options: [SessionOption]) -> [String: SessionOptionMetadata] {
            Dictionary(options.map { ($0.id, SessionOptionMetadata(name: $0.name, description: $0.detail)) },
                       uniquingKeysWith: { first, _ in first })
        }
        reported = SessionSettings(
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
    /// A run has one reply, whose identity holds from before its first words
    /// to its end: its text items join in order, and each finished one is also
    /// commentary, which the work log shows in place once work follows it.
    /// So text, tools and more text add to what is drawn and never move it.
    private func project() {
        var messages: [WorkspaceMessageRecord] = []
        var liveReplies: [String: (messageID: String, before: String)] = [:]
        var runs: [WorkspaceRunRecord] = []
        var activities: [WorkspaceRunActivityRecord] = []
        let entries = items.sorted { $0.sequence < $1.sequence }.map {
            (id: $0.id, date: $0.createdAt, content: $0.content, live: false, author: $0.author)
        } + inProgress.map { (id: $0.id, date: Date(), content: $0.content, live: true, author: ItemAuthor?.none) }
        var goneNotice: String?

        /// A turn that ended without a reply (it failed, or the person
        /// stopped it) still shows its work and how it ended, under an
        /// empty reply as a visual reply's turn does.
        func closeRun() {
            guard let last = runs.indices.last, runs[last].assistantMessageID == nil,
                  runs[last].status == .failed || activities.last?.runID == runs[last].id else { return }
            let id = Self.replyID(runs[last].id)
            messages.append(WorkspaceMessageRecord(id: id, conversationID: sessionID, role: .assistant, content: "",
                                                   status: .complete, createdAt: runs[last].completedAt ?? runs[last].startedAt ?? Date()))
            runs[last].assistantMessageID = id
        }

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
                closeRun()
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
                let id = Self.replyID(runs[run].id)
                let shown: Int
                if let index = messages.lastIndex(where: { $0.id == id }) {
                    shown = index
                } else {
                    messages.append(WorkspaceMessageRecord(id: id, conversationID: sessionID, role: .assistant, content: "",
                                                           status: .complete, createdAt: entry.date))
                    shown = messages.count - 1
                }
                if entry.live { liveReplies[entry.id] = (id, messages[shown].content) }
                messages[shown].content += text
                messages[shown].itemIDs.append(entry.id)
                messages[shown].status = entry.live ? .streaming : .complete
                if !entry.live {
                    activities.append(WorkspaceRunActivityRecord(
                        id: entry.id, runID: runs[run].id, conversationID: sessionID,
                        activity: AgentRunActivity(id: entry.id, kind: .assistant, content: text, assistantMessageID: id,
                                                   position: position),
                        createdAt: Self.timestamps.string(from: entry.date), sequence: Int64(position)))
                }
                runs[run].assistantMessageID = id
                if !entry.live { runs[run].completedAt = entry.date }
            case .toolCall(let call):
                let run = currentRun(at: entry.date)
                if !entry.live { runs[run].completedAt = entry.date }
                // A published visual reply shows as its own item; only a call that failed shows as a call.
                if call.kind == .visualReply && !call.failed { continue }
                activities.append(WorkspaceRunActivityRecord(
                    id: entry.id, runID: runs[run].id, conversationID: sessionID,
                    activity: Self.activity(call, id: entry.id, live: entry.live, position: position),
                    createdAt: Self.timestamps.string(from: entry.date), sequence: Int64(position)))
            case .visualReply(let reply):
                let run = currentRun(at: entry.date)
                runs[run].completedAt = entry.date
                // A visual reply is a reply even before any words, so its run is drawn.
                if runs[run].assistantMessageID == nil {
                    let id = Self.replyID(runs[run].id)
                    messages.append(WorkspaceMessageRecord(id: id, conversationID: sessionID, role: .assistant, content: "",
                                                           status: .complete, createdAt: entry.date))
                    runs[run].assistantMessageID = id
                }
                activities.append(WorkspaceRunActivityRecord(
                    id: entry.id, runID: runs[run].id, conversationID: sessionID,
                    activity: AgentRunActivity(
                        id: entry.id, kind: .activity, title: reply.title, status: "completed", position: position,
                        htmlRender: ConversationHTMLRenderReference(id: entry.id, title: reply.title, height: reply.height,
                                                                    digest: reply.digest)),
                    createdAt: Self.timestamps.string(from: entry.date), sequence: Int64(position)))
            case .notice(let notice):
                if notice.kind == .nativeSessionGone { goneNotice = entry.id }
                // A turn that failed or was stopped ended with that notice.
                if notice.kind == .failure || notice.kind == .interrupted, !runs.isEmpty {
                    runs[runs.count - 1].completedAt = entry.date
                }
                if notice.kind == .failure, !runs.isEmpty {
                    runs[runs.count - 1].status = .failed
                    runs[runs.count - 1].error = notice.text
                } else {
                    // A stopped turn's work shows before the notice that says it stopped.
                    if notice.kind == .interrupted { closeRun() }
                    messages.append(WorkspaceMessageRecord(id: entry.id, conversationID: sessionID, role: .system,
                                                           content: notice.text, status: .complete, createdAt: entry.date))
                }
            }
        }
        if run != .running { closeRun() }
        if run == .running, let last = runs.indices.last {
            runs[last].status = .running
            runs[last].completedAt = nil
            // Work before the first words of the reply shows under a reply that is still arriving.
            if runs[last].assistantMessageID == nil || messages.last?.role == .user {
                let id = Self.replyID(runs[last].id)
                messages.append(WorkspaceMessageRecord(id: id, conversationID: sessionID, role: .assistant, content: "",
                                                       status: .streaming, createdAt: Date()))
                runs[last].assistantMessageID = id
            }
        }
        self.liveReplies = liveReplies
        if goneNotice != goneNoticeID { goneNoticeID = goneNotice }
        let older = !noOlderItems && (items.map(\.sequence).min() ?? 1) > 1
        if older != hasOlderMessages { hasOlderMessages = older }
        self.messages = messages
        self.runs = runs
        runActivities = activities
        // The running turn's latest checklist, from its plan tool calls.
        let progress = run == .running ? runs.last.flatMap { ConversationTaskProgress.latest(in: activities, activeRunID: $0.id) } : nil
        if progress != taskProgress { taskProgress = progress }
        interactions = prompts.map(interaction)
    }
}
