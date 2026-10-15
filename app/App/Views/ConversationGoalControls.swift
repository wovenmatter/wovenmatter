import SwiftUI
import WovenMatterCore

struct ConversationGoalControls: View {
    @Environment(\.dashboardTheme) private var theme
    private let currentGoal: () -> WorkspaceGoal?
    let sessionID: String
    let update: (WorkspaceGoalMutation) async throws -> Void

    init(tools: WorkspaceAgentToolsModel, sessionID: String) {
        self.sessionID = sessionID
        currentGoal = { tools.goals[sessionID] }
        update = { try await tools.mutateGoalFromUI(sessionID: sessionID, mutation: $0) }
    }
    init(goal: WorkspaceGoal?, sessionID: String, update: @escaping (WorkspaceGoalMutation) async throws -> Void) {
        self.sessionID = sessionID; currentGoal = { goal }; self.update = update
    }
    @State private var showingDetails = false
    @State private var error: String?
    @State private var busy = false
    private var goal: WorkspaceGoal? { currentGoal() }

    var body: some View {
        if let goal {
            HStack(spacing: 8) {
                Text(goal.status.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(goal.elapsedPursuitText(at: context.date))
                }.font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(DashboardPalette.mutedForeground)
                Spacer(minLength: 0)
                Button(role: .destructive) { mutate(.clear(id: goal.id)) } label: {
                    Text("Delete").padding(.horizontal, 6).frame(height: 24)
                }.disabled(busy)
                if goal.status != .complete {
                    Button {
                        mutate(goal.status == .active ? .pause(id: goal.id) : .resume(id: goal.id))
                    } label: {
                        Text(goal.status == .active ? "Pause" : "Resume")
                            .padding(.horizontal, 6).frame(height: 24)
                    }.disabled(busy)
                }
                Button { showingDetails = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12)).frame(width: 24, height: 24)
                }
                .help("Expand goal")
                .accessibilityLabel("Expand goal")
            }
            .font(.system(size: 11))
            .buttonStyle(DashboardIconButtonStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(theme.palette.themeWhisper, in: DashboardShapes.card)
            .sheet(isPresented: $showingDetails) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Goal").font(.headline)
                        Spacer()
                        Text(goal.status.title).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(goal.objective).textSelection(.enabled)
                            if let evidence = goal.evidence, !evidence.isEmpty {
                                Text(evidence).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                                    .textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.never).frame(minHeight: 180, maxHeight: 360)
                    HStack {
                        Spacer()
                        Button("Done") { showingDetails = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }.padding(20).frame(width: 480)
            }
            .alert("Unable to update goal", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func mutate(_ mutation: WorkspaceGoalMutation) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await update(mutation)
                showingDetails = false
            } catch { self.error = error.localizedDescription }
        }
    }
}
