import SwiftUI
import WovenMatterCore

struct WorkspaceToolDefaultsCard: View {
    @Bindable var tools: WorkspaceAgentToolsModel

    private func setting<Value>(_ key: WritableKeyPath<WorkspaceToolSettings, Value>) -> Binding<Value> {
        Binding(get: { tools.settings[keyPath: key] }, set: { value in
            var settings = tools.settings
            settings[keyPath: key] = value
            tools.saveSettings(settings)
        })
    }

    var body: some View {
        SettingsCard(title: "Agent tools", detail: "Defaults for new sessions. You can change enabled tools in each session.") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(WorkspaceToolGroup.allCases) { group in
                    HStack(spacing: 12) {
                        Toggle(group.title, isOn: Binding(get: { tools.settings.enabledByDefault.contains(group) }, set: { enabled in
                            var settings = tools.settings
                            if enabled { settings.enabledByDefault.insert(group) } else { settings.enabledByDefault.remove(group) }
                            tools.saveSettings(settings)
                        }))
                        Spacer(minLength: 8)
                        if group == .calendar {
                            Picker("Calendar access", selection: setting(\.calendarAccess)) {
                                ForEach(WorkspaceCalendarAccess.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                            }.labelsHidden().frame(width: 140)
                        } else if group == .usage {
                            Text("Read only").font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                    }
                    if group == .sessions {
                        HStack {
                            Text("Sessions managed by one coordinator")
                            Spacer(minLength: 12)
                            Picker("Sessions managed by one coordinator", selection: setting(\.maximumManagedSessions)) {
                                ForEach(1...16, id: \.self) { Text(String($0)).tag($0) }
                            }.labelsHidden().frame(width: 78)
                        }.padding(.leading, 38)
                    }
                }
                Divider()
                HStack {
                    Text("Maximum sessions running simultaneously.")
                    Spacer(minLength: 12)
                    Picker("Maximum sessions running simultaneously.", selection: setting(\.maximumRunningSessions)) {
                        ForEach(1...48, id: \.self) { Text(String($0)).tag($0) }
                    }.labelsHidden().frame(width: 78)
                }
                if let error = tools.error {
                    Text(error).foregroundStyle(DashboardPalette.mutedForeground).font(.system(size: 11.5))
                }
            }.font(.system(size: 13)).foregroundStyle(DashboardPalette.foreground)
        }
    }
}

struct WorkspaceSessionToolsMenu: View {
    @Bindable var tools: WorkspaceAgentToolsModel
    let sessionID: String
    @State private var confirmsTimerPause = false
    @State private var error: String?

    private func set(_ group: WorkspaceToolGroup, enabled: Bool, confirmed: Bool = false) {
        do {
            try tools.setEnabled(group, enabled: enabled, sessionID: sessionID, confirmedPausingTimers: confirmed)
            error = nil
        } catch WorkspaceToolError.timerPauseConfirmation { confirmsTimerPause = true }
        catch { self.error = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Tools").font(.system(size: 13, weight: .semibold))
            ForEach(WorkspaceToolGroup.allCases) { group in
                HStack(spacing: 12) {
                    Toggle(group.title, isOn: Binding(get: { tools.policy(for: sessionID).enabled.contains(group) }, set: { set(group, enabled: $0) }))
                    Spacer(minLength: 0)
                    if group == .calendar || group == .usage {
                        Text(group == .usage ? "Read only" : tools.settings.calendarAccess.title)
                            .font(.system(size: 10.5)).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                }
            }
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground) }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(DashboardPalette.foreground)
        .toggleStyle(DashboardSwitchToggleStyle())
        .padding(16).frame(width: 310)
        .alert("Disable timers?", isPresented: $confirmsTimerPause) {
            Button("Cancel", role: .cancel) { }
            Button("Disable and pause") { set(.timers, enabled: false, confirmed: true) }
        } message: { Text("Disabling timers will pause this session’s active timers.") }
    }
}
