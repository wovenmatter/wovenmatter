import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterClient
import WovenMatterCore

struct OpenClawCronSurface: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    @Binding var provider: String
    let onOpenConversation: (String) -> Void
    @State private var showsDeleted = false
    @State private var selectedAgentID: UUID?
    @State private var editor: CronEditorSelection?
    @State private var deletingJob: OpenClawCronJob?

    private struct CronEditorSelection: Identifiable {
        let id = UUID()
        let agentID: UUID
        var job: OpenClawCronJob?
    }

    private var agents: [WorkspaceAgent] {
        let all = model.localCLIAgents
            + model.remoteWorkspaceAgents
            + model.buzzWorkspaceAgents
        return all.filter {
            $0.runtimeKind == .openclaw && model.isOpenClawGatewayLinked(agentID: $0.id)
        }
    }

    private var jobs: [OpenClawCronJob] {
        let filtered = model.openClawCronJobs.filter {
            (showsDeleted ? $0.archiveState == .deleted : $0.archiveState == .active)
                && (selectedAgentID == nil || $0.agentID == selectedAgentID)
        }
        return OpenClawCronOrdering.latestExecutionFirst(
            jobs: filtered,
            runs: model.openClawCronRuns
        )
    }

    private var heartbeatAgent: WorkspaceAgent? {
        if let selectedAgentID {
            return agents.first { $0.id == selectedAgentID }
        }
        return agents.count == 1 ? agents.first : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    DashboardLucideIcon(glyph: .calendarClockControl, size: 18)
                        .foregroundStyle(DashboardPalette.primary)
                        .frame(width: 36, height: 36)
                        .background(DashboardPalette.muted)
                        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
                    Text("Cron Jobs").font(.system(size: 22, weight: .semibold))
                    Spacer(minLength: 16)
                    DashboardSegmentedSelector(
                        options: ["Hermes", "OpenClaw"],
                        selection: $provider
                    ) { $0 }
                    .frame(width: 220)
                }
                ViewThatFits(in: .horizontal) {
                    openClawHeaderActions
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            agentPicker
                            deletedToggle
                            refreshButton
                        }
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            emptyTrashButton
                            newJobButton
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)
            .padding(.bottom, 20)

            if let error = model.openClawCronError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.danger)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            heartbeatSection
                .padding(.horizontal, 32)
                .padding(.bottom, 16)

            if jobs.isEmpty {
                DashboardConversationEmptyState(
                    icon: .calendarClockControl,
                    title: showsDeleted ? "Cron Trash is empty" : "No scheduled jobs",
                    detail: showsDeleted
                        ? "Deleted jobs and their retained results appear here."
                        : agents.isEmpty
                            ? "Connect OpenClaw in Settings to schedule jobs."
                            : "Create a job to get started."
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(jobs) { job in cronJob(job) }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.never)
            }
        }
        .background(theme.palette.workspace)
        .sheet(item: $editor) { selection in
            OpenClawCronEditor(model: model, agentID: selection.agentID, job: selection.job)
        }
        .confirmationDialog("Delete this scheduled job?", isPresented: Binding(
            get: { deletingJob != nil }, set: { if !$0 { deletingJob = nil } }
        ), titleVisibility: .visible) {
            if let job = deletingJob {
                Button("Delete \(job.name)", role: .destructive) {
                    model.performOpenClawCronAction(job: job, action: "remove")
                    deletingJob = nil
                }
            }
        } message: {
            Text("Stops future runs. Saved results stay in Cron Jobs.")
        }
        .task(id: heartbeatAgent?.id) {
            guard let agentID = heartbeatAgent?.id else { return }
            await model.loadOpenClawHeartbeat(agentID: agentID)
        }
    }

    private var openClawHeaderActions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            agentPicker
            deletedToggle
            emptyTrashButton
            refreshButton
            newJobButton
        }
    }

    private var agentPicker: some View {
        Picker("OpenClaw", selection: $selectedAgentID) {
            Text("All agents").tag(nil as UUID?)
            ForEach(agents) { Text($0.displayName).tag(Optional($0.id)) }
        }
        .frame(maxWidth: 190)
    }

    private var deletedToggle: some View {
        Toggle("Deleted", isOn: $showsDeleted)
    }

    @ViewBuilder
    private var emptyTrashButton: some View {
        if showsDeleted {
            Button("Empty trash") { model.emptyOpenClawCronTrash() }
                .buttonStyle(DashboardQuietButtonStyle())
        }
    }

    private var refreshButton: some View {
        Button(model.isRefreshingOpenClawCron ? "Refreshing…" : "Refresh") {
            Task { await model.refreshOpenClawCron() }
        }
        .buttonStyle(DashboardQuietButtonStyle())
        .disabled(model.isRefreshingOpenClawCron)
    }

    @ViewBuilder
    private var newJobButton: some View {
        if agents.count == 1, let agent = agents.first {
            Button("New job") { editor = CronEditorSelection(agentID: agent.id) }
                .buttonStyle(DashboardPrimaryButtonStyle())
        } else {
            Menu("New job") {
                ForEach(agents) { agent in
                    Button(agent.displayName) { editor = CronEditorSelection(agentID: agent.id) }
                }
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(agents.isEmpty)
        }
    }

    @ViewBuilder
    private var heartbeatSection: some View {
        if let agent = heartbeatAgent {
            OpenClawHeartbeatCard(
                agent: agent,
                configuration: model.openClawHeartbeatConfigurations[agent.id],
                isSaving: model.openClawHeartbeatSavingAgentIDs.contains(agent.id),
                message: model.openClawHeartbeatMessages[agent.id],
                messageIsError: model.openClawHeartbeatErrorAgentIDs.contains(agent.id),
                onSave: { configuration in
                    model.saveOpenClawHeartbeat(
                        agentID: agent.id,
                        configuration: configuration
                    )
                }
            )
            .id(agent.id)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Heartbeat")
                    .font(.system(size: 14, weight: .semibold))
                Text(agents.isEmpty
                     ? "Link an OpenClaw Gateway to configure its Heartbeat."
                     : "Choose an OpenClaw above to configure its Heartbeat.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous)
                    .stroke(DashboardPalette.foreground.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func cronJob(_ job: OpenClawCronJob) -> some View {
        let run = model.openClawCronRuns.first { $0.agentID == job.agentID && $0.jobID == job.id }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.system(size: 13.5, weight: .semibold))
                    Text(job.schedule).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer()
                DashboardCronPill(job.enabled ? "Enabled" : "Disabled", warning: !job.enabled)
                if let run { DashboardCronPill(run.status.capitalized, warning: run.status != "ok") }
            }
            if let run {
                Text(run.output.flatMap { $0.isEmpty ? nil : $0 } ?? "No output")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text((run.startedAt ?? run.completedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "Time unavailable")
                    .font(.system(size: 10.5)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            Picker("Send results to", selection: Binding(
                get: { model.openClawResultRoutes[job.agentID]?[job.id] ?? "" },
                set: { model.setOpenClawResultRoute(job: job, destination: $0) }
            )) {
                Text("Cron history only").tag("")
                Text("New chat for each result").tag("new")
                ForEach((model.workspaceOverview?.conversations ?? []).filter {
                    $0.agentID == job.agentID.uuidString.lowercased() && !$0.isArchived && $0.openClawSessionKey != nil
                }) { conversation in
                    Text(conversation.title).tag(conversation.id)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            Text("Changing the destination also imports undelivered results.")
                .font(.system(size: 10.5)).foregroundStyle(DashboardPalette.mutedForeground)
            DisclosureGroup("Job details and run history") {
                VStack(alignment: .leading, spacing: 8) {
                    if let description = cronText(job.remotePayload, keys: ["description", "message", "text", "script", "argv"]) {
                        Text(description).font(.system(size: 11.5)).textSelection(.enabled)
                    }
                    if let model = cronText(job.remotePayload, keys: ["model", "modelId"]) {
                        Text("Model: \(model)").font(.system(size: 11.5))
                    }
                    Text("Job ID: \(job.id)").font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    ForEach(jobRuns(job)) { historyRun in
                        DisclosureGroup("\(historyRun.status.capitalized) · \((historyRun.startedAt ?? historyRun.completedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "Time unavailable")") {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Run ID: \(historyRun.id)").font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                                Text(historyRun.output.flatMap { $0.isEmpty ? nil : $0 } ?? "No output")
                                    .font(.system(size: 11.5)).textSelection(.enabled)
                                if job.archiveState == .active {
                                    Button("Continue in chat") {
                                        createConversation(agentID: job.agentID, context: jobContext(job, run: historyRun, action: "Continue from this cron output"))
                                    }.buttonStyle(DashboardQuietButtonStyle())
                                }
                            }.padding(.top, 5)
                        }
                    }
                }.padding(.top, 6)
            }
            if job.archiveState == .active {
                HStack {
                    Button(job.enabled ? "Pause" : "Resume") {
                        model.performOpenClawCronAction(job: job, action: "toggle")
                    }.buttonStyle(DashboardQuietButtonStyle())
                    Button("Run now") { model.performOpenClawCronAction(job: job, action: "run") }
                        .buttonStyle(DashboardQuietButtonStyle())
                    Button("Edit") { editor = CronEditorSelection(agentID: job.agentID, job: job) }
                        .buttonStyle(DashboardQuietButtonStyle())
                    Button("Delete", role: .destructive) { deletingJob = job }
                        .buttonStyle(DashboardQuietButtonStyle())
                    Spacer()
                    Button("Edit with agent") {
                        createConversation(agentID: job.agentID, context: jobContext(job, run: nil, action: "Edit this cron job"))
                    }
                    .buttonStyle(DashboardQuietButtonStyle())
                    if let run {
                        Button("Continue in chat") {
                            createConversation(agentID: job.agentID, context: jobContext(job, run: run, action: "Continue from this cron output"))
                        }
                        .buttonStyle(DashboardQuietButtonStyle())
                    }
                }
                .disabled(model.openClawCronBusy)
            }
        }
        .padding(14)
        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous)
                .stroke(DashboardPalette.foreground.opacity(0.12), lineWidth: 1)
        }
    }


    private func jobRuns(_ job: OpenClawCronJob) -> [OpenClawCronRun] {
        model.openClawCronRuns.filter { $0.agentID == job.agentID && $0.jobID == job.id }
            .sorted { ($0.startedAt ?? $0.completedAt ?? .distantPast) > ($1.startedAt ?? $1.completedAt ?? .distantPast) }
    }

    private func cronText(_ data: Data, keys: [String]) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let values = object[key] as? [String], !values.isEmpty { return values.joined(separator: " ") }
            if let payload = object["payload"] as? [String: Any],
               let value = payload[key] as? String, !value.isEmpty { return value }
            if let payload = object["payload"] as? [String: Any],
               let values = payload[key] as? [String], !values.isEmpty { return values.joined(separator: " ") }
        }
        return nil
    }

    private func createConversation(agentID: UUID, context: String?) {
        Task {
            if let id = await model.createOpenClawContextConversation(
                agentID: agentID,
                context: context
            ) {
                onOpenConversation(id)
            }
        }
    }

    private func jobContext(
        _ job: OpenClawCronJob,
        run: OpenClawCronRun?,
        action: String
    ) -> String {
        [
            action,
            "Job ID: \(job.id)",
            "Schedule: \(job.schedule)",
            cronText(job.remotePayload, keys: ["description", "message", "text", "script", "argv"]).map { "What it does: \($0)" },
            cronText(job.remotePayload, keys: ["model", "modelId"]).map { "Model: \($0)" },
            "Original cron session ID: \(run?.nativeSessionID ?? job.nativeSessionID ?? "unavailable")",
            "Original cron session key: \(run?.nativeSessionKey ?? job.nativeSessionKey ?? "unavailable")",
            run?.output.map { "Output:\n\($0)" },
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

struct OpenClawHeartbeatCard: View {
    let agent: WorkspaceAgent
    let configuration: OpenClawHeartbeatConfiguration?
    let isSaving: Bool
    let message: String?
    let messageIsError: Bool
    let onSave: (OpenClawHeartbeatConfiguration) -> Void

    @State private var draft = OpenClawHeartbeatConfiguration()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Heartbeat")
                        .font(.system(size: 14, weight: .semibold))
                    Text("OpenClaw's recurring check-in for \(agent.displayName)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer()
                Toggle("Enabled", isOn: $draft.isEnabled)
                    .toggleStyle(DashboardSwitchToggleStyle())
                    .disabled(configuration == nil || isSaving)
            }

            if configuration == nil {
                if let message {
                    Text(message)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(
                            messageIsError
                                ? DashboardPalette.danger
                                : DashboardPalette.mutedForeground
                        )
                        .textSelection(.enabled)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading Heartbeat from OpenClaw…")
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    heartbeatField("Interval") {
                        TextField("30m", text: $draft.interval)
                    }
                    heartbeatField("Active from") {
                        TextField("09:00", text: $draft.activeFrom)
                    }
                    heartbeatField("Active until") {
                        TextField("17:00", text: $draft.activeUntil)
                    }
                    heartbeatField("Timezone") {
                        TextField("America/New_York", text: $draft.timezone)
                    }
                }
                .disabled(!draft.isEnabled || isSaving)

                heartbeatField("Prompt") {
                    TextField("Heartbeat prompt", text: $draft.prompt, axis: .vertical)
                        .lineLimit(2...4)
                }
                .disabled(isSaving)

                HStack {
                    Button(isSaving ? "Saving Heartbeat…" : "Save Heartbeat") {
                        onSave(draft)
                    }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled(isSaving || !canSave)
                    if let message {
                        Text(message)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(
                                messageIsError
                                    ? DashboardPalette.danger
                                    : DashboardPalette.mutedForeground
                            )
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(16)
        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous)
                .stroke(DashboardPalette.foreground.opacity(0.12), lineWidth: 1)
        }
        .onAppear { if let configuration { draft = configuration } }
        .onChange(of: configuration) { _, configuration in
            if let configuration { draft = configuration }
        }
    }

    private var canSave: Bool {
        !draft.interval.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.activeFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.activeUntil.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.timezone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func heartbeatField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DashboardPalette.mutedForeground)
            content()
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardCronPill: View {
    let label: String
    let warning: Bool

    init(_ label: String, warning: Bool) {
        self.label = label
        self.warning = warning
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(warning ? DashboardPalette.warning : DashboardPalette.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((warning ? DashboardPalette.warning : DashboardPalette.mutedForeground).opacity(0.08))
            .clipShape(Capsule())
    }
}

private struct OpenClawCronEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ApplicationModel
    let agentID: UUID
    let job: OpenClawCronJob?
    @State private var name = ""
    @State private var message = ""
    @State private var expression = "0 9 * * *"
    @State private var timeZone = TimeZone.current.identifier
    @State private var destination = "new"
    @State private var error: String?
    @State private var declarationKey = "wovenmatter-" + UUID().uuidString.lowercased()
    @State private var hasAgentPrompt = true
    @State private var originalSchedule: GatewayJSONValue?
    @State private var changesSchedule = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(job == nil ? "New scheduled job" : "Edit scheduled job")
                .font(.system(size: 20, weight: .semibold))
            TextField("Job name", text: $name)
            if hasAgentPrompt {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions").font(.system(size: 12, weight: .medium))
                    TextEditor(text: $message)
                        .scrollIndicators(.never)
                        .frame(height: 120)
                        .font(.system(size: 13))
                }
            }
            if originalSchedule?.objectValue?["kind"]?.stringValue != "cron", job != nil {
                Toggle("Replace the existing schedule with a cron expression", isOn: $changesSchedule)
            }
            if job == nil || originalSchedule?.objectValue?["kind"]?.stringValue == "cron" || changesSchedule {
                HStack {
                    TextField("Cron expression", text: $expression)
                    TextField("Time zone", text: $timeZone)
                }
                Text("Minute · hour · day of month · month · day of week")
                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            Picker("Send results to", selection: $destination) {
                Text("Cron history only").tag("")
                Text("New chat for each result").tag("new")
                ForEach((model.workspaceOverview?.conversations ?? []).filter {
                    $0.agentID == agentID.uuidString.lowercased() && !$0.isArchived && $0.openClawSessionKey != nil
                }) { Text($0.title).tag($0.id) }
            }
            Text("Jobs keep running while Woven Matter is closed, as long as OpenClaw and its host stay running. New jobs run in a separate session.")
                .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.openClawCronBusy ? "Saving…" : "Save") {
                    Task {
                        error = await model.saveOpenClawCron(agentID: agentID, job: job,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines), message: message,
                            expression: expression, timeZone: timeZone, declarationKey: declarationKey,
                            destination: destination, preserveSchedule: job != nil && !changesSchedule && originalSchedule?.objectValue?["kind"]?.stringValue != "cron")
                        if error == nil { dismiss() }
                    }
                }
                .buttonStyle(DashboardPrimaryButtonStyle())
                .disabled(model.openClawCronBusy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (hasAgentPrompt && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            guard let job else { return }
            name = job.name
            destination = model.openClawResultRoutes[agentID]?[job.id] ?? ""
            let payload = (try? JSONDecoder().decode(GatewayJSONValue.self, from: job.remotePayload))?.objectValue
            originalSchedule = payload?["schedule"]
            expression = originalSchedule?.objectValue?["expr"]?.stringValue ?? "0 9 * * *"
            timeZone = originalSchedule?.objectValue?["tz"]?.stringValue ?? TimeZone.current.identifier
            hasAgentPrompt = payload?["payload"]?.objectValue?["kind"]?.stringValue == "agentTurn"
            message = payload?["payload"]?.objectValue?["message"]?.stringValue ?? ""
        }
    }
}
