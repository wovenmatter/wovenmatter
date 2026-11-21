import SwiftUI

/// The Bots tab's list, in the Mac rail's order: the Forum, then Admin Bot
/// and the orchestrator, the groups, and everyone else. A row opens the
/// channel; its chevron shows the threads, pinned first and then newest.
/// Thread lists start closed.
struct BotsList: View {
    @Bindable var bots: BotsStore
    /// The channel shown beside the list, on iPad.
    let selected: BotTarget?
    let onOpen: (BotTarget) -> Void
    @State private var expanded: Set<String> = []

    private var host: String { bots.hostMachineID ?? "" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let status = BotsStatusCaption.text(bots) {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .accessibilityIdentifier("bots-status")
                }
                forumRow
                ForEach(bots.layout.pinned) { row in botRow(row) }
                ForEach(bots.layout.groups) { group in
                    Text(group.group.name)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.rows) { row in botRow(row) }
                }
                ForEach(bots.layout.ungrouped) { row in botRow(row) }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.never)
        .onChange(of: bots.isConnected) { _, connected in
            if connected { Task { await loadOpenThreads() } }
        }
        .accessibilityIdentifier("bots-list")
    }

    // MARK: Rows

    private var forumRow: some View {
        let isOpen = expanded.contains(BotTarget.forumBotID)
        let target = BotTarget.forum(machineID: host)
        return VStack(alignment: .leading, spacing: 2) {
            BotsListRow(glyph: .messageSquareReply, title: "Forum", trailing: bots.forum?.paused == true ? "Paused" : nil,
                        expanded: isOpen, selected: selected == target,
                        onOpen: { onOpen(target) }, onToggle: { toggle(BotTarget.forumBotID) })
                .accessibilityIdentifier("bots-forum")
            if isOpen {
                let threads = PiBotForumThread.sorted(bots.forum?.threads ?? [])
                if threads.isEmpty {
                    BotsListNote(text: bots.forum == nil ? "Loading threads…" : "No threads yet")
                }
                ForEach(threads) { thread in
                    let target = BotTarget.forum(machineID: host, roomID: thread.roomId)
                    BotsThreadRow(title: thread.label, isPinned: thread.isPinned, selected: selected == target,
                                  canPin: bots.isConnected, onOpen: { onOpen(target) }) {
                        Task { await bots.setForumThreadPinned(roomID: thread.roomId, pinned: !thread.isPinned) }
                    }
                    .accessibilityIdentifier("bots-forum-thread-\(thread.roomId)")
                }
            }
        }
    }

    private func botRow(_ row: PiBotSidebarLayout.Row) -> some View {
        let bot = row.bot
        let isOpen = expanded.contains(bot.id)
        let target = BotTarget(machineID: host, botID: bot.id)
        return VStack(alignment: .leading, spacing: 2) {
            BotsListRow(glyph: bot.isAdmin ? .settings : bot.manager ? .circleUser : .bot, title: bot.name,
                        trailing: Self.statusLabel(bot), expanded: isOpen, selected: selected == target,
                        onOpen: { onOpen(target) }, onToggle: { toggle(bot.id) })
                .accessibilityIdentifier("bots-bot-\(bot.id)")
            if isOpen {
                let threads = bots.threads(for: bot.id)
                if threads.isEmpty {
                    BotsListNote(text: bots.threadsByBot[bot.id] == nil ? "Loading threads…" : "No threads yet")
                }
                ForEach(threads) { thread in
                    let target = BotTarget(machineID: host, botID: bot.id, conversationID: thread.conversationId)
                    BotsThreadRow(title: thread.label, isPinned: thread.isPinned, selected: selected == target,
                                  canPin: bots.isConnected, onOpen: { onOpen(target) }) {
                        Task { await bots.setPinned(botID: bot.id, conversationID: thread.conversationId, pinned: !thread.isPinned) }
                    }
                    .accessibilityIdentifier("bots-thread-\(bot.id)-\(thread.conversationId)")
                }
            }
        }
        .padding(.leading, row.isTeamMember ? 16 : 0)
    }

    /// As the Mac's row says it: not "Paused", which is only the Forum's.
    static func statusLabel(_ bot: PiBotSummary) -> String? {
        switch bot.modelStatus?.kind {
        case .paused: "Out of usage"
        case .fallback: "Fallback"
        case .returned, nil: nil
        }
    }

    private func toggle(_ id: String) {
        if expanded.remove(id) == nil {
            expanded.insert(id)
            if id != BotTarget.forumBotID { Task { await bots.loadThreads(botID: id) } }
        }
    }

    private func loadOpenThreads() async {
        for id in expanded where id != BotTarget.forumBotID && bots.threadsByBot[id] == nil {
            await bots.loadThreads(botID: id)
        }
    }
}

/// What the bots are doing when it is not simply ready, in the Mac rail's words.
/// A host that is away is named, since it is what is unavailable.
enum BotsStatusCaption {
    @MainActor static func text(_ bots: BotsStore) -> String? {
        switch bots.state {
        case .ready: bots.isConnected ? nil : "Connecting to your bots…"
        case .starting: "Starting bots…"
        case .off: "Bots are off"
        case .unreachable: bots.hostMachine.map { "\($0.name) is offline. Your bots answer when it’s back." }
            ?? "Your bots answer when the machine they run on is back."
        case .failed: "Bots could not start"
        case .transferring: "Moving bots…"
        }
    }
}

private struct BotsListRow: View {
    let glyph: LucideGlyph
    let title: String
    let trailing: String?
    let expanded: Bool
    let selected: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void
    @Environment(\.wovenTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    LucideIcon(glyph: glyph, size: 18)
                        .frame(width: 34, height: 34)
                        .background(theme.palette.themeSoft, in: Circle())
                    Text(title)
                        .font(.body)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(.footnote)
                            .foregroundStyle(WovenPalette.mutedForeground)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 8)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(trailing.map { "\(title), \($0)" } ?? title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: onToggle) {
                LucideIcon(glyph: .chevronDown, size: 13)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(WovenIconButtonStyle())
            .accessibilityLabel(expanded ? "Hide \(title) threads" : "Show \(title) threads")
        }
        .padding(.trailing, 2)
        .background(selected ? theme.palette.themeSoft : .clear,
                    in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
        .hoverEffect(.highlight)
        .foregroundStyle(WovenPalette.foreground)
    }
}

private struct BotsThreadRow: View {
    let title: String
    let isPinned: Bool
    let selected: Bool
    let canPin: Bool
    let onOpen: () -> Void
    let onTogglePin: () -> Void
    @Environment(\.wovenTheme) private var theme

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                LucideIcon(glyph: .messageSquare, size: 15)
                    .foregroundStyle(WovenPalette.mutedForeground)
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isPinned {
                    LucideIcon(glyph: .pin, size: 13)
                        .foregroundStyle(WovenPalette.mutedForeground)
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
            .frame(minHeight: 44)
            .background(selected ? theme.palette.themeSoft : .clear,
                        in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 34)
        .hoverEffect(.highlight)
        .foregroundStyle(WovenPalette.foreground)
        .contextMenu {
            Button(isPinned ? "Unpin thread" : "Pin thread", action: onTogglePin).disabled(!canPin)
        }
        .accessibilityLabel(isPinned ? "\(title), pinned" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct BotsListNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(WovenPalette.mutedForeground)
            .padding(.leading, 74)
            .frame(minHeight: 32)
    }
}
