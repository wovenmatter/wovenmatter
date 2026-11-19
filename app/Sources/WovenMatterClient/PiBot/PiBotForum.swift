import Foundation

// The Forum: one group chat on the bots machine, with the user and every bot, and threads
// (docs/architecture/WOVEN_EVERYWHERE.md, "Forum"). The runtime owns these shapes. Decode
// what the app shows and tolerate additions.

public struct PiBotForumPost: Codable, Equatable, Identifiable, Sendable {
    /// A Forum post's thread: its room and how many posts it holds.
    public struct ThreadLink: Codable, Equatable, Sendable {
        public let roomId: Int
        public let replies: Int
        public init(roomId: Int, replies: Int) { self.roomId = roomId; self.replies = replies }
    }

    /// A mentioned bot that had nothing to post, and why.
    public struct Unanswered: Codable, Equatable, Identifiable, Sendable {
        public let botId: String
        public let name: String
        public let reason: String
        /// "signIn" or "limit" when Settings has the fix.
        public let issue: String?
        public init(botId: String, name: String, reason: String, issue: String? = nil) {
            self.botId = botId; self.name = name; self.reason = reason; self.issue = issue
        }
        public var id: String { botId }
        public var needsSignIn: Bool { issue == "signIn" }
        public var hitLimit: Bool { issue == "limit" }
    }

    /// Numbered across every room; never changes.
    public let id: Int
    public let roomId: Int
    /// "user" or "bot".
    public let author: String
    public let botId: String?
    /// The author's name when it posted, so a deleted bot's posts keep theirs.
    public let name: String
    public let text: String
    /// Bots the user asked to reply.
    public let mentions: [String]?
    public let scheduled: Bool?
    /// Posted for the bot from its final message, after a mention it did not answer itself.
    public let auto: Bool?
    public let createdAt: String
    public let thread: ThreadLink?
    public let unanswered: [Unanswered]?

    public init(id: Int, roomId: Int, author: String, botId: String? = nil, name: String, text: String,
                mentions: [String]? = nil, scheduled: Bool? = nil, auto: Bool? = nil, createdAt: String = "",
                thread: ThreadLink? = nil, unanswered: [Unanswered]? = nil) {
        self.id = id; self.roomId = roomId; self.author = author; self.botId = botId; self.name = name
        self.text = text; self.mentions = mentions; self.scheduled = scheduled; self.auto = auto
        self.createdAt = createdAt; self.thread = thread; self.unanswered = unanswered
    }

    public var isUser: Bool { author == "user" }
    public var isScheduled: Bool { scheduled == true }
}

public struct PiBotForumThread: Codable, Equatable, Identifiable, Sendable {
    public let roomId: Int
    public let parentPostId: Int
    /// Generated from the thread's first post; absent until then.
    public let title: String?
    /// The start of the thread's first post.
    public let preview: String?
    public let createdAt: String
    public let pinned: Bool?
    public let replies: Int?
    /// The bots that hear this thread.
    public let botIds: [String]?

    public init(roomId: Int, parentPostId: Int, title: String? = nil, preview: String? = nil, createdAt: String = "",
                pinned: Bool? = nil, replies: Int? = nil, botIds: [String]? = nil) {
        self.roomId = roomId; self.parentPostId = parentPostId; self.title = title; self.preview = preview
        self.createdAt = createdAt; self.pinned = pinned; self.replies = replies; self.botIds = botIds
    }

    public var id: Int { roomId }
    public var isPinned: Bool { pinned == true }
    public var hasTitle: Bool { title?.isEmpty == false }

    /// The title, else how the thread starts, else a placeholder.
    public var label: String {
        if let title, !title.isEmpty { return title }
        let start = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return start.isEmpty ? "New thread" : start
    }

    /// Pins first, then newest created, like a bot's threads.
    public static func sorted(_ threads: [PiBotForumThread]) -> [PiBotForumThread] {
        threads.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.roomId > rhs.roomId
        }
    }
}

/// `forum.get`: what every Forum view shares.
public struct PiBotForumState: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Identifiable, Sendable {
        public let botId: String
        /// In the Forum: it hears posts and may post.
        public let active: Bool
        public init(botId: String, active: Bool) { self.botId = botId; self.active = active }
        public var id: String { botId }
    }

    public let mainRoomId: Int
    public let paused: Bool
    public let latestPostId: Int?
    /// Every live bot, in or out.
    public let bots: [Member]
    public let threads: [PiBotForumThread]

    public init(mainRoomId: Int = 1, paused: Bool = false, latestPostId: Int? = nil, bots: [Member] = [],
                threads: [PiBotForumThread] = []) {
        self.mainRoomId = mainRoomId; self.paused = paused; self.latestPostId = latestPostId
        self.bots = bots; self.threads = threads
    }

    public var activeBotIDs: Set<String> { Set(bots.filter(\.active).map(\.botId)) }
    public func isActive(_ botID: String) -> Bool { bots.contains { $0.botId == botID && $0.active } }
    public func thread(roomID: Int) -> PiBotForumThread? { threads.first { $0.roomId == roomID } }
}

/// `forum.open`: one room as its subscription starts.
public struct PiBotForumRoomSnapshot: Decodable, Equatable, Sendable {
    public let subscriptionId: JSONValue?
    public let roomId: Int
    public let mainRoomId: Int
    /// A thread's starting post.
    public let parent: PiBotForumPost?
    /// The newest posts, oldest first.
    public let posts: [PiBotForumPost]
    public let hasEarlier: Bool?
    /// Bots with a turn running in this room.
    public let thinking: [String]?

    public init(subscriptionId: JSONValue? = nil, roomId: Int, mainRoomId: Int, parent: PiBotForumPost? = nil,
                posts: [PiBotForumPost] = [], hasEarlier: Bool? = nil, thinking: [String]? = nil) {
        self.subscriptionId = subscriptionId; self.roomId = roomId; self.mainRoomId = mainRoomId
        self.parent = parent; self.posts = posts; self.hasEarlier = hasEarlier; self.thinking = thinking
    }
}

/// What one open room shows.
public struct PiBotForumRoomState: Equatable, Sendable {
    /// Oldest first.
    public var posts: [PiBotForumPost] = []
    public var parent: PiBotForumPost?
    public var thinking: [String] = []
    /// The room holds posts older than the oldest one here.
    public var hasEarlier = false

    public init() {}

    /// Adds or replaces posts by id, in post order: a post is pushed again when it changes.
    public static func merge(_ current: [PiBotForumPost], _ incoming: [PiBotForumPost]) -> [PiBotForumPost] {
        guard !incoming.isEmpty else { return current }
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for post in incoming { byID[post.id] = post }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// A new or changed post of room `roomID`. A thread also follows its starting post, which
    /// lives in the Forum.
    public mutating func apply(_ post: PiBotForumPost, roomID: Int) {
        if post.roomId == roomID {
            posts = Self.merge(posts, [post])
        } else if post.id == parent?.id {
            parent = post
        }
    }

    public mutating func apply(thinking botIDs: [String]) { thinking = botIDs }

    /// An older page, from `forum.posts`.
    public mutating func prepend(_ earlier: [PiBotForumPost], hasEarlier: Bool) {
        posts = Self.merge(posts, earlier)
        self.hasEarlier = hasEarlier
    }

    /// The state after an open: the snapshot, then what was pushed while it was on the way.
    public static func opened(snapshot: PiBotForumRoomSnapshot, posts pushed: [PiBotForumPost] = [],
                              thinking: [String]? = nil) -> PiBotForumRoomState {
        var next = PiBotForumRoomState()
        next.posts = merge([], snapshot.posts)
        next.parent = snapshot.parent
        next.hasEarlier = snapshot.hasEarlier ?? false
        next.thinking = thinking ?? snapshot.thinking ?? []
        for post in pushed { next.apply(post, roomID: snapshot.roomId) }
        return next
    }

    /// "Ada is thinking…", "Ada and Max are thinking…", "Ada, Max and 2 others are thinking…".
    public static func thinkingText(_ names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: "\(names[0]) is thinking…"
        case 2, 3: "\(PiBotForumMentions.list(names)) are thinking…"
        default: "\(names[0]), \(names[1]) and \(names.count - 2) others are thinking…"
        }
    }
}

// MARK: - Mentions

/// Who a draft asks to reply. Only the user mentions; `@Name` picks a bot by its name and
/// `@everyone` the whole room.
public struct PiBotForumMentions: Equatable, Sendable {
    public struct Candidate: Equatable, Sendable {
        public let id: String
        public let name: String
        /// In the Forum. A bot that is out neither hears a post nor answers a mention.
        public let active: Bool
        /// Already hears this room. In a thread, mentioning an active bot adds it.
        public let member: Bool
        public init(id: String, name: String, active: Bool = true, member: Bool = true) {
            self.id = id; self.name = name; self.active = active; self.member = member
        }
    }

    /// Bots in the Forum that the draft mentions, in the order they first appear.
    public var botIDs: [String] = []
    public var everyone = false
    /// Names of mentioned bots that are out of the Forum.
    public var outNames: [String] = []
    /// Names of mentioned bots a thread will add.
    public var addedNames: [String] = []
    /// Names of the bots asked to reply, without `everyone`.
    public var names: [String] = []

    public var isEmpty: Bool { botIDs.isEmpty && !everyone && outNames.isEmpty }

    public static let everyoneKeyword = "everyone"

    /// Finds `@<name>` in `text`: case-insensitive, the longest name wins ("Ada Two" before
    /// "Ada"), and the name has to end at a word boundary. An `@` inside a word (an email
    /// address) is not a mention.
    public static func resolve(_ text: String, candidates: [Candidate]) -> PiBotForumMentions {
        var result = PiBotForumMentions()
        // Longest first, and otherwise in the order given, whatever the sort does with ties.
        let named = candidates.enumerated().filter { !$0.element.name.isEmpty }
            .sorted { ($1.element.name.count, $0.offset) < ($0.element.name.count, $1.offset) }
            .map(\.element)
        var seen = Set<String>()
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            index = text.index(after: at)
            if at > text.startIndex, isWordCharacter(text[text.index(before: at)]) { continue }
            let rest = text[index...]
            let match = named.first { ends(rest, after: $0.name) }
            let isEveryone = ends(rest, after: everyoneKeyword)
            // A bot whose own name starts with "everyone" keeps its mention.
            if isEveryone, (match?.name.count ?? 0) < everyoneKeyword.count {
                result.everyone = true
                continue
            }
            guard let match else { continue }
            // Two bots may share a name: the mention reaches both.
            for bot in named where bot.name.compare(match.name, options: .caseInsensitive) == .orderedSame {
                guard seen.insert(bot.id).inserted else { continue }
                if !bot.active {
                    result.outNames.append(bot.name)
                } else {
                    result.botIDs.append(bot.id)
                    result.names.append(bot.name)
                    if !bot.member { result.addedNames.append(bot.name) }
                }
            }
        }
        return result
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Whether `rest` starts with `name` and the name ends there.
    private static func ends(_ rest: Substring, after name: String) -> Bool {
        guard let range = rest.range(of: name, options: [.caseInsensitive, .anchored]) else { return false }
        return range.upperBound == rest.endIndex || !isWordCharacter(rest[range.upperBound])
    }

    /// "Ada", "Ada and Max", "Ada, Max and Lee".
    public static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// What the composer says about a draft's mentions, or nil when it has none.
    public var note: String? {
        var parts: [String] = []
        if everyone {
            parts.append("Will ask every bot here to reply.")
        } else if !names.isEmpty {
            parts.append("Will ask \(Self.list(names)) to reply.")
        }
        if !addedNames.isEmpty {
            parts.append("\(Self.list(addedNames)) will join this thread.")
        }
        if !outNames.isEmpty {
            let verb = outNames.count == 1 ? "is" : "are"
            parts.append("\(Self.list(outNames)) \(verb) out of the Forum and won't see this.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Scheduled posts

/// A post the runtime makes as the user at a set time, once or repeating.
public struct PiBotForumSchedule: Codable, Equatable, Identifiable, Sendable {
    public enum Repeat: String, CaseIterable, Sendable {
        case once, daily, weekdays, weekly
        public var title: String {
            switch self {
            case .once: "Once"
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekly: "Every week"
            }
        }
    }

    public let id: String
    public let text: String
    public let mentions: [String]?
    public let everyone: Bool?
    /// "once", "daily", "weekdays" or "weekly".
    public let `repeat`: String
    /// "HH:MM" on the 24-hour clock in `timeZone`, for a repeating post.
    public let time: String?
    /// 0 (Sunday) to 6 (Saturday), for a weekly post.
    public let weekday: Int?
    /// Epoch milliseconds, for a one-time post.
    public let at: Double?
    public let timeZone: String
    /// Epoch milliseconds of the next post, when the runtime knows it.
    public let nextAt: Double?

    public init(id: String, text: String, mentions: [String]? = nil, everyone: Bool? = nil, repeat: String,
                time: String? = nil, weekday: Int? = nil, at: Double? = nil, timeZone: String, nextAt: Double? = nil) {
        self.id = id; self.text = text; self.mentions = mentions; self.everyone = everyone; self.repeat = `repeat`
        self.time = time; self.weekday = weekday; self.at = at; self.timeZone = timeZone; self.nextAt = nextAt
    }

    /// "Every day at 9:00 AM", "Mondays at 9:00 AM", "Jun 3 at 9:00 AM".
    public func whenText(locale: Locale = .current, displayTimeZone: TimeZone = .current) -> String {
        let zone = TimeZone(identifier: timeZone) ?? displayTimeZone
        let clock = time.flatMap { Self.clockText($0, locale: locale) }
        // Another time zone's clock is named, so "9:00 AM" is never read as local.
        let suffix = zone.identifier == displayTimeZone.identifier ? "" : " (\(zone.identifier))"
        switch Repeat(rawValue: `repeat`) {
        case .daily: return "Every day" + (clock.map { " at \($0)" } ?? "") + suffix
        case .weekdays: return "Weekdays" + (clock.map { " at \($0)" } ?? "") + suffix
        case .weekly:
            let day = weekday.flatMap { Self.weekdayName($0, locale: locale) }.map { $0 + "s" } ?? "Every week"
            return day + (clock.map { " at \($0)" } ?? "") + suffix
        case .once, nil:
            guard let at else { return "Once" }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = displayTimeZone
            formatter.setLocalizedDateFormatFromTemplate("MMM d jm")
            return formatter.string(from: Date(timeIntervalSince1970: at / 1000))
        }
    }

    public static func weekdayName(_ weekday: Int, locale: Locale = .current) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        // `weekdaySymbols` starts on Sunday, as the wire's 0 does.
        return calendar.weekdaySymbols.indices.contains(weekday) ? calendar.weekdaySymbols[weekday] : nil
    }

    static func clockText(_ time: String, locale: Locale) -> String? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: parts[0], minute: parts[1])) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: date)
    }
}

/// A scheduled post on its way to `forum.schedules.save`.
public struct PiBotForumScheduleDraft: Equatable, Sendable {
    /// Set to change a saved one; nil adds one.
    public var id: String?
    public var text = ""
    public var mentions: [String] = []
    public var everyone = false
    public var `repeat` = PiBotForumSchedule.Repeat.daily
    /// The time of day for a repeating post, and the whole moment for a one-time post.
    public var date: Date
    /// 0 (Sunday) to 6 (Saturday).
    public var weekday: Int
    public var timeZone: TimeZone

    public init(date: Date = Date(), timeZone: TimeZone = .current) {
        self.date = date
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        weekday = calendar.component(.weekday, from: date) - 1
    }

    public var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (`repeat` != .once || date.timeIntervalSinceNow > 0)
    }

    public var wire: JSONValue {
        var fields: [String: JSONValue] = [
            "text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            "repeat": .string(`repeat`.rawValue),
            "timeZone": .string(timeZone.identifier),
        ]
        if let id { fields["id"] = .string(id) }
        if everyone { fields["everyone"] = .bool(true) }
        else if !mentions.isEmpty { fields["mentions"] = .array(mentions.map(JSONValue.string)) }
        if `repeat` == .once {
            fields["at"] = .number((date.timeIntervalSince1970 * 1000).rounded())
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            fields["time"] = .string(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))
            if `repeat` == .weekly { fields["weekday"] = .number(Double(weekday)) }
        }
        return .object(fields)
    }
}
