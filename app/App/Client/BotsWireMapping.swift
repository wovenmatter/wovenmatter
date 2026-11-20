import Foundation
import WovenProtocol

// What the bots views show, from the runtime's shapes (`BotsWire`) and from
// what the library holds while the home machine is away.

enum BotsDate {
    /// The runtime writes ISO 8601 times, with or without fractional seconds.
    static func parse(_ text: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? .distantPast
    }
}

extension BotReplyIssue {
    init?(wire: String?) {
        switch wire {
        case "signIn": self = .signIn
        case "limit": self = .limit
        default: return nil
        }
    }
}

extension PiBotSummary {
    init(_ bot: BotsWire.BotSummary) {
        self.init(id: bot.id, name: bot.name, isAdmin: bot.kind == "admin", manager: bot.manager, managerId: bot.managerId,
                  orchestrator: bot.orchestrator, groupId: bot.groupId, profileId: bot.profileId,
                  profileName: bot.profileName, defaultProfile: bot.defaultProfile,
                  modelStatus: bot.modelStatus.map(ModelStatus.init))
    }

    /// A bot as the library holds it: no group, profile or model status.
    init(saved bot: SavedBot) {
        self.init(id: bot.id, name: bot.name, isAdmin: bot.isAdmin, manager: bot.manager, managerId: bot.managerID,
                  orchestrator: bot.orchestrator, groupId: nil, profileId: nil, profileName: nil, defaultProfile: false,
                  modelStatus: nil)
    }
}

extension PiBotSummary.ModelStatus {
    init(_ status: BotsWire.ModelStatusSummary) {
        let kind: Kind = switch status.kind {
        case "paused": .paused
        case "returned": .returned
        default: .fallback
        }
        self.init(kind: kind, at: status.at, primary: status.primary, active: status.active, limits: status.limits.map { limit in
            let kind: Limit.Kind = switch limit.kind {
            case "five_hour": .fiveHour
            case "weekly": .weekly
            case "credits": .credits
            default: .other
            }
            return Limit(model: limit.model, account: limit.account, kind: kind, resetsAt: limit.resetsAt, retryAt: limit.retryAt)
        })
    }
}

extension PiBotThread {
    init(_ thread: BotsWire.ThreadSummary) {
        self.init(conversationId: thread.conversationId, parentConversationId: thread.parentConversationId,
                  forkedAt: thread.forkedAt, title: thread.title, createdAt: BotsDate.parse(thread.createdAt),
                  isPinned: thread.pinned == true)
    }

    init(saved chat: SavedBotChat) {
        self.init(conversationId: chat.conversationID, parentConversationId: chat.parentConversationID, forkedAt: nil,
                  title: chat.session.title, createdAt: chat.session.createdAt, isPinned: chat.session.pinned)
    }
}

extension PiBotGroup {
    init(_ group: BotsWire.Group) {
        self.init(id: group.id, name: group.name, position: group.position)
    }
}

extension PiBotDisplayEntry {
    init(_ entry: BotsWire.DisplayEntry) {
        self.init(id: entry.id, conversationId: entry.conversationId, isUser: entry.role == "user", text: entry.text,
                  error: entry.error, issue: BotReplyIssue(wire: entry.issue), isStopped: entry.stopped == true,
                  pages: (entry.pages ?? []).enumerated().map { index, page in
                      ConversationHTMLRenderReference(id: "\(entry.id):\(index)", title: page.title, height: page.height,
                                                      digest: page.digest)
                  })
    }

    /// A saved conversation's messages: what was said, a failure on the reply it ended, and a stop.
    static func saved(_ items: [SessionItem], conversationID: Int) -> [PiBotDisplayEntry] {
        var entries: [PiBotDisplayEntry] = []
        func entry(_ item: SessionItem, isUser: Bool, text: String, error: String? = nil, stopped: Bool = false) -> PiBotDisplayEntry {
            PiBotDisplayEntry(id: item.sequence, conversationId: conversationID, isUser: isUser, text: text, error: error,
                              issue: nil, isStopped: stopped)
        }
        for item in items.sorted(by: { $0.sequence < $1.sequence }) {
            switch item.content {
            case .userMessage(let text, _): entries.append(entry(item, isUser: true, text: text))
            case .assistantMessage(let text): entries.append(entry(item, isUser: false, text: text))
            case .toolCall: break
            case .htmlPage(let page):
                var shown = entry(item, isUser: false, text: "")
                shown.pages = [ConversationHTMLRenderReference(id: item.id, title: page.title, height: page.height,
                                                               digest: page.digest)]
                entries.append(shown)
            case .notice(let notice) where notice.kind == .interrupted:
                if let last = entries.last, !last.isUser {
                    entries[entries.count - 1] = PiBotDisplayEntry(id: last.id, conversationId: last.conversationId, isUser: false,
                                                                   text: last.text, error: last.error, issue: last.issue,
                                                                   isStopped: true)
                } else {
                    entries.append(entry(item, isUser: false, text: "", stopped: true))
                }
            case .notice(let notice): entries.append(entry(item, isUser: false, text: "", error: notice.text))
            }
        }
        return entries
    }
}

extension PiBotConversationState {
    /// Adds or replaces entries by id, keeping first-seen order.
    static func merge(_ current: [PiBotDisplayEntry], _ incoming: [PiBotDisplayEntry]) -> [PiBotDisplayEntry] {
        var next = current
        var positions = Dictionary(next.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
        for entry in incoming {
            if let index = positions[entry.id] {
                next[index] = entry
            } else {
                positions[entry.id] = next.count
                next.append(entry)
            }
        }
        return next
    }

    /// The state an open starts from. Nothing carries over from before but messages still on
    /// their way: a run may have ended and the history window moved meanwhile.
    init(snapshot: BotsWire.ConversationSnapshot, pending: [Pending]) {
        self.init()
        entries = Self.merge([], snapshot.entries.map(PiBotDisplayEntry.init))
        running = snapshot.running
        streaming = snapshot.streaming
        let recorded = Set(entries.filter(\.isUser).map(\.text))
        self.pending = pending.filter { !recorded.contains($0.text) }
    }

    mutating func apply(_ event: BotsWire.StreamEvent) {
        switch event {
        case .run(let started):
            running = started
            if !started { streaming = nil }
        case .assistantStart(let text):
            streaming = text
        case .delta(let text):
            streaming = (streaming ?? "") + text
        case .entry(let wire):
            let entry = PiBotDisplayEntry(wire)
            if entry.isUser, let index = pending.firstIndex(where: { $0.text == entry.text }) {
                pending.remove(at: index)
            }
            entries = Self.merge(entries, [entry])
            if !entry.isUser { streaming = nil }
        case .error:
            break
        }
    }
}

// MARK: - The Forum

extension PiBotForumPost {
    init(_ post: BotsWire.ForumPost) {
        self.init(id: post.id, roomId: post.roomId, isUser: post.author == "user", name: post.name, text: post.text,
                  isScheduled: post.scheduled == true,
                  thread: post.thread.map { ThreadLink(roomId: $0.roomId, replies: $0.replies) },
                  unanswered: (post.unanswered ?? []).map {
                      Unanswered(botId: $0.botId, name: $0.name, reason: $0.reason, issue: BotReplyIssue(wire: $0.issue))
                  })
    }

    /// A room's saved posts: the person's, and each bot's or agent session's under the name it posted with.
    static func saved(_ items: [SessionItem], roomID: Int) -> [PiBotForumPost] {
        items.sorted { $0.sequence < $1.sequence }.compactMap { item in
            switch item.content {
            case .userMessage(let text, _):
                PiBotForumPost(id: item.sequence, roomId: roomID, isUser: item.author == nil, name: item.author?.name ?? "", text: text,
                               isScheduled: false, thread: nil, unanswered: [])
            case .assistantMessage(let text):
                PiBotForumPost(id: item.sequence, roomId: roomID, isUser: false, name: item.author?.name ?? "", text: text,
                               isScheduled: false, thread: nil, unanswered: [])
            case .toolCall, .notice, .htmlPage: nil
            }
        }
    }
}

extension PiBotForumThread {
    init(_ thread: BotsWire.ForumThreadSummary) {
        self.init(roomId: thread.roomId, title: thread.title, preview: thread.preview, createdAt: BotsDate.parse(thread.createdAt),
                  isPinned: thread.pinned == true, botIds: thread.botIds)
    }

    init(saved chat: SavedBotChat) {
        self.init(roomId: chat.conversationID, title: chat.session.title, preview: nil, createdAt: chat.session.createdAt,
                  isPinned: chat.session.pinned, botIds: [])
    }
}

extension PiBotForumState {
    init(_ state: BotsWire.ForumState) {
        self.init(paused: state.paused, bots: state.bots.map { Member(botId: $0.botId, active: $0.active) },
                  threads: state.threads.map(PiBotForumThread.init))
    }
}

extension PiBotForumRoomState {
    static func merge(_ current: [PiBotForumPost], _ incoming: [PiBotForumPost]) -> [PiBotForumPost] {
        guard !incoming.isEmpty else { return current }
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for post in incoming { byID[post.id] = post }
        return byID.values.sorted { $0.id < $1.id }
    }

    init(snapshot: BotsWire.ForumRoomSnapshot) {
        self.init(posts: Self.merge([], snapshot.posts.map(PiBotForumPost.init)), parent: snapshot.parent.map(PiBotForumPost.init),
                  thinking: snapshot.thinking, hasEarlier: snapshot.hasEarlier)
    }

    /// A new or changed post of room `roomID`. A thread also follows its starting post, which
    /// lives in the Forum.
    mutating func apply(_ post: PiBotForumPost, roomID: Int) {
        if post.roomId == roomID {
            posts = Self.merge(posts, [post])
        } else if post.id == parent?.id {
            parent = post
        }
    }
}

extension PiBotForumSchedule {
    init(_ schedule: BotsWire.ForumScheduleSummary) {
        let time = schedule.time.flatMap { text -> (hour: Int, minute: Int)? in
            let parts = text.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        self.init(id: schedule.id, text: schedule.text, repeat: Repeat(rawValue: schedule.repeat) ?? .once, time: time,
                  weekday: schedule.weekday, at: schedule.at.map { Date(timeIntervalSince1970: $0 / 1000) },
                  timeZone: TimeZone(identifier: schedule.timeZone) ?? .current)
    }
}

extension PiBotForumScheduleDraft {
    /// The `schedule` of `forum.schedules.save`.
    var wire: JSONValue {
        var fields: [String: JSONValue] = [
            "text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            "repeat": .string(`repeat`.rawValue),
            "timeZone": .string(timeZone.identifier),
        ]
        if everyone { fields["everyone"] = .bool(true) }
        else if !mentions.isEmpty { fields["mentions"] = .array(mentions.map(JSONValue.string)) }
        if `repeat` == .once {
            fields["at"] = .integer(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            fields["time"] = .string(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))
            if `repeat` == .weekly { fields["weekday"] = .integer(Int64(weekday)) }
        }
        return .object(fields)
    }
}

// MARK: - Models, profiles, containers

extension PiBotModelCatalog {
    init(_ catalog: BotsWire.ModelCatalog) {
        func rates(_ rates: BotsWire.PriceRates) -> PiBotPriceRates {
            PiBotPriceRates(input: rates.input, output: rates.output, cacheRead: rates.cacheRead, cacheWrite: rates.cacheWrite)
        }
        self.init(providers: catalog.providers.map { provider in
            PiBotProviderModels(id: provider.id, name: provider.name,
                                accessLabel: provider.access.kind == "unknown" ? nil : provider.access.label,
                                models: provider.models.map { model in
                let status: PiBotModelPricing.Status = switch model.pricing.status {
                case "listed": .listed
                case "zero": .zero
                default: .unknown
                }
                let pricing = PiBotModelPricing(status: status, rates: model.pricing.rates.map(rates), tiers: (model.pricing.tiers ?? []).map {
                    .init(rates: PiBotPriceRates(input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cacheWrite: $0.cacheWrite),
                          inputTokensAbove: $0.inputTokensAbove)
                })
                return PiBotModelOption(id: model.id, name: model.name, reasoning: model.reasoning, contextWindow: model.contextWindow,
                                        maxTokens: model.maxTokens, input: model.input ?? [], pricing: pricing,
                                        limit: model.limit.map { .init(label: $0.label, resetsAt: $0.resetsAt) })
            })
        }, roles: PiBotRoles(catalog.roles), reasoningLevels: catalog.reasoningLevels)
    }
}

extension PiBotRoles {
    init(_ roles: BotsWire.Roles) {
        self.init(titles: roles.titles, titlesReasoning: roles.titlesReasoning)
    }
}

extension PiBotProfile {
    static func list(_ list: BotsWire.ProfilesList) -> [PiBotProfile] {
        list.profiles.map { profile in
            PiBotProfile(id: profile.id, name: profile.name, main: profile.main, fallbacks: profile.fallbacks ?? [],
                         memoryModel: profile.memoryModel, guidance: profile.guidance,
                         pool: profile.pool.map { PoolModel(model: $0.model, useFor: $0.useFor) },
                         isDefault: profile.default == true || profile.id == list.defaultId)
        }
    }
}

extension PiBotProfileDraft {
    /// The `profile` of `profiles.save`.
    var wire: JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(id.trimmingCharacters(in: .whitespacesAndNewlines)),
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "main": .string(main),
            "pool": .array(pool.filter { !$0.model.isEmpty }.map { entry in
                var item: [String: JSONValue] = ["model": .string(entry.model)]
                let useFor = entry.useFor.trimmingCharacters(in: .whitespacesAndNewlines)
                if !useFor.isEmpty { item["useFor"] = .string(useFor) }
                return .object(item)
            }),
            "guidance": .string(guidance),
        ]
        if !fallbackModels.isEmpty { fields["fallbacks"] = .array(fallbackModels.map(JSONValue.string)) }
        fields["memoryModel"] = memoryModel.isEmpty || memoryModel == Self.activeMainModel ? JSONValue.null : JSONValue.string(memoryModel)
        return .object(fields)
    }
}

extension PiBotEnvironment {
    init(_ environment: BotsWire.EnvironmentSummary) {
        let state: State = switch environment.state {
        case "running": .running
        case "stopped": .stopped
        case "missing": .missing
        default: .unavailable
        }
        self.init(state: state, busy: environment.busy)
    }
}

extension BotsUpdateProgress {
    /// The words for one `runtime.update` push.
    init(botID: String?, phase: String, error: String?) {
        let what: String = switch phase {
        case "stopping": "Stopping running work"
        case "updating": "Updating"
        case "updated": "Updated"
        case "rolledBack": "Rolled back to the previous version"
        case "skipped": "Already up to date"
        case "done": error == nil ? "Update finished" : "Update failed"
        default: phase
        }
        self.init(botID: botID, text: [what, error].compactMap { $0 }.joined(separator: ": "))
    }
}
