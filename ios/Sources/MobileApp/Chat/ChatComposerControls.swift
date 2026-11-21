import SwiftUI
import UIKit

/// Native switch semantics at 65% inside a full 44-point touch frame, as the
/// style guide asks for iPhone Tools popouts.
private struct CompactToolToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label.font(.callout)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden().toggleStyle(SwitchToggleStyle(tint: WovenPalette.primary))
                .fixedSize().scaleEffect(0.65).frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

/// The composer's one compact row: add, model name, thinking level,
/// permission key, tools icon, then send or stop. Each opens a popout driven by
/// the chat's settings, as the Mac composer's are: the open session's, or for
/// a chat not started yet what its runtime offers, kept until it starts.
struct ChatComposerControls<Accessory: View, Submission: View>: View {
    let settings: SessionSettings?
    /// The open session, for its tools; nil for a chat not started yet.
    let sessionID: String?
    let isUpdating: Bool
    /// The last change that failed.
    let error: String?
    /// Makes a change; true once it took.
    let apply: @MainActor (SessionSettingsChange) async -> Bool
    let tools: AgentToolsStore
    /// The chat can be changed now: its owner is reachable and no turn runs.
    let configurable: Bool
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var submission: () -> Submission
    @Environment(\.wovenTheme) private var theme
    @State private var open: Popout?
    @State private var search = ""
    @State private var confirmTimers = false
    @State private var problem: String?

    private enum Popout: String, Identifiable {
        case model, thinking, permission, tools
        var id: String { rawValue }
    }

    private var modelLabel: String {
        settings?.model.map { SessionOptionMetadata.modelButtonLabel(id: $0, metadata: settings?.modelOptionMetadata[$0]) } ?? "Model"
    }

    private func thinkingName(_ id: String) -> String {
        settings?.thinkingOptionMetadata[id]?.name ?? sessionThinkingLabel(id)
    }

    private var thinkingLabel: String { settings?.thinking.map(thinkingName) ?? "Thinking" }

    private func permissionName(_ id: String) -> String {
        settings?.permissionOptionMetadata[id]?.name ?? sessionThinkingLabel(id)
    }

    private var permissionLabel: String { settings?.permission.map(permissionName) ?? "Permissions" }

    private var changeable: Bool { configurable && settings != nil && !isUpdating }

    var body: some View {
        HStack(spacing: 2) {
            accessory()
            Button { show(.model) } label: {
                HStack(spacing: 3) {
                    Text(modelLabel).lineLimit(1).minimumScaleFactor(0.8)
                    LucideIcon(glyph: .chevronDown, size: 10)
                }
                .font(.caption.weight(.medium))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .disabled(!changeable || (settings?.selectableModels.count ?? 0) < 2 && settings?.selectableModels.first == settings?.model)
            .accessibilityLabel("Choose model")
            .accessibilityValue(modelLabel)
            .accessibilityIdentifier("chat-model")
            .popover(item: popout(.model)) { _ in modelPopout }

            Button { show(.thinking) } label: {
                Text(thinkingLabel).font(.caption.weight(.medium)).lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!changeable || settings?.selectableThinkingLevels.isEmpty != false)
            .accessibilityLabel("Thinking level")
            .accessibilityValue(thinkingLabel)
            .accessibilityIdentifier("chat-thinking")
            .popover(item: popout(.thinking)) { _ in
                popoutPage("Thinking Level", rows: settings?.selectableThinkingLevels.count ?? 0) {
                    ForEach(settings?.selectableThinkingLevels ?? [], id: \.self) { id in
                        selectionRow(thinkingName(id), selected: id == settings?.thinking) { change(SessionSettingsChange(thinking: id)) }
                    }
                }
            }

            Button { show(.permission) } label: {
                LucideIcon(glyph: .keyRound, size: 18).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!changeable)
            .accessibilityLabel("Choose session permissions")
            .accessibilityValue(permissionLabel)
            .accessibilityIdentifier("chat-permissions")
            .popover(item: popout(.permission)) { _ in
                popoutPage("Permissions", rows: max(1, settings?.permissionOptions.count ?? 0) * 2) {
                    ForEach(settings?.permissionOptions ?? [], id: \.self) { id in
                        selectionRow(permissionName(id), detail: settings?.permissionOptionMetadata[id]?.description,
                                     selected: id == settings?.permission) { change(SessionSettingsChange(permission: id)) }
                    }
                }
            }

            Button { show(.tools) } label: {
                LucideIcon(glyph: .settings, size: 18).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sessionID == nil || !configurable)
            .accessibilityLabel("Session tools")
            .accessibilityIdentifier("chat-tools")
            .popover(item: popout(.tools)) { _ in toolsPopout }

            Spacer(minLength: 0)
            submission()
        }
        .foregroundStyle(WovenPalette.foreground)
    }

    // MARK: Popouts

    private var modelPopout: some View {
        let models = settings?.selectableModels ?? []
        let matches = models.filter {
            search.isEmpty || SessionOptionMetadata.modelLabel(id: $0, metadata: settings?.modelOptionMetadata[$0])
                .localizedCaseInsensitiveContains(search)
        }
        // Grouped by the connection each model comes through, in catalog order.
        var groups: [(name: String?, ids: [String])] = []
        for id in matches {
            let name = settings?.modelOptionMetadata[id]?.description
            if let index = groups.firstIndex(where: { $0.name == name }) { groups[index].ids.append(id) } else { groups.append((name, [id])) }
        }
        return popoutPage("Model", rows: models.count + groups.count + 2) {
            WovenSearchField(text: $search, prompt: "Search models").padding(.bottom, 6)
            ForEach(groups, id: \.name) { group in
                if let name = group.name, groups.count > 1 || !name.isEmpty {
                    Text(name).font(.caption.weight(.semibold)).foregroundStyle(WovenPalette.mutedForeground).padding(.top, 8)
                }
                ForEach(group.ids, id: \.self) { id in
                    selectionRow(SessionOptionMetadata.modelLabel(id: id, metadata: settings?.modelOptionMetadata[id]),
                                 selected: id == settings?.model) { change(SessionSettingsChange(model: id)) }
                }
            }
            if matches.isEmpty {
                Text("No matching models.").font(.callout).foregroundStyle(WovenPalette.mutedForeground)
            }
        }
        .onDisappear { search = "" }
    }

    private var toolsPopout: some View {
        popoutPage("Tools", rows: WorkspaceToolGroup.allCases.count) {
            if let sessionID {
                ForEach(WorkspaceToolGroup.allCases) { group in
                    Toggle(group.title, isOn: Binding(
                        get: { tools.policy(for: sessionID).enabled.contains(group) },
                        set: { setTool(group, enabled: $0, sessionID: sessionID) }))
                    .toggleStyle(CompactToolToggleStyle())
                    .padding(.horizontal, 4)
                }
            }
        }
        .confirmationDialog("Removing timer access pauses this session’s timers.", isPresented: $confirmTimers,
                            titleVisibility: .visible) {
            Button("Pause timers and remove access") {
                if let sessionID { setTool(.timers, enabled: false, sessionID: sessionID, confirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func popout(_ kind: Popout) -> Binding<Popout?> {
        Binding(get: { open == kind ? kind : nil }, set: { if $0 == nil, open == kind { open = nil } })
    }

    private func show(_ kind: Popout) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        problem = nil
        open = kind
    }

    private func popoutPage<Content: View>(_ title: String, rows: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            if let problem = problem ?? error {
                Text(problem).font(.caption).foregroundStyle(WovenPalette.danger)
            }
        }
        .padding(18)
        .frame(width: 310, height: min(440, CGFloat(rows) * 46 + 80))
        .background(theme.palette.workspace)
        .foregroundStyle(WovenPalette.foreground)
        .presentationCompactAdaptation(.popover)
    }

    private func selectionRow(_ label: String, detail: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).multilineTextAlignment(.leading)
                    if let detail { Text(detail).font(.caption).foregroundStyle(WovenPalette.mutedForeground) }
                }
                Spacer()
                if selected { LucideIcon(glyph: .check, size: 16).foregroundStyle(WovenPalette.primary) }
            }
            .font(.callout)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!changeable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func change(_ change: SessionSettingsChange) {
        guard changeable else { return }
        Task { if await apply(change) { open = nil } }
    }

    private func setTool(_ group: WorkspaceToolGroup, enabled: Bool, sessionID: String, confirmed: Bool = false) {
        Task {
            do {
                try await tools.setEnabledFromUI(group, enabled: enabled, sessionID: sessionID, confirmedPausingTimers: confirmed)
                problem = nil
            } catch WorkspaceToolError.timerPauseConfirmation {
                confirmTimers = true
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
