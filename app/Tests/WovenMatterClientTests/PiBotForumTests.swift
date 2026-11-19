import Foundation
import Testing
@testable import WovenMatterClient

private func decoded<T: Decodable>(_ text: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(text.utf8))
}

private func post(_ id: Int, room: Int = 1, author: String = "bot", name: String = "Ada", text: String = "x",
                  thread: PiBotForumPost.ThreadLink? = nil) -> PiBotForumPost {
    PiBotForumPost(id: id, roomId: room, author: author, name: name, text: text, thread: thread)
}

@Suite("Forum wire shapes")
struct PiBotForumWireTests {
    @Test func aPostWithEveryFieldDecodes() throws {
        let post: PiBotForumPost = try decoded(#"""
        {"id":41,"roomId":1,"author":"user","name":"Trey","text":"@Ada and @Max: status?","mentions":["a","m"],
         "scheduled":true,"createdAt":"2026-11-19T09:00:00.000Z","thread":{"roomId":7,"replies":3},
         "unanswered":[{"botId":"m","name":"Max","reason":"Not logged in to Claude.","issue":"signIn"},
                       {"botId":"a","name":"Ada","reason":"its reply was stopped"}],
         "futureField":{"anything":1}}
        """#)
        #expect(post.id == 41 && post.roomId == 1)
        #expect(post.isUser && post.isScheduled)
        #expect(post.mentions == ["a", "m"])
        #expect(post.thread == .init(roomId: 7, replies: 3))
        #expect(post.unanswered?.map(\.name) == ["Max", "Ada"])
        #expect(post.unanswered?.first?.needsSignIn == true)
        #expect(post.unanswered?.last?.needsSignIn == false && post.unanswered?.last?.hitLimit == false)
    }

    @Test func aPostWithOnlyTheRequiredFieldsDecodes() throws {
        let post: PiBotForumPost = try decoded(#"{"id":2,"roomId":3,"author":"bot","botId":"a","name":"Ada","text":"hello","createdAt":"2026-11-19T09:00:01.000Z"}"#)
        #expect(!post.isUser && !post.isScheduled)
        #expect(post.botId == "a" && post.auto == nil && post.thread == nil && post.unanswered == nil && post.mentions == nil)
        let auto: PiBotForumPost = try decoded(#"{"id":3,"roomId":1,"author":"bot","botId":"a","name":"Ada","text":"ok","auto":true,"createdAt":""}"#)
        #expect(auto.auto == true)
    }

    @Test func theForumStateDecodesAndAnswersWhoIsIn() throws {
        let state: PiBotForumState = try decoded(#"""
        {"mainRoomId":1,"paused":true,"latestPostId":9,
         "bots":[{"botId":"a","active":true},{"botId":"admin","active":false}],
         "threads":[{"roomId":4,"parentPostId":2,"preview":"What about tests?","createdAt":"2026-11-19T10:00:00Z","replies":2,"botIds":["a"]},
                    {"roomId":5,"parentPostId":3,"title":"Release plan","preview":"p","createdAt":"2026-11-18T10:00:00Z","pinned":true,"replies":0,"botIds":[]}]}
        """#)
        #expect(state.paused && state.mainRoomId == 1 && state.latestPostId == 9)
        #expect(state.activeBotIDs == ["a"])
        #expect(state.isActive("a") && !state.isActive("admin") && !state.isActive("gone"))
        #expect(state.thread(roomID: 4)?.botIds == ["a"])
        #expect(state.thread(roomID: 99) == nil)
    }

    @Test func aRoomSnapshotDecodesWithAndWithoutAParent() throws {
        let forum: PiBotForumRoomSnapshot = try decoded(#"{"subscriptionId":12,"roomId":1,"mainRoomId":1,"posts":[],"hasEarlier":false,"thinking":[]}"#)
        #expect(forum.parent == nil && forum.posts.isEmpty && forum.subscriptionId == .number(12))
        let thread: PiBotForumRoomSnapshot = try decoded(#"""
        {"subscriptionId":"s","roomId":4,"mainRoomId":1,"hasEarlier":true,"thinking":["a"],
         "parent":{"id":2,"roomId":1,"author":"bot","botId":"a","name":"Ada","text":"idea","createdAt":""},
         "posts":[{"id":6,"roomId":4,"author":"user","name":"Trey","text":"go on","createdAt":""}]}
        """#)
        #expect(thread.parent?.id == 2 && thread.posts.map(\.id) == [6] && thread.hasEarlier == true && thread.thinking == ["a"])
    }

    @Test func aThreadIsNamedByItsTitleThenItsFirstPost() {
        #expect(PiBotForumThread(roomId: 1, parentPostId: 1, title: "Release plan", preview: "p").label == "Release plan")
        #expect(PiBotForumThread(roomId: 1, parentPostId: 1, title: "", preview: " What about tests? ").label == "What about tests?")
        #expect(PiBotForumThread(roomId: 1, parentPostId: 1, preview: "").label == "New thread")
        #expect(PiBotForumThread(roomId: 1, parentPostId: 1).label == "New thread")
        #expect(PiBotForumThread(roomId: 1, parentPostId: 1, title: "T").hasTitle)
        #expect(!PiBotForumThread(roomId: 1, parentPostId: 1, preview: "p").hasTitle)
    }

    @Test func threadsSortPinnedFirstThenNewest() {
        let threads = [
            PiBotForumThread(roomId: 2, parentPostId: 1, createdAt: "2026-11-01T00:00:00Z"),
            PiBotForumThread(roomId: 3, parentPostId: 1, createdAt: "2026-11-03T00:00:00Z"),
            PiBotForumThread(roomId: 4, parentPostId: 1, createdAt: "2026-10-01T00:00:00Z", pinned: true),
            PiBotForumThread(roomId: 5, parentPostId: 1, createdAt: "2026-11-03T00:00:00Z"),
        ]
        #expect(PiBotForumThread.sorted(threads).map(\.roomId) == [4, 5, 3, 2])
    }
}

@Suite("Forum room state")
struct PiBotForumRoomStateTests {
    @Test func postsMergeByIdInPostOrder() {
        var state = PiBotForumRoomState()
        state.apply(post(5), roomID: 1)
        state.apply(post(3), roomID: 1)
        state.apply(post(5, text: "changed", thread: .init(roomId: 9, replies: 1)), roomID: 1)
        #expect(state.posts.map(\.id) == [3, 5])
        #expect(state.posts.last?.text == "changed" && state.posts.last?.thread?.replies == 1)
    }

    @Test func aRoomIgnoresOtherRoomsButFollowsItsStartingPost() {
        var state = PiBotForumRoomState()
        state.parent = post(2, room: 1, text: "idea")
        state.apply(post(7, room: 1), roomID: 4)
        #expect(state.posts.isEmpty)
        state.apply(post(2, room: 1, text: "idea", thread: .init(roomId: 4, replies: 2)), roomID: 4)
        #expect(state.parent?.thread?.replies == 2)
        state.apply(post(8, room: 4), roomID: 4)
        #expect(state.posts.map(\.id) == [8])
    }

    @Test func anOpenTakesTheSnapshotThenWhatWasPushedMeanwhile() {
        let snapshot = PiBotForumRoomSnapshot(roomId: 1, mainRoomId: 1, posts: [post(1), post(2)], hasEarlier: true, thinking: ["a"])
        let state = PiBotForumRoomState.opened(snapshot: snapshot, posts: [post(2, text: "newer"), post(3), post(9, room: 4)], thinking: ["m"])
        #expect(state.posts.map(\.id) == [1, 2, 3])
        #expect(state.posts[1].text == "newer")
        #expect(state.hasEarlier && state.thinking == ["m"])
        #expect(PiBotForumRoomState.opened(snapshot: snapshot).thinking == ["a"])
    }

    @Test func anEarlierPageGoesInFront() {
        var state = PiBotForumRoomState.opened(snapshot: .init(roomId: 1, mainRoomId: 1, posts: [post(10), post(11)], hasEarlier: true))
        state.prepend([post(8), post(9), post(10)], hasEarlier: false)
        #expect(state.posts.map(\.id) == [8, 9, 10, 11])
        #expect(!state.hasEarlier)
    }

    @Test func whoIsThinkingReadsAsASentence() {
        #expect(PiBotForumRoomState.thinkingText([]) == nil)
        #expect(PiBotForumRoomState.thinkingText(["Ada"]) == "Ada is thinking…")
        #expect(PiBotForumRoomState.thinkingText(["Ada", "Max"]) == "Ada and Max are thinking…")
        #expect(PiBotForumRoomState.thinkingText(["Ada", "Max", "Lee"]) == "Ada, Max and Lee are thinking…")
        #expect(PiBotForumRoomState.thinkingText(["Ada", "Max", "Lee", "Kim"]) == "Ada, Max and 2 others are thinking…")
    }
}

@Suite("Forum mentions")
struct PiBotForumMentionsTests {
    private let bots: [PiBotForumMentions.Candidate] = [
        .init(id: "a", name: "Ada"),
        .init(id: "a2", name: "Ada Two"),
        .init(id: "m", name: "Max"),
        .init(id: "r", name: "Research Bot"),
        .init(id: "admin", name: "Admin Bot", active: false),
    ]

    private func resolve(_ text: String, _ candidates: [PiBotForumMentions.Candidate]? = nil) -> PiBotForumMentions {
        PiBotForumMentions.resolve(text, candidates: candidates ?? bots)
    }

    @Test func aNameIsFoundWhateverItsCase() {
        #expect(resolve("@ada what do you think?").botIDs == ["a"])
        #expect(resolve("thoughts, @MAX?").botIDs == ["m"])
        #expect(resolve("no mention here").isEmpty)
    }

    @Test func theLongestNameWins() {
        #expect(resolve("@Ada Two, your turn").botIDs == ["a2"])
        #expect(resolve("@Ada, two things").botIDs == ["a"])
        #expect(resolve("@Ada Twofold").botIDs == ["a"])
    }

    @Test func aNameEndsAtAWordBoundary() {
        #expect(resolve("@Adam is not here").isEmpty)
        #expect(resolve("@Ada's idea, @Max.").botIDs == ["a", "m"])
        #expect(resolve("(@Max)").botIDs == ["m"])
        #expect(resolve("@Max").botIDs == ["m"])
        #expect(resolve("@Max_2").isEmpty)
    }

    @Test func anAtSignInsideAWordIsNotAMention() {
        #expect(resolve("mail trey@max.example").isEmpty)
        #expect(resolve("a@Ada").isEmpty)
        #expect(resolve("@ Ada").isEmpty)
    }

    @Test func namesWithSpacesAndRepeatsResolveOnce() {
        let found = resolve("@Research Bot please, and @research bot again, then @Ada")
        #expect(found.botIDs == ["r", "a"])
        #expect(found.names == ["Research Bot", "Ada"])
    }

    @Test func everyoneAsksTheWholeRoom() {
        let found = resolve("@everyone good morning")
        #expect(found.everyone && found.botIDs.isEmpty)
        #expect(resolve("@Everyone, and @Ada").everyone)
        #expect(resolve("@Everyone, and @Ada").botIDs == ["a"])
        #expect(!resolve("@everyoneelse").everyone)
        // A bot that is really called that keeps its name.
        let named = resolve("@everyone hi", bots + [.init(id: "e", name: "Everyone")])
        #expect(!named.everyone && named.botIDs == ["e"])
    }

    @Test func aBotOutOfTheForumIsNamedNotMentioned() {
        let found = resolve("@Admin Bot and @Ada")
        #expect(found.botIDs == ["a"])
        #expect(found.outNames == ["Admin Bot"])
        #expect(found.note == "Will ask Ada to reply. Admin Bot is out of the Forum and won't see this.")
        #expect(!resolve("@Admin Bot").isEmpty)
    }

    @Test func aThreadSaysWhoItWillAdd() {
        let thread: [PiBotForumMentions.Candidate] = [
            .init(id: "a", name: "Ada"), .init(id: "m", name: "Max", member: false), .init(id: "l", name: "Lee", member: false),
        ]
        let found = resolve("@Ada @Max @Lee", thread)
        #expect(found.botIDs == ["a", "m", "l"])
        #expect(found.addedNames == ["Max", "Lee"])
        #expect(found.note == "Will ask Ada, Max and Lee to reply. Max and Lee will join this thread.")
    }

    @Test func twoBotsWithOneNameAreBothAsked() {
        let found = resolve("@Ada", [.init(id: "1", name: "Ada"), .init(id: "2", name: "ada")])
        #expect(found.botIDs == ["1", "2"])
    }

    @Test func theNoteSaysWhatTheDraftWillDo() {
        #expect(resolve("hello").note == nil)
        #expect(resolve("@Max hi").note == "Will ask Max to reply.")
        #expect(resolve("@everyone hi").note == "Will ask every bot here to reply.")
        #expect(PiBotForumMentions.list([]) == "")
        #expect(PiBotForumMentions.list(["Ada", "Max"]) == "Ada and Max")
    }
}

@Suite("Forum scheduled posts")
struct PiBotForumScheduleTests {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let us = Locale(identifier: "en_US")

    /// 2026-11-19 14:30 in New York (a Thursday), which is 19:30 UTC.
    private var afternoon: Date { Date(timeIntervalSince1970: 1_795_116_600) }

    @Test func aScheduleDecodes() throws {
        let schedules: [PiBotForumSchedule] = try decoded(#"""
        [{"id":"s1","text":"Morning, @everyone","everyone":true,"repeat":"weekdays","time":"09:00","timeZone":"America/New_York","nextAt":1795270000000},
         {"id":"s2","text":"Once","mentions":["a"],"repeat":"once","at":1795116600000,"timeZone":"UTC"}]
        """#)
        #expect(schedules.map(\.id) == ["s1", "s2"])
        #expect(schedules[0].everyone == true && schedules[0].time == "09:00" && schedules[0].at == nil)
        #expect(schedules[1].mentions == ["a"] && schedules[1].at == 1_795_116_600_000)
    }

    @Test func aRepeatingDraftSendsItsClockTimeInItsZone() {
        var draft = PiBotForumScheduleDraft(date: afternoon, timeZone: newYork)
        draft.text = "  Stand-up  "
        draft.repeat = .weekly
        #expect(draft.weekday == 4)
        #expect(draft.wire == .object([
            "text": .string("Stand-up"), "repeat": .string("weekly"), "timeZone": .string("America/New_York"),
            "time": .string("14:30"), "weekday": .number(4),
        ]))
        draft.repeat = .daily
        draft.everyone = true
        #expect(draft.wire.objectValue?["weekday"] == nil)
        #expect(draft.wire.objectValue?["everyone"] == .bool(true))
        #expect(draft.wire.objectValue?["at"] == nil)
    }

    @Test func aOneTimeDraftSendsTheMoment() {
        var draft = PiBotForumScheduleDraft(date: afternoon, timeZone: newYork)
        draft.text = "Ship it"
        draft.repeat = .once
        draft.mentions = ["a"]
        draft.id = "s9"
        #expect(draft.wire == .object([
            "id": .string("s9"), "text": .string("Ship it"), "repeat": .string("once"), "timeZone": .string("America/New_York"),
            "at": .number(1_795_116_600_000), "mentions": .array([.string("a")]),
        ]))
    }

    @Test func aDraftNeedsTextAndAFutureMomentWhenItRunsOnce() {
        var draft = PiBotForumScheduleDraft(date: Date().addingTimeInterval(3_600))
        #expect(!draft.canSave)
        draft.text = "x"
        #expect(draft.canSave)
        draft.repeat = .once
        #expect(draft.canSave)
        draft.date = Date().addingTimeInterval(-60)
        #expect(!draft.canSave)
        draft.repeat = .daily
        #expect(draft.canSave)
    }

    @Test func aScheduleSaysWhenItPosts() {
        func schedule(_ `repeat`: String, time: String? = "09:00", weekday: Int? = nil, at: Double? = nil,
                      zone: String = "America/New_York") -> PiBotForumSchedule {
            PiBotForumSchedule(id: "s", text: "t", repeat: `repeat`, time: time, weekday: weekday, at: at, timeZone: zone)
        }
        // The system puts a narrow no-break space before AM and PM.
        func when(_ schedule: PiBotForumSchedule) -> String {
            schedule.whenText(locale: us, displayTimeZone: newYork).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        #expect(when(schedule("daily")) == "Every day at 9:00 AM")
        #expect(when(schedule("weekdays", time: "17:05")) == "Weekdays at 5:05 PM")
        #expect(when(schedule("weekly", weekday: 1)) == "Mondays at 9:00 AM")
        #expect(when(schedule("weekly", weekday: 0)) == "Sundays at 9:00 AM")
        // A clock in another zone is named, so it is never read as local time.
        #expect(when(schedule("daily", zone: "Europe/Berlin")) == "Every day at 9:00 AM (Europe/Berlin)")
        let once = when(schedule("once", time: nil, at: 1_795_116_600_000))
        #expect(once.contains("Nov 19") && once.contains("2:30"))
    }
}
