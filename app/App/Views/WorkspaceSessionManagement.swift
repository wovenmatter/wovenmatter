import SwiftUI
import WovenMatterCore

struct WorkspaceSessionManagementControls: View {
    @Bindable var tools: WorkspaceAgentToolsModel
    @Environment(\.workspaceApplicationModel) private var model
    @Environment(\.openWorkspaceConversation) private var open
    let sessionID: String
    @State private var editingTimer: WorkspaceSessionTimer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let relationship = tools.relationships[sessionID]
            if let coordinator = relationship?.coordinatorID {
                Divider()
                Button("Managed by \(title(coordinator))") { open(coordinator) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                Toggle("Notify coordinator", isOn: Binding(get: { tools.relationships[sessionID]?.notificationsEnabled ?? true },
                    set: { tools.setNotifications(sessionID: sessionID, enabled: $0) }))
                Button("End coordination") { tools.endCoordination(sessionID: sessionID) }
                    .buttonStyle(SettingsQuietButtonStyle())
            }
            let managed = tools.relationships.values.filter { $0.coordinatorID == sessionID }.sorted { title($0.sessionID) < title($1.sessionID) }
            if !managed.isEmpty {
                Divider()
                Text("Managing \(managed.count) \(managed.count == 1 ? "session" : "sessions")").font(.system(size: 12, weight: .medium))
                ForEach(managed, id: \.sessionID) { relation in
                    HStack {
                        Button(title(relation.sessionID)) { open(relation.sessionID) }.lineLimit(1).buttonStyle(.plain)
                        Spacer()
                        Button("Release") { tools.endCoordination(sessionID: relation.sessionID) }.buttonStyle(.plain)
                    }
                }
            }
            let timers = tools.timers.filter { $0.sessionID == sessionID }
            let enabled = tools.policy(for: sessionID).enabled.contains(.timers)
            if enabled || !timers.isEmpty {
                Divider()
                HStack {
                    Text("Session timers").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Add") { editingTimer = .init(sessionID: sessionID, instruction: "", nextFireAt: Date().addingTimeInterval(300)) }
                        .buttonStyle(.plain).disabled(!enabled)
                }
                ForEach(timers) { timer in
                    VStack(alignment: .leading, spacing: 5) {
                        Button { editingTimer = timer } label: {
                            Text(timer.instruction).lineLimit(2).multilineTextAlignment(.leading)
                        }.buttonStyle(.plain)
                        HStack {
                            if timer.isPaused { Text("Paused") }
                            else { Text(timer.nextFireAt, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                            Spacer()
                            Button(timer.isPaused ? "Resume" : "Pause") { tools.pauseTimer(timer, paused: !timer.isPaused) }
                                .disabled(timer.isPaused && !enabled)
                            Button { tools.removeTimer(timer) } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Remove timer: \(timer.instruction)")
                        }.font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground).buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $editingTimer) { timer in
            WorkspaceTimerEditor(tools: tools, initial: timer)
        }
    }
    private func title(_ id: String) -> String {
        model?.workspaceOverview?.conversations.first { $0.id == id }?.title ?? "Unavailable session"
    }
}

private struct WorkspaceTimerEditor: View {
    @Bindable var tools: WorkspaceAgentToolsModel
    let initial: WorkspaceSessionTimer
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkspaceSessionTimerDraft
    @State private var error: String?

    init(tools: WorkspaceAgentToolsModel, initial: WorkspaceSessionTimer) {
        self.tools = tools
        self.initial = initial
        _draft = State(initialValue: WorkspaceSessionTimerDraft(initial))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session timer").font(.system(size: 16, weight: .semibold))
            Text("Send this instruction while Woven Matter is open.")
                .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
            TextEditor(text: $draft.instruction).font(.system(size: 13)).scrollIndicators(.never)
                .frame(height: 100).accessibilityLabel("Timer instruction")
            DatePicker("Next run", selection: $draft.nextFireAt)
            Toggle("Repeat", isOn: $draft.repeats)
            if draft.repeats {
                HStack {
                    Text("Every")
                    TextField("Seconds", value: $draft.intervalSeconds, format: .number)
                        .frame(width: 100).accessibilityLabel("Repeat interval in seconds")
                    Text("seconds")
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save timer") {
                    do {
                        try tools.database.saveSessionTimer(draft.timer(), callerID: initial.sessionID)
                        try tools.reload()
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled((try? draft.timer()) == nil)
            }
        }.padding(24).frame(width: 410)
    }
}
