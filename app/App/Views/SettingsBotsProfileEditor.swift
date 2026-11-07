import SwiftUI
import WovenMatterClient

struct BotSettingsProfileEditor: View {
    let profile: PiBotProfile?
    let providers: [PiBotProviderModels]
    let onSave: (PiBotProfileDraft) async -> Bool
    let onCancel: () -> Void
    @State private var draft: PiBotProfileDraft
    @State private var saving = false

    init(profile: PiBotProfile?, providers: [PiBotProviderModels],
         onSave: @escaping (PiBotProfileDraft) async -> Bool, onCancel: @escaping () -> Void) {
        self.profile = profile; self.providers = providers; self.onSave = onSave; self.onCancel = onCancel
        _draft = State(initialValue: PiBotProfileDraft(profile: profile))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsField("Name") { TextField("e.g. Coding", text: $draft.name).dashboardInput().accessibilityLabel("Name") }
            if profile == nil {
                SettingsField("Id") {
                    SettingsNote("Lowercase letters, digits, - and _. Can't be changed.")
                    TextField("e.g. coding", text: $draft.id).dashboardInput().accessibilityLabel("Id")
                }
            }
            BotSettingsEditorSection(title: "Main model", summary: draft.main.isEmpty ? "Not set" : draft.main, open: true) {
                SettingsNote("Runs the main channel and every thread.")
                BotSettingsModelPicker(providers: providers, selection: $draft.main, label: "Main model")
            }
            fallbacks
            memory
            pool
            BotSettingsEditorSection(title: "Model preferences", summary: draft.guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "None" : draft.guidance) {
                SettingsNote("Describe your preferences and experiences with these models. The main model uses this guidance when choosing models for subagents.")
                BotSettingsTextEditor(text: $draft.guidance, label: "Model preferences",
                    placeholder: "e.g. Opus writes nicer code. Sol is thorough. Check Astra's work.")
            }
            HStack {
                Button(saving ? "Saving…" : profile == nil ? "Create profile" : "Save profile") {
                    saving = true
                    Task { _ = await onSave(draft); saving = false }
                }
                .buttonStyle(DashboardPrimaryButtonStyle())
                .disabled(!draft.canSave(isNew: profile == nil))
                Button("Cancel", action: onCancel)
            }
        }
        .disabled(saving)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(profile.map { "Edit \($0.name)" } ?? "New profile")
    }

    private var fallbacks: some View {
        BotSettingsEditorSection(title: "Fallbacks", summary: draft.fallbackModels.isEmpty ? "None, the bot pauses" : draft.fallbackModels.joined(separator: " → "), problem: draft.fallbackProblem) {
            SettingsNote("Up to 5, tried in order when the main model hits a usage limit or runs out of credits. The bot switches back once it resets.")
            ForEach(Array(draft.fallbacks.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 6) {
                    Text("\(index + 1).").font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                    BotSettingsModelPicker(providers: providers, selection: Binding(
                        get: { draft.fallbacks.first { $0.id == entry.id }?.model ?? "" },
                        set: { value in if let at = draft.fallbacks.firstIndex(where: { $0.id == entry.id }) { draft.fallbacks[at].model = value } }),
                        label: "Fallback \(index + 1)")
                    Button { draft.fallbacks.swapAt(index, index - 1) } label: { DashboardLucideIcon(glyph: .arrowUp, size: 13) }
                        .disabled(index == 0).accessibilityLabel("Move fallback \(index + 1) up")
                    Button { draft.fallbacks.swapAt(index, index + 1) } label: { DashboardLucideIcon(glyph: .arrowDown, size: 13) }
                        .disabled(index == draft.fallbacks.count - 1).accessibilityLabel("Move fallback \(index + 1) down")
                    Button { draft.fallbacks.removeAll { $0.id == entry.id } } label: { DashboardLucideIcon(glyph: .trash, size: 13) }
                        .accessibilityLabel("Remove fallback \(index + 1)")
                }
            }
            if let problem = draft.fallbackProblem { SettingsError(problem) }
            if draft.fallbacks.count < PiBotProfileDraft.maxFallbacks {
                Button { draft.fallbacks.append(.init()) } label: { BotSettingsActionLabel(title: "Add fallback", glyph: .plus) }
            }
        }
    }

    private var memory: some View {
        BotSettingsEditorSection(title: "Memory extraction", summary: draft.memoryModel.isEmpty ? PiBotProfileDraft.activeMainModel : draft.memoryModel) {
            SettingsNote("Reviews new conversation messages and saves useful facts into the bot's memory, on the extraction schedule and when the bot goes idle, if memory extraction is enabled. Doesn't affect chat or subagents.")
            BotSettingsModelPicker(providers: providers, selection: $draft.memoryModel, label: "Memory extraction model", emptyLabel: PiBotProfileDraft.activeMainModel)
            if !draft.memoryModel.isEmpty { BotSettingsModelFacts(providers: providers, model: draft.memoryModel) }
        }
    }

    private var pool: some View {
        BotSettingsEditorSection(title: "Model pool", summary: draft.poolModels.isEmpty ? "Main model only" : "Main model + " + draft.poolModels.joined(separator: ", ")) {
            SettingsNote("Additional models available for subagents. The main model can always spawn subagents using itself, even when this list is empty.")
            if !draft.main.isEmpty {
                Text("Main model \(draft.main)").font(.system(size: 12.5))
                BotSettingsModelFacts(providers: providers, model: draft.main)
            }
            ForEach(Array(draft.pool.enumerated()), id: \.element.id) { index, entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        BotSettingsModelPicker(providers: providers, selection: Binding(
                            get: { draft.pool.first { $0.id == entry.id }?.model ?? "" },
                            set: { value in if let at = draft.pool.firstIndex(where: { $0.id == entry.id }) { draft.pool[at].model = value } }),
                            label: "Pool model \(index + 1)")
                        Button { draft.pool.removeAll { $0.id == entry.id } } label: { DashboardLucideIcon(glyph: .trash, size: 13) }
                            .accessibilityLabel("Remove pool model \(index + 1)")
                    }
                    BotSettingsModelFacts(providers: providers, model: entry.model)
                    TextField("Notes (optional)", text: Binding(
                        get: { draft.pool.first { $0.id == entry.id }?.useFor ?? "" },
                        set: { value in if let at = draft.pool.firstIndex(where: { $0.id == entry.id }) { draft.pool[at].useFor = value } }))
                        .dashboardInput().accessibilityLabel("Notes on pool model \(index + 1)")
                }
            }
            Button { draft.pool.append(.init()) } label: { BotSettingsActionLabel(title: "Add pool model", glyph: .plus) }
        }
    }
}

private struct BotSettingsEditorSection<Content: View>: View {
    let title: String
    let summary: String
    let problem: String?
    @ViewBuilder let content: Content
    @State private var expanded: Bool

    init(title: String, summary: String, problem: String? = nil, open: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.summary = summary; self.problem = problem; self.content = content()
        _expanded = State(initialValue: open || problem != nil)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) { content }.padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let problem { SettingsError(problem) }
                else { SettingsNote(summary).lineLimit(2) }
            }.padding(.vertical, 4)
        }
        .onChange(of: problem) { _, value in if value != nil { expanded = true } }
    }
}
