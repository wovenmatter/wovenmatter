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
            Button { showingDetails = true } label: {
                HStack(spacing: 8) {
                    DashboardLucideIcon(glyph: .compass, size: 14)
                    Text(goal.status.title).font(.system(size: 11, weight: .medium)).lineLimit(1).layoutPriority(1)
                    Text(goal.objective).font(.system(size: 12)).lineLimit(1)
                        .foregroundStyle(DashboardPalette.mutedForeground)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(theme.palette.themeWhisper, in: DashboardShapes.card)
            .accessibilityLabel("Goal: \(goal.status.title). \(goal.objective)")
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Goal").font(.headline)
                        Spacer()
                        Text(goal.status.title).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(goal.objective).textSelection(.enabled)
                            if let evidence = goal.evidence, !evidence.isEmpty {
                                Text(evidence).font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                                    .textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.never).frame(maxHeight: 240)
                    HStack {
                        if goal.status != .complete {
                            Button(goal.status == .active ? "Pause" : "Resume") {
                                mutate(goal.status == .active ? .pause(id: goal.id) : .resume(id: goal.id))
                            }.buttonStyle(DashboardQuietButtonStyle())
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { mutate(.clear(id: goal.id)) }
                            .buttonStyle(DashboardQuietButtonStyle())
                    }.disabled(busy)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding(16).frame(width: 360)
            }
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
