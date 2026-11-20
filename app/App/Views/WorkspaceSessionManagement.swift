import SwiftUI

struct WorkspaceSessionManagementControls: View {
    @Bindable var tools: AgentToolsStore
    @Environment(\.workspaceApplicationModel) private var model
    let sessionID: String
    @State private var editingTimer: WorkspaceSessionTimer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let timers = tools.timers.filter { $0.sessionID == sessionID }
            let enabled = tools.policy(for: sessionID).enabled.contains(.timers)
            if enabled || !timers.isEmpty {
                Divider()
                HStack {
                    Text("Session timers").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Add") {
                        if let machineID { editingTimer = .init(sessionID: sessionID, machineID: machineID, instruction: "",
                                                                nextFireAt: Date().addingTimeInterval(300)) }
                    }
                    .buttonStyle(.plain).disabled(!enabled || machineID == nil)
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
                            Button(timer.isPaused ? "Resume" : "Pause") { Task { await tools.pauseTimer(timer, paused: !timer.isPaused) } }
                                .disabled(timer.isPaused && !enabled)
                            Button { Task { await tools.removeTimer(timer) } } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Remove timer: \(timer.instruction)")
                        }.font(.system(size: 11)).foregroundStyle(WovenPalette.mutedForeground).buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $editingTimer) { timer in
            WorkspaceTimerEditor(tools: tools, initial: timer)
        }
    }

    private var machineID: String? { model?.workspace.conversation(id: sessionID)?.machineID }
}

private struct WorkspaceTimerEditor: View {
    @Bindable var tools: AgentToolsStore
    let initial: WorkspaceSessionTimer
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkspaceSessionTimerDraft
    @State private var error: String?

    init(tools: AgentToolsStore, initial: WorkspaceSessionTimer) {
        self.tools = tools
        self.initial = initial
        _draft = State(initialValue: WorkspaceSessionTimerDraft(initial))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session timer").font(.system(size: 16, weight: .semibold))
            Text("Send this instruction while Woven Matter is open.")
                .font(.system(size: 12)).foregroundStyle(WovenPalette.mutedForeground)
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
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(WovenPalette.mutedForeground) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save timer") {
                    Task {
                        do {
                            try await tools.saveTimer(draft.timer())
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(WovenPrimaryButtonStyle())
                    .disabled((try? draft.timer()) == nil)
            }
        }.padding(24).frame(width: 410)
    }
}
