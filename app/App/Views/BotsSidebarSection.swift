import SwiftUI
import WovenMatterClient
import WovenMatterCore

/// Thread dropdowns start closed. Everything else in the sidebar starts open and
/// stores collapsed keys, so these keep their own store of opened bots.
enum BotThreadDisclosure {
    static let storageKey = "wovenmatter.sidebar.expanded-bot-threads"

    static func decode(_ raw: String) -> Set<String> {
        guard let data = raw.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(values)
    }

    static func encode(_ values: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(values.sorted()), let raw = String(data: data, encoding: .utf8) else { return "[]" }
        return raw
    }
}

/// Bots from every machine: one section per machine, titled by machine when there are several.
struct BotsSidebar: View {
    @Bindable var bots: BotsModel
    let selectedTarget: BotTarget?
    let isWorkspaceDestination: Bool
    @Binding var disclosureRaw: String
    let onSelect: (BotTarget) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        let sessions = bots.orderedSessions
        if sessions.isEmpty {
            // Collapses like a machine's section, with its own key: there is no machine yet.
            let key = "bots:section"
            let expanded = AgentDisclosureStore.isExpanded(key, in: disclosureRaw)
            VStack(alignment: .leading, spacing: 0) {
                DisclosureHeading(title: "Bots", expanded: expanded) {
                    AgentDisclosureStore.toggle(key, in: &disclosureRaw)
                }
                if expanded {
                    RailRow(icon: .plus, title: "Set up bots", hoverID: "bots:setup", action: onOpenSettings)
                }
            }
            .padding(.bottom, 10)
        } else {
            ForEach(sessions) { session in
                BotsSidebarSection(
                    bots: session,
                    title: sessions.count == 1 ? "Bots" : "Bots on \(session.displayName)",
                    selectedTarget: selectedTarget?.machineID == session.machineID ? selectedTarget : nil,
                    isWorkspaceDestination: isWorkspaceDestination,
                    disclosureRaw: $disclosureRaw,
                    onSelect: onSelect,
                    onOpenSettings: onOpenSettings)
            }
        }
    }
}

struct BotsSidebarSection: View {
    @Bindable var bots: BotMachineSession
    var title = "Bots"
    let selectedTarget: BotTarget?
    let isWorkspaceDestination: Bool
    @Binding var disclosureRaw: String
    let onSelect: (BotTarget) -> Void
    let onOpenSettings: () -> Void

    @AppStorage(BotThreadDisclosure.storageKey) private var expandedThreadsRaw = "[]"
    @State private var creatingBot = false
    @State private var newBotName = ""
    @State private var renamingBotID: String?
    @State private var renamedBotName = ""
    @State private var deletingBot: PiBotSummary?
    @State private var creatingGroupForBotID: String?
    @State private var creatingGroup = false
    @State private var newGroupName = ""
    @State private var renamingGroupID: String?
    @State private var renamedGroupName = ""
    @State private var deletingGroup: PiBotGroup?

    private var sectionKey: String { "bots:section:" + bots.machineID }
    private var layout: PiBotSidebarLayout { bots.layout }
    private var expandedThreads: Set<String> { BotThreadDisclosure.decode(expandedThreadsRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureHeading(
                title: title,
                expanded: AgentDisclosureStore.isExpanded(sectionKey, in: disclosureRaw)
            ) {
                AgentDisclosureStore.toggle(sectionKey, in: &disclosureRaw)
            }
            .contextMenu {
                if bots.supportsGroups {
                    Button("New group…") {
                        newGroupName = ""
                        creatingGroup = true
                    }
                    .disabled(!bots.isConnected)
                }
                Button("Bot settings…", action: onOpenSettings)
            }
            .popover(isPresented: $creatingGroup, arrowEdge: .trailing) {
                BotNamePopover(title: "New group", placeholder: "Group name", actionTitle: "Create", name: $newGroupName,
                               onCancel: { creatingGroup = false }) {
                    let name = trimmed(newGroupName)
                    creatingGroup = false
                    Task { await bots.createGroup(name: name) }
                }
            }
            if AgentDisclosureStore.isExpanded(sectionKey, in: disclosureRaw) {
                content
            }
        }
        .padding(.bottom, 10)
        .task(id: selectedTarget) {
            // A thread opened from chat must be visible in the sidebar.
            if let target = selectedTarget, target.conversationID != nil { setExpanded(target.botID, true) }
        }
        .onChange(of: bots.isConnected) { _, connected in
            if connected { Task { await loadExpandedThreads() } }
        }
        .task(id: bots.bots.map(\.id)) { await loadExpandedThreads() }
    }

    @ViewBuilder private var content: some View {
        newBotRow
        statusRow
        ForEach(layout.pinned) { row in botRow(row) }
        ForEach(layout.groups) { group in groupSection(group) }
        ForEach(layout.ungrouped) { row in botRow(row) }
    }

    @ViewBuilder private var statusRow: some View {
        if let text = statusText {
            Button(action: onOpenSettings) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(WovenPalette.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var statusText: String? {
        switch bots.machine.state {
        case .ready: bots.isConnected ? (bots.isCompatible ? nil : "Update bots on \(bots.displayName)") : "Connecting to your bots…"
        case .starting: "Starting bots…"
        case .off: "Bots are off"
        case .unreachable: "\(bots.displayName) is unavailable"
        case .needsUpdate: "Update everything to use these bots"
        case .failed: "Bots could not start"
        }
    }

    private var newBotRow: some View {
        RailRow(icon: .plus, title: "New bot", hoverID: "bots:new") {
            newBotName = ""
            creatingBot = true
        }
        .disabled(!bots.isConnected)
        .popover(isPresented: $creatingBot, arrowEdge: .trailing) {
            BotNamePopover(title: "New bot", placeholder: "Bot name", actionTitle: "Create", name: $newBotName,
                           onCancel: { creatingBot = false }) {
                let name = trimmed(newBotName)
                creatingBot = false
                Task {
                    if let bot = await bots.createBot(name: name) { onSelect(BotTarget(machineID: bots.machineID, botID: bot.id)) }
                }
            }
        }
    }

    @ViewBuilder private func groupSection(_ item: PiBotSidebarLayout.Group) -> some View {
        let key = "bots:group:" + item.group.id
        let expanded = AgentDisclosureStore.isExpanded(key, in: disclosureRaw)
        DisclosureHeading(title: item.group.name, expanded: expanded) {
            AgentDisclosureStore.toggle(key, in: &disclosureRaw)
        }
        .contextMenu { groupMenu(item.group) }
        .popover(isPresented: Binding(get: { renamingGroupID == item.group.id },
                                      set: { if !$0, renamingGroupID == item.group.id { renamingGroupID = nil } }), arrowEdge: .trailing) {
            BotNamePopover(title: "Rename group", placeholder: "Group name", actionTitle: "Rename", name: $renamedGroupName,
                           onCancel: { renamingGroupID = nil }) {
                let name = trimmed(renamedGroupName)
                renamingGroupID = nil
                Task { await bots.renameGroup(id: item.group.id, name: name) }
            }
        }
        .confirmationDialog("Remove the \(item.group.name) group?", isPresented: Binding(
            get: { deletingGroup?.id == item.group.id }, set: { if !$0 { deletingGroup = nil } }
        ), titleVisibility: .visible) {
            Button("Remove Group", role: .destructive) {
                deletingGroup = nil
                Task { await bots.deleteGroup(id: item.group.id) }
            }
            Button("Cancel", role: .cancel) { deletingGroup = nil }
        } message: {
            Text("Its bots stay and move back to the main list.")
        }
        if expanded {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(item.rows) { row in botRow(row) }
                if item.rows.isEmpty {
                    Text("No bots in this group")
                        .font(.system(size: 11))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }
            .padding(.leading, 8)
        }
    }

    @ViewBuilder private func groupMenu(_ group: PiBotGroup) -> some View {
        Button("Rename group") {
            renamedGroupName = group.name
            renamingGroupID = group.id
        }
        Button("Move up") { Task { await bots.moveGroup(id: group.id, by: -1) } }
        Button("Move down") { Task { await bots.moveGroup(id: group.id, by: 1) } }
        Divider()
        Button("Remove group…", role: .destructive) { deletingGroup = group }
    }

    private func botRow(_ row: PiBotSidebarLayout.Row) -> AnyView {
        let bot = row.bot
        let expanded = expandedThreads.contains(bot.id)
        let onMain = isWorkspaceDestination && selectedTarget?.botID == bot.id && selectedTarget?.conversationID == nil
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                RailRow(
                    icon: bot.isAdmin ? .settings : bot.manager ? .circleUser : .bot,
                    title: bot.name,
                    hoverID: "bot:" + bot.id,
                    trailing: statusLabel(bot),
                    selected: onMain
                ) {
                    onSelect(BotTarget(machineID: bots.machineID, botID: bot.id))
                }
                .contextMenu { botMenu(bot) }
                Button { toggleThreads(bot.id) } label: {
                    LucideIcon(glyph: .chevronDown, size: 12)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .frame(width: 24, height: WovenMetrics.rowHeight)
                }
                .buttonStyle(WovenIconButtonStyle())
                .help(expanded ? "Hide threads" : "Show threads")
                .accessibilityLabel(expanded ? "Hide \(bot.name) threads" : "Show \(bot.name) threads")
                .accessibilityAddTraits(.isButton)
            }
            .popover(isPresented: Binding(get: { renamingBotID == bot.id },
                                          set: { if !$0, renamingBotID == bot.id { renamingBotID = nil } }), arrowEdge: .trailing) {
                BotNamePopover(title: "Rename bot", placeholder: "Bot name", actionTitle: "Rename", name: $renamedBotName,
                               onCancel: { renamingBotID = nil }) {
                    let name = trimmed(renamedBotName)
                    renamingBotID = nil
                    Task { await bots.rename(botID: bot.id, name: name) }
                }
            }
            .popover(isPresented: Binding(get: { creatingGroupForBotID == bot.id },
                                          set: { if !$0, creatingGroupForBotID == bot.id { creatingGroupForBotID = nil } }), arrowEdge: .trailing) {
                BotNamePopover(title: "New group", placeholder: "Group name", actionTitle: "Create", name: $newGroupName,
                               onCancel: { creatingGroupForBotID = nil }) {
                    let name = trimmed(newGroupName)
                    creatingGroupForBotID = nil
                    Task { await bots.createGroup(name: name, adding: bot.id) }
                }
            }
            .confirmationDialog("Delete \(bot.name)?", isPresented: Binding(
                get: { deletingBot?.id == bot.id }, set: { if !$0 { deletingBot = nil } }
            ), titleVisibility: .visible) {
                Button("Delete Bot", role: .destructive) {
                    deletingBot = nil
                    Task { await bots.delete(botID: bot.id) }
                }
                Button("Cancel", role: .cancel) { deletingBot = nil }
            } message: {
                Text("You can restore it from Settings → Bots.")
            }
            if expanded { threadRows(bot) }
        }
        .padding(.leading, row.isTeamMember ? 8 : 0))
    }

    @ViewBuilder private func threadRows(_ bot: PiBotSummary) -> some View {
        let threads = bots.threads(for: bot.id)
        VStack(alignment: .leading, spacing: 1) {
            if threads.isEmpty {
                Text(bots.threadsByBot[bot.id] == nil ? "Loading threads…" : "No threads yet")
                    .font(.system(size: 11))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            ForEach(threads) { thread in
                RailRow(
                    icon: .messageSquare,
                    title: thread.label,
                    hoverID: "bot-thread:\(bot.id):\(thread.conversationId)",
                    showsPin: thread.isPinned,
                    selected: isWorkspaceDestination && selectedTarget?.botID == bot.id && selectedTarget?.conversationID == thread.conversationId,
                    pinMenuTitle: thread.isPinned ? "Unpin thread" : "Pin thread",
                    onTogglePin: {
                        Task { await bots.setPinned(botID: bot.id, conversationID: thread.conversationId, pinned: !thread.isPinned) }
                    }
                ) {
                    onSelect(BotTarget(machineID: bots.machineID, botID: bot.id, conversationID: thread.conversationId))
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 24)
    }

    @ViewBuilder private func botMenu(_ bot: PiBotSummary) -> some View {
        if !bot.isAdmin {
            Button("Rename") {
                renamedBotName = bot.name
                renamingBotID = bot.id
            }
            if bots.supportsGroups {
                Menu("Move to group") {
                    ForEach(bots.groups.sorted { ($0.position, $0.id) < ($1.position, $1.id) }) { group in
                        Button(group.name) { Task { await bots.setGroup(botID: bot.id, groupID: group.id) } }
                            .disabled(bot.groupId == group.id)
                    }
                    if !bots.groups.isEmpty { Divider() }
                    Button("New group…") {
                        newGroupName = ""
                        creatingGroupForBotID = bot.id
                    }
                    if bot.groupId != nil {
                        Divider()
                        Button("Remove from group") { Task { await bots.setGroup(botID: bot.id, groupID: nil) } }
                    }
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { deletingBot = bot }
        } else {
            Button("Bot settings…", action: onOpenSettings)
        }
    }

    private func statusLabel(_ bot: PiBotSummary) -> String? {
        switch bot.modelStatus?.kind {
        case "paused": "Paused"
        case "fallback": "Fallback"
        default: nil
        }
    }

    private func toggleThreads(_ botID: String) {
        let opening = !expandedThreads.contains(botID)
        setExpanded(botID, opening)
        if opening { Task { await bots.loadThreads(botID: botID) } }
    }

    private func setExpanded(_ botID: String, _ expanded: Bool) {
        var values = expandedThreads
        if expanded { values.insert(botID) } else { values.remove(botID) }
        expandedThreadsRaw = BotThreadDisclosure.encode(values)
    }

    private func loadExpandedThreads() async {
        guard bots.isConnected else { return }
        let present = Set(bots.bots.map(\.id))
        for botID in expandedThreads.intersection(present) where bots.threadsByBot[botID] == nil {
            await bots.loadThreads(botID: botID)
        }
    }

    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private struct BotNamePopover: View {
    let title: String
    let placeholder: String
    let actionTitle: String
    @Binding var name: String
    let onCancel: () -> Void
    let onCommit: () -> Void
    @FocusState private var focused: Bool

    private var canCommit: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 14, weight: .semibold))
            TextField(placeholder, text: $name)
                .focused($focused)
                .quietTextInput()
                .onSubmit { if canCommit { onCommit() } }
                .onChange(of: name) { _, value in if value.count > 80 { name = String(value.prefix(80)) } }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(actionTitle, action: onCommit).keyboardShortcut(.defaultAction).disabled(!canCommit)
            }
        }
        .padding(16)
        .frame(width: 280)
        .task { focused = true }
    }
}
