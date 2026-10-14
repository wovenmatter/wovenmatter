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
    @State private var editing = false
    @State private var error: String?
    @State private var busy = false
    private var goal: WorkspaceGoal? { currentGoal() }

    var body: some View {
        HStack(spacing: 8) {
            DashboardLucideIcon(glyph: .compass, size: 14)
            if let goal {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(goal.status.title).font(.system(size: 11, weight: .medium))
                        if let used = goal.tokensUsed {
                            Text(goal.tokenBudget.map { "\(used.formatted()) / \($0.formatted()) tokens" } ?? "\(used.formatted()) tokens")
                                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Text(goal.objective).font(.system(size: 12)).lineLimit(1)
                        .help([goal.objective, goal.evidence].compactMap { $0 }.joined(separator: "\n\n"))
                }
                Spacer(minLength: 4)
                Button(goal.status == .complete ? "New goal" : "Edit") { editing = true }
                if goal.status != .complete {
                    Button(goal.status == .active ? "Pause" : "Resume") {
                        mutate(goal.status == .active ? .pause(id: goal.id) : .resume(id: goal.id))
                    }
                }
                Button("Clear") { mutate(.clear(id: goal.id)) }
            } else {
                Button("Set goal") { editing = true }
                Spacer()
            }
        }
        .buttonStyle(.borderless)
        .disabled(busy)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.palette.themeWhisper, in: DashboardShapes.card)
        .sheet(isPresented: $editing) {
            ConversationGoalEditor(goal: goal, update: update)
        }
        .alert("Unable to update goal", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func mutate(_ mutation: WorkspaceGoalMutation) {
        busy = true
        Task {
            defer { busy = false }
            do { try await update(mutation) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ConversationGoalEditor: View {
    @Environment(\.dismiss) private var dismiss
    let goal: WorkspaceGoal?
    let update: (WorkspaceGoalMutation) async throws -> Void
    @State private var objective: String
    @State private var tokens: String
    @State private var turns: String
    @State private var error: String?
    @State private var saving = false

    init(goal: WorkspaceGoal?, update: @escaping (WorkspaceGoalMutation) async throws -> Void) {
        self.goal = goal; self.update = update
        _objective = State(initialValue: goal?.status == .complete ? "" : goal?.objective ?? "")
        _tokens = State(initialValue: goal?.tokenBudget.map(String.init) ?? "")
        _turns = State(initialValue: goal?.turnBudget.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(goal == nil || goal?.status == .complete ? "Set goal" : "Edit goal").font(.headline)
            Text("Describe the outcome and how the agent should verify it.").foregroundStyle(.secondary)
            TextEditor(text: $objective).scrollIndicators(.never).frame(minHeight: 140)
                .accessibilityLabel("Goal objective")
            HStack {
                TextField("Token budget (optional)", text: $tokens)
                TextField("Turn budget (optional)", text: $turns)
            }
            Text("Budgets are checked between turns. Editing pauses the goal until you resume it.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(saving || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 480)
        .disabled(saving)
    }

    private func save() {
        let tokenBudget = tokens.isEmpty ? nil : Int64(tokens)
        let turnBudget = turns.isEmpty ? nil : Int(turns)
        guard (tokens.isEmpty || tokenBudget != nil), (turns.isEmpty || turnBudget != nil) else {
            error = "Enter positive whole numbers for budgets."; return
        }
        do { try WorkspaceGoal.validate(objective: objective, tokenBudget: tokenBudget, turnBudget: turnBudget) }
        catch { self.error = error.localizedDescription; return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let mutation: WorkspaceGoalMutation
                if let goal, goal.status != .complete {
                    mutation = .edit(id: goal.id, objective: objective, tokenBudget: tokenBudget, turnBudget: turnBudget)
                } else { mutation = .set(objective: objective, tokenBudget: tokenBudget, turnBudget: turnBudget) }
                try await update(mutation)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
