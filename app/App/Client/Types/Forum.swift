import Foundation

// The Forum: one group chat with the user and every bot, and threads, on the bots' home machine.

struct PiBotForumPost: Equatable, Identifiable, Sendable {
    /// A Forum post's thread: its room and how many posts it holds.
    struct ThreadLink: Equatable, Sendable {
        let roomId: Int
        let replies: Int
    }

    /// A mentioned bot that had nothing to post, and why.
    struct Unanswered: Equatable, Identifiable, Sendable {
        let botId: String
        let name: String
        let reason: String
        let issue: BotReplyIssue?
        var id: String { botId }
        var needsSignIn: Bool { issue == .signIn }
        var hitLimit: Bool { issue == .limit }
    }

    /// Numbered across every room; never changes.
    let id: Int
    let roomId: Int
    let isUser: Bool
    /// The author's name when it posted, so a deleted bot's posts keep theirs.
    let name: String
    let text: String
    let isScheduled: Bool
    let thread: ThreadLink?
    let unanswered: [Unanswered]
    /// A visual reply the bot published here with `render_html`, shown in place of text.
    var visualReply: ConversationHTMLRenderReference?
}

struct PiBotForumThread: Equatable, Identifiable, Sendable {
    let roomId: Int
    /// Generated from the thread's first post; absent until then.
    let title: String?
    /// The start of the thread's first post.
    let preview: String?
    let createdAt: Date
    let isPinned: Bool
    /// The bots that hear this thread.
    let botIds: [String]

    var id: Int { roomId }
    var hasTitle: Bool { title?.isEmpty == false }

    /// The title, else how the thread starts, else a placeholder.
    var label: String {
        if let title, !title.isEmpty { return title }
        let start = (preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return start.isEmpty ? "New thread" : start
    }

    /// Pins first, then newest created, like a bot's threads.
    static func sorted(_ threads: [PiBotForumThread]) -> [PiBotForumThread] {
        threads.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.roomId > rhs.roomId
        }
    }
}

/// What every Forum view shares.
struct PiBotForumState: Equatable, Sendable {
    struct Member: Equatable, Identifiable, Sendable {
        let botId: String
        /// In the Forum: it hears posts and may post.
        let active: Bool
        var id: String { botId }
    }

    let paused: Bool
    /// Every live bot, in or out.
    let bots: [Member]
    let threads: [PiBotForumThread]

    var activeBotIDs: Set<String> { Set(bots.filter(\.active).map(\.botId)) }
    func isActive(_ botID: String) -> Bool { bots.contains { $0.botId == botID && $0.active } }
    func thread(roomID: Int) -> PiBotForumThread? { threads.first { $0.roomId == roomID } }
}

/// What one open room shows.
struct PiBotForumRoomState: Equatable, Sendable {
    /// Oldest first.
    var posts: [PiBotForumPost] = []
    /// A thread's starting post.
    var parent: PiBotForumPost?
    /// Bots with a turn running in this room.
    var thinking: [String] = []
    /// The room holds posts older than the oldest one here.
    var hasEarlier = false

    /// "Ada is thinking…", "Ada and Max are thinking…", "Ada, Max and 2 others are thinking…".
    static func thinkingText(_ names: [String]) -> String? {
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
struct PiBotForumMentions: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let id: String
        let name: String
        /// In the Forum. A bot that is out neither hears a post nor answers a mention.
        let active: Bool
        /// Already hears this room. In a thread, mentioning an active bot adds it.
        let member: Bool
        init(id: String, name: String, active: Bool = true, member: Bool = true) {
            self.id = id; self.name = name; self.active = active; self.member = member
        }
    }

    /// Bots in the Forum that the draft mentions, in the order they first appear.
    var botIDs: [String] = []
    var everyone = false
    /// Names of mentioned bots that are out of the Forum.
    var outNames: [String] = []
    /// Names of mentioned bots a thread will add.
    var addedNames: [String] = []
    /// Names of the bots asked to reply, without `everyone`.
    var names: [String] = []

    var isEmpty: Bool { botIDs.isEmpty && !everyone && outNames.isEmpty }

    static let everyoneKeyword = "everyone"

    /// Finds `@<name>` in `text`: case-insensitive, the longest name wins ("Ada Two" before
    /// "Ada"), and the name has to end at a word boundary. An `@` inside a word (an email
    /// address) is not a mention.
    static func resolve(_ text: String, candidates: [Candidate]) -> PiBotForumMentions {
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
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// What the composer says about a draft's mentions, or nil when it has none.
    var note: String? {
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

/// A post made to the Forum as the user at a set time, once or repeating.
struct PiBotForumSchedule: Equatable, Identifiable, Sendable {
    enum Repeat: String, CaseIterable, Sendable {
        case once, daily, weekdays, weekly
        var title: String {
            switch self {
            case .once: "Once"
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekly: "Every week"
            }
        }
    }

    let id: String
    let text: String
    let `repeat`: Repeat
    /// Hour and minute on the 24-hour clock in `timeZone`, for a repeating post.
    let time: (hour: Int, minute: Int)?
    /// 0 (Sunday) to 6 (Saturday), for a weekly post.
    let weekday: Int?
    /// When a one-time post goes out.
    let at: Date?
    let timeZone: TimeZone

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.repeat == rhs.repeat && lhs.time?.hour == rhs.time?.hour
            && lhs.time?.minute == rhs.time?.minute && lhs.weekday == rhs.weekday && lhs.at == rhs.at
            && lhs.timeZone == rhs.timeZone
    }

    /// "Every day at 9:00 AM", "Mondays at 9:00 AM", "Jun 3 at 9:00 AM".
    func whenText(locale: Locale = .current, displayTimeZone: TimeZone = .current) -> String {
        let clock = time.flatMap { Self.clockText(hour: $0.hour, minute: $0.minute, locale: locale) }
        // Another time zone's clock is named, so "9:00 AM" is never read as local.
        let suffix = timeZone.identifier == displayTimeZone.identifier ? "" : " (\(timeZone.identifier))"
        switch `repeat` {
        case .daily: return "Every day" + (clock.map { " at \($0)" } ?? "") + suffix
        case .weekdays: return "Weekdays" + (clock.map { " at \($0)" } ?? "") + suffix
        case .weekly:
            let day = weekday.flatMap { Self.weekdayName($0, locale: locale) }.map { $0 + "s" } ?? "Every week"
            return day + (clock.map { " at \($0)" } ?? "") + suffix
        case .once:
            guard let at else { return "Once" }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = displayTimeZone
            formatter.setLocalizedDateFormatFromTemplate("MMM d jm")
            return formatter.string(from: at)
        }
    }

    static func weekdayName(_ weekday: Int, locale: Locale = .current) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        // `weekdaySymbols` starts on Sunday, as 0 does.
        return calendar.weekdaySymbols.indices.contains(weekday) ? calendar.weekdaySymbols[weekday] : nil
    }

    static func clockText(hour: Int, minute: Int, locale: Locale) -> String? {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: date)
    }
}

/// A scheduled post being written.
struct PiBotForumScheduleDraft: Equatable, Sendable {
    var text = ""
    var mentions: [String] = []
    var everyone = false
    var `repeat` = PiBotForumSchedule.Repeat.daily
    /// The time of day for a repeating post, and the whole moment for a one-time post.
    var date: Date
    /// 0 (Sunday) to 6 (Saturday).
    var weekday: Int
    var timeZone: TimeZone

    init(date: Date = Date(), timeZone: TimeZone = .current) {
        self.date = date
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        weekday = calendar.component(.weekday, from: date) - 1
    }

    var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (`repeat` != .once || date.timeIntervalSinceNow > 0)
    }
}
