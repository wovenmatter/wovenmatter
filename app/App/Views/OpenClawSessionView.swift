import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct OpenClawSessionLibrary: View {
    let model: ApplicationModel
    let agentID: UUID
    @State private var sessions: [OpenClawGatewaySession] = []
    @State private var nextOffset: Int?
    @State private var currentOffset = 0
    @State private var busy = false
    @State private var feedback: String?

    var body: some View {
        SettingsCard(title: "Shared OpenClaw sessions", detail: "Continue an existing session from OpenClaw without copying or starting a new chat. Imported sessions appear in this agent’s conversation list.") {
            HStack {
                Button("Refresh sessions") { load(offset: 0) }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
            ForEach(sessions) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title).font(.system(size: 13, weight: .medium))
                        Text(session.key).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DashboardPalette.mutedForeground).lineLimit(2)
                    }
                    Spacer()
                    Button("Import") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                try await model.importOpenClawSession(agentID: agentID, session: session)
                                feedback = "“\(session.title)” is available in the conversation list."
                            } catch { feedback = error.localizedDescription }
                        }
                    }.disabled(busy)
                }
            }
            HStack {
                Button("Previous") { load(offset: max(0, currentOffset - 25)) }
                    .disabled(busy || currentOffset == 0)
                Text("Page \(currentOffset / 25 + 1) of up to 10").font(.caption)
                Button("Next") { if let nextOffset { load(offset: nextOffset) } }
                    .disabled(busy || nextOffset == nil || currentOffset >= 225)
            }
            if let feedback { Text(feedback).font(.system(size: 12)).textSelection(.enabled) }
        }
    }

    private func load(offset: Int) {
        busy = true; feedback = nil
        Task {
            defer { busy = false }
            do {
                let page = try await model.openClawNativeSessions(agentID: agentID, offset: offset)
                sessions = page.sessions
                currentOffset = offset
                nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
                if sessions.isEmpty { feedback = "No shared sessions are available." }
            } catch { feedback = error.localizedDescription }
        }
    }
}

struct OpenClawSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let model: ApplicationModel
    let conversationID: String
    @State private var snapshot: OpenClawGatewayControls?
    @State private var busy = false
    @State private var error: String?
    @State private var refreshRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("OpenClaw session").font(.title2.weight(.semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Refresh") { perform { try await reload() } }.disabled(busy)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let snapshot {
                        Text(snapshot.sessionKey).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DashboardPalette.mutedForeground).textSelection(.enabled)
                        SettingsCard(title: "Session controls", detail: "Model and thinking are available in the composer. Changes here affect this shared OpenClaw session on every client.") {
                            HStack {
                                settingMenu("Fast mode", setting: .fastMode, choices: ["on", "off"])
                                settingMenu("Reasoning", setting: .reasoningLevel, choices: ["off", "on", "stream"])
                                settingMenu("Verbosity", setting: .verboseLevel, choices: ["off", "on", "full"])
                                settingMenu("Usage", setting: .responseUsage, choices: ["off", "tokens", "full"])
                            }
                            Menu("Reset to agent default") {
                                ForEach(OpenClawSessionSetting.allCases, id: \.rawValue) { setting in
                                    Button(setting.rawValue) { perform { try await model.setOpenClawSetting(setting, value: .null, snapshot: snapshot) } }
                                }
                            }
                            Button("Stop OpenClaw work in this session", role: .destructive) {
                                perform {
                                    try await model.stopOpenClawSession(snapshot: snapshot)
                                    try await reload()
                                }
                            }
                            if let url = snapshot.controlUIURL {
                                Button("Open OpenClaw Control UI…") { openURL(url) }
                                Text("Opens in your browser with its own sign-in. Includes media, account management, and plugin screens.")
                                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            }
                        }
                        SettingsCard(title: "Approvals", detail: "Pending approvals for this session and its child sessions. Review the complete request before deciding.") {
                            if snapshot.approvals.isEmpty { Text("No pending approvals.") }
                            ForEach(Array(snapshot.approvals.enumerated()), id: \.offset) { _, approval in
                                approvalRow(approval, snapshot: snapshot)
                            }
                            if snapshot.approvalsTruncated { Text("More approvals are available in OpenClaw Control UI.") }
                        }
                        SettingsCard(title: "Questions", detail: "Answers go to this OpenClaw session. Secret-store questions must be answered in OpenClaw Control UI.") {
                            if snapshot.questions.isEmpty { Text("No pending questions.") }
                            ForEach(snapshot.questions.compactMap(OpenClawQuestionRecord.init)) { record in
                                OpenClawQuestionForm(record: record.value, disabled: busy) { id, answers in
                                    perform {
                                        try await model.answerOpenClawQuestion(id: id, answers: answers, snapshot: snapshot)
                                        try await reload()
                                    }
                                }
                            }
                        }
                    }
                    if let error { SettingsError(error) }
                }
            }
            .disabled(busy)
        }
        .padding(24)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 480, idealHeight: 680)
        .task { perform { try await reload() } }
        .task(id: conversationID) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !busy else { continue }
                let revision = refreshRevision
                do {
                    let updated = try await model.openClawSessionControls(conversationID: conversationID)
                    guard !Task.isCancelled, !busy, revision == refreshRevision else { continue }
                    snapshot = updated
                    error = nil
                } catch {
                    guard !Task.isCancelled, !busy, revision == refreshRevision else { continue }
                    self.error = error.localizedDescription
                    snapshot = nil
                }
            }
        }
    }

    private func settingMenu(_ title: String, setting: OpenClawSessionSetting, choices: [String]) -> some View {
        Menu(title) {
            ForEach(choices, id: \.self) { value in
                Button(value.capitalized) {
                    guard let snapshot else { return }
                    perform { try await model.setOpenClawSetting(setting, value: setting == .fastMode ? .bool(value == "on") : .string(value), snapshot: snapshot) }
                }
            }
        }
    }

    @ViewBuilder private func approvalRow(_ value: GatewayJSONValue, snapshot: OpenClawGatewayControls) -> some View {
        if let row = value.objectValue, let id = row["id"]?.stringValue,
           let presentation = row["presentation"]?.objectValue {
            VStack(alignment: .leading, spacing: 10) {
                Text(presentation["title"]?.stringValue ?? presentation["commandText"]?.stringValue ?? "OpenClaw approval")
                    .font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                // Render all reviewer-safe fields, including blast radius and warning text.
                Text(Self.pretty(value: .object(presentation)))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                HStack {
                    ForEach(["deny", "allow-once"], id: \.self) { decision in
                        if presentation["allowedDecisions"]?.arrayValue?.contains(.string(decision)) == true {
                            Button(decision == "deny" ? "Deny" : "Allow once") {
                                perform {
                                    try await model.resolveOpenClawApproval(id: id, decision: decision, snapshot: snapshot)
                                    try await reload()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func pretty(value: GatewayJSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func reload() async throws {
        snapshot = try await model.openClawSessionControls(conversationID: conversationID)
        _ = try await model.loadOpenClawHistory(conversationID: conversationID)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        refreshRevision += 1
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch {
                snapshot = nil
                self.error = error.localizedDescription + " Refresh before retrying a decision."
            }
        }
    }
}

// Keep drafts attached to their request when an earlier question disappears.
private struct OpenClawQuestionRecord: Identifiable {
    let id: String
    let value: GatewayJSONValue

    init?(_ value: GatewayJSONValue) {
        guard let id = value.objectValue?["id"]?.stringValue else { return nil }
        self.id = id
        self.value = value
    }
}

private struct OpenClawQuestionForm: View {
    let record: GatewayJSONValue
    let disabled: Bool
    let submit: (String, [String: [String]]) -> Void
    @State private var answers: [String: [String]] = [:]
    @State private var freeText: [String: String] = [:]
    private var questions: [GatewayJSONValue] { record.objectValue?["questions"]?.arrayValue ?? [] }
    private var requiresControlUI: Bool {
        questions.contains { $0.objectValue?["isSecret"]?.boolValue == true || $0.objectValue?["secretStore"]?.objectValue != nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, value in
                if let question = value.objectValue, let id = question["questionId"]?.stringValue {
                    Text(question["question"]?.stringValue ?? "Question").font(.system(size: 13, weight: .medium))
                    if !requiresControlUI {
                        ForEach(Array((question["options"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, option in
                            if let label = option.objectValue?["label"]?.stringValue {
                                Toggle(isOn: Binding(get: { answers[id, default: []].contains(label) }, set: { selected in
                                    if question["multiSelect"]?.boolValue != true {
                                        answers[id] = selected ? [label] : []
                                        if selected { freeText[id] = nil }
                                    }
                                    else if selected { answers[id, default: []].append(label) }
                                    else { answers[id]?.removeAll { $0 == label } }
                                })) {
                                    VStack(alignment: .leading) {
                                        Text(label)
                                        if let detail = option.objectValue?["description"]?.stringValue {
                                            Text(detail).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                                        }
                                    }
                                }.toggleStyle(.checkbox)
                            }
                        }
                        if question["isOther"]?.boolValue == true || question["options"]?.arrayValue?.isEmpty == true {
                            TextField("Your answer", text: Binding(get: { freeText[id, default: ""] }, set: { freeText[id] = $0 }))
                                .settingsInput()
                        }
                    }
                }
            }
            if requiresControlUI { Text("Open this question in OpenClaw Control UI to manage secret storage.").font(.caption) }
            else {
                Button("Send answer") {
                    guard let id = record.objectValue?["id"]?.stringValue else { return }
                    submit(id, resolvedAnswers)
                }.disabled(disabled || !questions.allSatisfy { !(resolvedAnswers[$0.objectValue?["questionId"]?.stringValue ?? ""] ?? []).isEmpty })
            }
        }
    }
    private var resolvedAnswers: [String: [String]] {
        OpenClawQuestionAnswers.resolve(questions: questions, selected: answers, freeText: freeText)
    }
}
