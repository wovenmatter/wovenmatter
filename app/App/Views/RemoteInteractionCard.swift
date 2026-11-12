import SwiftUI
import WovenMatterCore

/// A question or approval from a session another machine runs, answered
/// through its owner (`PendingInteraction`). Sessions this Mac runs use the
/// ACP cards (`DashboardLocalPermissionCard`, `DashboardLocalQuestionCard`);
/// this card has their look for the owner's wire shape.
struct RemoteInteractionCard: View {
    @Environment(\.dashboardTheme) private var theme
    let interaction: PendingInteraction
    let respond: (InteractionResponse) async -> Void
    @State private var selected: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]
    @State private var submitting = false

    private var answers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: interaction.questions.map { question in
            var values = Array(selected[question.id] ?? []).sorted()
            let text = freeText[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { values.append(text) }
            return (question.id, values)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(interaction.kind == .approval ? "Approval needed" : "Agent has a question")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .textCase(.uppercase)
                .tracking(0.8)
            Text(interaction.title)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = interaction.detail {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(interaction.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.prompt).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    ForEach(question.options) { option in
                        Toggle(option.label, isOn: Binding(get: { selected[question.id]?.contains(option.id) == true }, set: { value in
                            if question.allowsMultiple {
                                if value { selected[question.id, default: []].insert(option.id) } else { selected[question.id]?.remove(option.id) }
                            } else { selected[question.id] = value ? [option.id] : [] }
                        })).toggleStyle(.checkbox).font(.system(size: 12.5))
                    }
                    if question.allowsFreeText {
                        TextField("Answer", text: Binding(get: { freeText[question.id, default: ""] }, set: { freeText[question.id] = $0 }))
                            .dashboardInput()
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            .disabled(submitting)
        }
        .padding(13)
        .frame(maxWidth: 768, alignment: .leading)
        .background(theme.palette.themeWhisper)
        .clipShape(DashboardShapes.card)
        .overlay { DashboardShapes.card.stroke(theme.palette.border, lineWidth: 1) }
    }

    @ViewBuilder private var actions: some View {
        ForEach(Array(interaction.options.enumerated()), id: \.element.id) { index, option in
            if index == 0 {
                Button(option.label) { send(.init(optionID: option.id)) }.buttonStyle(DashboardPrimaryButtonStyle())
            } else {
                Button(option.label) { send(.init(optionID: option.id)) }.buttonStyle(DashboardQuietButtonStyle())
            }
        }
        if !interaction.questions.isEmpty {
            Button("Submit answers") { send(.init(answers: answers)) }.buttonStyle(DashboardPrimaryButtonStyle())
                .disabled(interaction.questions.contains { $0.isRequired && answers[$0.id]?.isEmpty != false })
        }
        Button("Cancel", role: .cancel) { send(.init(cancelled: true)) }.buttonStyle(DashboardQuietButtonStyle())
    }

    private func send(_ response: InteractionResponse) {
        submitting = true
        Task { await respond(response); submitting = false }
    }
}
