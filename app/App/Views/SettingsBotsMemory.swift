import SwiftUI
import WovenMatterClient

struct BotSettingsMemory: View {
    let state: BotSettingsState
    let bots: [PiBotSummary]
    @State private var picked: String?
    @State private var facts: [String]?
    @State private var factsBotID: String?
    @State private var observer: UUID?
    private var bot: PiBotSummary? { bots.first { $0.id == picked } ?? bots.first }

    var body: some View {
        SettingsSection(title: "Memory", detail: "Facts a bot keeps from its conversations and sees on every turn.") {
            SettingsRow(title: "Bot", detail: "Changes apply from its next reply.") {
                BotSettingsReferencePicker(selection: bot?.id ?? "", options: bots.map { .init($0.id, $0.name) },
                    label: "Bot whose memory to show") { picked = $0 }
            }
            if let bot {
                if factsBotID != bot.id || facts == nil { SettingsEmpty("Loading…") }
                else if facts?.isEmpty == true { SettingsEmpty("\(bot.name) doesn't remember anything yet.") }
                else {
                    ForEach(facts ?? [], id: \.self) { fact in
                        BotSettingsFactRow(fact: fact, onSave: { await change(fact: fact, text: $0) }, onDelete: { remove(fact) })
                    }
                }
                BotSettingsFactForm(label: "New memory", action: "Add", onSave: { await change(fact: nil, text: $0) }).id(bot.id)
            }
        }
        .task(id: "\(state.bots.connection.rawValue):\(bot?.id ?? "")") {
            if let observer { state.bots.stopObservingMemory(observer) }
            guard let id = bot?.id, state.bots.isConnected else { return }
            observer = state.bots.observeMemory { changed in
                if changed == id { Task { await refresh(id) } }
            }
            await refresh(id)
        }
        .onDisappear { if let observer { state.bots.stopObservingMemory(observer) } }
    }

    private func refresh(_ id: String) async {
        await state.load { client in
            let next = try await client.memory(botID: id)
            guard bot?.id == id else { return }
            facts = next; factsBotID = id
        }
    }

    private func change(fact: String?, text: String) async -> Bool {
        guard let id = bot?.id else { return false }
        return await state.run { client in
            let next: [String]
            if let fact { next = try await client.updateMemory(botID: id, fact: fact, text: text) }
            else { next = try await client.addMemory(botID: id, text: text) }
            guard bot?.id == id else { return }
            facts = next; factsBotID = id
        }
    }

    private func remove(_ fact: String) {
        guard let id = bot?.id else { return }
        state.confirm("Delete this memory?\n\n\(fact)", action: "Delete") {
            Task {
                await state.run { client in
                    let next = try await client.deleteMemory(botID: id, fact: fact)
                    guard bot?.id == id else { return }
                    facts = next; factsBotID = id
                }
            }
        }
    }
}

private struct BotSettingsFactRow: View {
    let fact: String
    let onSave: (String) async -> Bool
    let onDelete: () -> Void
    @State private var editing = false

    var body: some View {
        Group {
            if editing {
                BotSettingsFactForm(label: "Edit memory", action: "Save", initial: fact, onSave: { text in
                    let saved: Bool
                    if text.trimmingCharacters(in: .whitespacesAndNewlines) == fact { saved = true }
                    else { saved = await onSave(text) }
                    if saved { editing = false }
                    return saved
                }, onCancel: { editing = false })
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text(fact).font(.settingsText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit") { editing = true }.accessibilityLabel("Edit memory: \(fact)")
                    Button(action: onDelete) { BotSettingsActionLabel(title: "Delete", glyph: .trash) }
                        .accessibilityLabel("Delete memory: \(fact)")
                }
                .frame(minHeight: SettingsMetrics.rowHeight)
            }
        }
    }
}

private struct BotSettingsFactForm: View {
    let label: String
    let action: String
    let onSave: (String) async -> Bool
    let onCancel: (() -> Void)?
    @State private var value: String
    @State private var saving = false
    @FocusState private var focused: Bool

    init(label: String, action: String, initial: String = "", onSave: @escaping (String) async -> Bool,
         onCancel: (() -> Void)? = nil) {
        self.label = label; self.action = action; self.onSave = onSave; self.onCancel = onCancel
        _value = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(onCancel == nil ? "Something this bot should remember" : "", text: $value)
                .dashboardInput().accessibilityLabel(label).focused($focused)
                .onChange(of: value) { _, text in if text.count > 1000 { value = String(text.prefix(1000)) } }
                .onSubmit { save() }.onExitCommand { onCancel?() }
            Button(saving ? "Saving…" : action) { save() }
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let onCancel { Button("Cancel", action: onCancel) }
        }
        .disabled(saving)
        .task {
            // The field has to be in the window before it can take focus.
            guard onCancel != nil else { return }
            await Task.yield()
            focused = true
        }
    }

    private func save() {
        guard !saving, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        Task {
            if await onSave(value), onCancel == nil { value = "" }
            saving = false
        }
    }
}
