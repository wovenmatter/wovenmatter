import SwiftUI
import WovenMatterCompanion

struct LibraryClientInteraction: View {
  @Environment(\.dashboardTheme) private var theme
  @Bindable var model: CentralLibraryClientModel
  var interaction: CompanionPendingInteraction
  @State private var answers: [String: Set<String>] = [:]
  @State private var freeText: [String: String] = [:]
  @State private var responding = false
  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Label(interaction.title, systemImage: interaction.kind == .approval ? "hand.raised" : "questionmark.bubble").font(.headline)
      if let detail = interaction.detail { Text(detail).font(.subheadline).textSelection(.enabled) }
      if interaction.kind == .approval {
        ForEach(interaction.options) { option in
          Button { respond(.init(optionID: option.id)) } label: {
            VStack(alignment: .leading) { Text(option.label); if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) } }.frame(maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(DashboardQuietButtonStyle())
        }
      } else {
        ForEach(interaction.questions) { question in
          VStack(alignment: .leading, spacing: 8) {
            Text(question.prompt).font(.subheadline.weight(.medium))
            ForEach(question.options) { option in
              Button {
                var selected = answers[question.id] ?? []
                if selected.contains(option.id) { selected.remove(option.id) }
                else if question.allowsMultiple { selected.insert(option.id) }
                else { selected = [option.id] }
                answers[question.id] = selected
                if !question.allowsMultiple { freeText[question.id] = "" }
              } label: { Label(option.label, systemImage: answers[question.id]?.contains(option.id) == true ? "checkmark.circle.fill" : "circle").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).frame(minHeight: 44)
            }
            if question.allowsFreeText {
              TextField("Your answer", text: Binding(get: { freeText[question.id] ?? "" }, set: { freeText[question.id] = $0; if !question.allowsMultiple { answers[question.id] = [] } }), axis: .vertical).textFieldStyle(.roundedBorder)
            }
          }
        }
        Button("Send answers") {
          var result = answers.mapValues { Array($0).sorted() }
          for (id, text) in freeText where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result[id, default: []].append(text) }
          respond(.init(answers: result))
        }.buttonStyle(DashboardPrimaryButtonStyle()).disabled(!interaction.questions.allSatisfy { !$0.isRequired || !(answers[$0.id] ?? []).isEmpty || !(freeText[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      }
      Button("Cancel request", role: .cancel) { respond(.init(cancelled: true)) }.font(.caption).frame(minHeight: 44)
      Text("The first valid answer on any connected device wins.").font(.caption2).foregroundStyle(DashboardPalette.mutedForeground)
    }.disabled(!model.canControl || responding).padding(16).background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
  }
  private func respond(_ response: CompanionInteractionResponse) {
    responding = true
    Task { await model.respond(interaction, response: response); responding = false }
  }
}
