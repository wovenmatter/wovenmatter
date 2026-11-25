import SwiftUI

/// The one card for whatever a running turn asks the person, on every
/// runtime: an approval, questions or a form.
struct SessionInteractionCard: View {
    let interaction: SessionInteraction
    let respond: (SessionInteractionResponse) -> Void

    var body: some View {
        switch interaction.request {
        case .approval(let title, let options):
            SessionApprovalCard(title: title, options: options, respond: respond)
        case .questions(let title, let questions):
            SessionQuestionCard(title: title, questions: questions, respond: respond)
        case .form(let message, let fields):
            SessionFormCard(message: message, fields: fields, respond: respond)
        }
    }
}

private struct SessionApprovalCard: View {
    @Environment(\.wovenTheme) private var theme
    let title: String
    let options: [SessionChoice]
    let respond: (SessionInteractionResponse) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approval needed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WovenPalette.mutedForeground)
                .textCase(.uppercase)
                .tracking(0.8)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
        }
        .sessionInteractionCardStyle(theme)
    }

    private var allowOnce: SessionChoice? { options.first { $0.allowsOnce } }

    private var otherOptions: [SessionChoice] { options.filter { $0.id != allowOnce?.id } }

    @ViewBuilder
    private var actions: some View {
        if let option = allowOnce {
            Button("Allow once") { respond(.option(option.id)) }
                .buttonStyle(WovenPrimaryButtonStyle())
                .help(option.label)
                .accessibilityLabel(option.label)
        }
        if !otherOptions.isEmpty {
            Menu(allowOnce == nil ? "Choose response" : "More options") {
                // Keep the runtime's complete labels: persistent choices may
                // apply only to a domain, command, or project, not every tool.
                ForEach(otherOptions) { option in
                    Button(option.label) { respond(.option(option.id)) }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(WovenPalette.foreground)
            .fixedSize()
            .padding(.horizontal, 8)
            .accessibilityLabel("Other permission responses")
        }
        Button("Cancel", role: .cancel) { respond(.cancelled) }
            .buttonStyle(WovenQuietButtonStyle())
    }
}

private struct SessionQuestionCard: View {
    @Environment(\.wovenTheme) private var theme
    let title: String?
    let questions: [SessionQuestion]
    let respond: (SessionInteractionResponse) -> Void
    @State private var selections: [String: Set<String>] = [:]
    @State private var customAnswers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(nonemptyString(title) ?? "Agent has a question")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WovenPalette.mutedForeground)
                .textCase(.uppercase)
                .tracking(0.8)

            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.prompt)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if question.allowsMultiple {
                        Text("Select one or more options.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(WovenPalette.mutedForeground)
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 132), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(question.options) { option in
                            let selected = selections[question.id]?.contains(option.id) == true
                            Button {
                                toggle(option: option, for: question)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: Self.mark(selected: selected, several: question.allowsMultiple))
                                    Text(option.label)
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(selected ? WovenPalette.primary : WovenPalette.foreground)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 34)
                                .background(
                                    selected ? theme.palette.themeSoft : WovenPalette.background.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if question.acceptsOwnAnswer {
                        TextField("Other response", text: customAnswerBinding(for: question.id))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Submit") { respond(.answers(answers)) }
                    .buttonStyle(WovenPrimaryButtonStyle())
                    .disabled(!canSubmit)
                Button("Cancel", role: .cancel) { respond(.cancelled) }
                    .buttonStyle(WovenQuietButtonStyle())
            }
        }
        .sessionInteractionCardStyle(theme)
    }

    private var canSubmit: Bool {
        questions.allSatisfy { question in
            ownAnswer(for: question) != nil || selections[question.id]?.isEmpty == false
        }
    }

    /// The runtime checks answers against the options' ids, never their labels.
    private var answers: [String: SessionQuestionAnswer] {
        questions.reduce(into: [:]) { result, question in
            if let answer = ownAnswer(for: question) {
                result[question.id] = .text(answer)
                return
            }
            let selectedIDs = selections[question.id] ?? []
            let ids = question.options.map(\.id).filter { selectedIDs.contains($0) }
            result[question.id] = .options(question.allowsMultiple ? ids : Array(ids.prefix(1)))
        }
    }

    /// A checkbox where several options may be picked, a radio mark where one may.
    static func mark(selected: Bool, several: Bool) -> String {
        several ? (selected ? "checkmark.square.fill" : "square") : (selected ? "checkmark.circle.fill" : "circle")
    }

    private func ownAnswer(for question: SessionQuestion) -> String? {
        question.acceptsOwnAnswer ? nonemptyString(customAnswers[question.id]) : nil
    }

    private func toggle(option: SessionChoice, for question: SessionQuestion) {
        customAnswers[question.id] = ""
        if question.allowsMultiple {
            var selected = selections[question.id] ?? []
            if selected.contains(option.id) { selected.remove(option.id) } else { selected.insert(option.id) }
            selections[question.id] = selected
        } else {
            selections[question.id] = [option.id]
        }
    }

    private func customAnswerBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { customAnswers[questionID] ?? "" },
            set: { value in
                customAnswers[questionID] = value
                if nonemptyString(value) != nil { selections[questionID] = [] }
            }
        )
    }
}

private struct SessionFormCard: View {
    @Environment(\.wovenTheme) private var theme
    let message: String
    let fields: [SessionFormField]
    let respond: (SessionInteractionResponse) -> Void
    @State private var included: Set<String> = []
    @State private var text: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var selections: [String: Set<String>] = [:]
    /// A choice answered in the person's own words, where the field takes them.
    @State private var ownAnswers: [String: String] = [:]
    @State private var initialized = false
    /// Whether the form has fields below what its scroll area shows.
    @State private var moreBelow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A long form scrolls; macOS hides the scroller until then, so a
            // hint says when fields are out of sight below.
            ScrollView {
                formFields
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 420)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height > 4
            } action: { _, value in
                moreBelow = value
            }
            .overlay(alignment: .bottom) {
                if moreBelow {
                    Label("More below", systemImage: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(theme.palette.themeWhisper, in: Capsule())
                        .overlay { Capsule().stroke(theme.palette.border, lineWidth: 1) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: 8) {
                Button("Submit") { if let values { respond(.formValues(values)) } }
                    .buttonStyle(WovenPrimaryButtonStyle()).disabled(values == nil)
                Button("Cancel", role: .cancel) { respond(.cancelled) }.buttonStyle(WovenQuietButtonStyle())
            }
        }
        .sessionInteractionCardStyle(theme)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            for field in fields {
                guard let value = field.initialValue else { continue }
                included.insert(field.id)
                switch value {
                case .string(let value):
                    if field.kind != .singleChoice { text[field.id] = value }
                    else if field.options.contains(where: { $0.id == value }) { selections[field.id] = [value] }
                    else { ownAnswers[field.id] = value }
                case .strings(let values):
                    selections[field.id] = Set(values.filter { value in field.options.contains { $0.id == value } })
                    ownAnswers[field.id] = values.first { value in !field.options.contains { $0.id == value } }
                case .number(let value): text[field.id] = String(value)
                case .boolean(let value): flags[field.id] = value
                }
            }
        }
    }

    private var formFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message).font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 7) {
                    // An optional field is sent once it has an answer, and left out while it has none.
                    Text(field.title).font(.system(size: 12.5, weight: .medium))
                    if let detail = field.detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground) }
                    control(for: field)
                }
            }
        }
    }

    @ViewBuilder
    private func control(for field: SessionFormField) -> some View {
        switch field.kind {
        case .boolean:
            Toggle("Yes", isOn: Binding(get: { flags[field.id] ?? false }, set: { included.insert(field.id); flags[field.id] = $0 }))
                .toggleStyle(CompactSwitchToggleStyle())
        case .singleChoice, .multipleChoice:
            ForEach(field.options) { option in
                Button {
                    var selected = selections[field.id] ?? []
                    if field.kind == .singleChoice, !field.required, selected.contains(option.id) { selected = [] }
                    else if field.kind == .singleChoice { selected = [option.id] }
                    else if selected.contains(option.id) { selected.remove(option.id) }
                    else { selected.insert(option.id) }
                    selections[field.id] = selected
                    if selected.isEmpty, nonemptyString(ownAnswers[field.id]) == nil, !field.required { included.remove(field.id) }
                    else { included.insert(field.id) }
                    if field.kind == .singleChoice { ownAnswers[field.id] = nil }
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: SessionQuestionCard.mark(selected: selections[field.id]?.contains(option.id) == true,
                                                                   several: field.kind == .multipleChoice))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label)
                            if let detail = option.detail { Text(detail).font(.system(size: 11)).foregroundStyle(WovenPalette.mutedForeground) }
                        }
                        Spacer(minLength: 0)
                    }.font(.system(size: 12.5)).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if field.acceptsOwnAnswer {
                TextField(field.placeholder ?? "Other response", text: ownAnswerBinding(field))
                    .textFieldStyle(.roundedBorder)
            }
        case .text, .number, .integer:
            if field.multiline {
                TextEditor(text: textBinding(field.id)).frame(minHeight: 90, maxHeight: 200)
                    .scrollIndicators(.never)
            } else {
                TextField(field.placeholder ?? "Answer", text: textBinding(field.id)).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { text[id] ?? "" }, set: { value in
            text[id] = value
            if value.isEmpty { included.remove(id) } else { included.insert(id) }
        })
    }

    /// Typing an own answer to a single choice replaces the option picked.
    private func ownAnswerBinding(_ field: SessionFormField) -> Binding<String> {
        Binding(get: { ownAnswers[field.id] ?? "" }, set: { value in
            ownAnswers[field.id] = value
            if field.kind == .singleChoice, nonemptyString(value) != nil { selections[field.id] = [] }
            if nonemptyString(value) != nil || selections[field.id]?.isEmpty == false { included.insert(field.id) }
            else { included.remove(field.id) }
        })
    }

    private var values: [String: SessionFormValue]? {
        var result: [String: SessionFormValue] = [:]
        for field in fields where field.required || included.contains(field.id) {
            let value: SessionFormValue
            switch field.kind {
            case .text: value = .string(text[field.id] ?? "")
            case .number, .integer:
                guard let number = Double(text[field.id] ?? ""), number.isFinite else { return nil }
                value = .number(number)
            case .boolean: value = .boolean(flags[field.id] ?? false)
            case .singleChoice:
                guard let choice = nonemptyString(ownAnswers[field.id]) ?? selections[field.id]?.first else { return nil }
                value = .string(choice)
            case .multipleChoice:
                let picked = field.options.filter { selections[field.id]?.contains($0.id) == true }.map(\.id)
                value = .strings(picked + [nonemptyString(ownAnswers[field.id])].compactMap { $0 })
            }
            guard field.accepts(value) else { return nil }
            result[field.id] = value
        }
        return result
    }
}

private extension View {
    func sessionInteractionCardStyle(_ theme: WovenTheme) -> some View {
        padding(13)
            .frame(maxWidth: 768, alignment: .leading)
            // The tint over the window's own colour: the chat scrolls under
            // these cards, and must not show through them.
            .background(theme.palette.themeWhisper)
            .background(WovenPalette.background)
            .clipShape(DesktopShapes.card)
            .overlay { DesktopShapes.card.stroke(theme.palette.border, lineWidth: 1) }
    }
}
