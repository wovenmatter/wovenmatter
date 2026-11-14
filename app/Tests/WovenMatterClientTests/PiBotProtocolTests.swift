import Foundation
import Testing
@testable import WovenMatterClient

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func decoded<T: Decodable>(_ text: String, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(text.utf8))
}

@Suite("Pi Bot conversation state")
struct PiBotConversationStateTests {
    private func entry(_ id: Int, role: String = "assistant", text: String = "x", conversation: Int = 1) -> PiBotDisplayEntry {
        PiBotDisplayEntry(id: id, conversationId: conversation, role: role, text: text)
    }

    @Test func streamEventsParseFromTheWire() {
        #expect(PiBotStreamEvent(json: json(#"{"kind":"run","state":"start"}"#)) == .run(started: true))
        #expect(PiBotStreamEvent(json: json(#"{"kind":"run","state":"end"}"#)) == .run(started: false))
        #expect(PiBotStreamEvent(json: json(#"{"kind":"assistant_start","text":"a"}"#)) == .assistantStart("a"))
        #expect(PiBotStreamEvent(json: json(#"{"kind":"delta","text":"b"}"#)) == .delta("b"))
        #expect(PiBotStreamEvent(json: json(#"{"kind":"error","message":"no"}"#)) == .error("no"))
        #expect(PiBotStreamEvent(json: json(#"{"kind":"entry","entry":{"id":4,"conversationId":2,"role":"user","text":"t","stopped":true}}"#))
            == .entry(PiBotDisplayEntry(id: 4, conversationId: 2, role: "user", text: "t", stopped: true)))
        #expect(PiBotStreamEvent(json: json(#"{"kind":"future"}"#)) == nil)
    }

    @Test func aFailedReplyCarriesItsFix() {
        let event = PiBotStreamEvent(json: json(#"{"kind":"entry","entry":{"id":5,"conversationId":1,"role":"assistant","text":"","error":"Not logged in to Claude.","issue":"signIn"}}"#))
        guard case .entry(let entry) = event else { Issue.record("not an entry"); return }
        #expect(entry.needsSignIn)
        #expect(!entry.hitLimit)
        #expect(!self.entry(6).needsSignIn)
    }

    @Test func aFinalEntryReplacesTheStreamAndARunEndClearsIt() {
        var state = PiBotConversationState()
        state.apply(.run(started: true))
        state.apply(.assistantStart("Hel"))
        state.apply(.delta("lo"))
        #expect(state.streaming == "Hello")
        state.apply(.entry(entry(1, text: "Hello")))
        #expect(state.streaming == nil)
        #expect(state.running)
        state.apply(.delta("more"))
        state.apply(.run(started: false))
        #expect(state.streaming == nil)
        #expect(!state.running)
    }

    @Test func aUserEntryRemovesOnlyItsOwnPendingMessage() {
        var state = PiBotConversationState()
        state.pending = [.init(id: 1, text: "a"), .init(id: 2, text: "a"), .init(id: 3, text: "b")]
        state.apply(.entry(entry(9, role: "user", text: "a")))
        #expect(state.pending.map(\.id) == [2, 3])
        state.apply(.entry(entry(10, role: "assistant", text: "b")))
        #expect(state.pending.map(\.id) == [2, 3])
    }

    @Test func mergingReplacesByIDAndKeepsFirstSeenOrder() {
        let merged = PiBotConversationState.merge([entry(1, text: "old"), entry(2)], [entry(3), entry(1, text: "new")])
        #expect(merged.map(\.id) == [1, 2, 3])
        #expect(merged[0].text == "new")
    }

    @Test func aSnapshotDoesNotUndoWhatTheStreamAlreadyShowed() {
        var state = PiBotConversationState()
        state.apply(.run(started: true))
        state.apply(.assistantStart("live"))
        state.apply(.entry(entry(5, text: "newer")))
        state.apply(.assistantStart("live"))
        state.apply(snapshot: PiBotConversationSnapshot(botId: "b", conversationId: 1, mainConversationId: 1,
            entries: [entry(4)], running: false, streaming: "stale"))
        #expect(state.entries.map(\.id) == [4, 5])
        #expect(state.running)
        #expect(state.streaming == "live")
    }

    @Test func eventsAfterASnapshotContinueIt() {
        let snapshot = PiBotConversationSnapshot(botId: "b", conversationId: 1, mainConversationId: 1,
            entries: [entry(1)], running: true, streaming: "Hel")
        let streaming = PiBotConversationState.opened(snapshot: snapshot, events: [.delta("lo")])
        #expect(streaming.streaming == "Hello")
        #expect(streaming.running)

        let finished = PiBotConversationState.opened(snapshot: snapshot, events: [
            .delta("lo"), .entry(entry(2, text: "Hello")), .run(started: false),
        ])
        #expect(finished.entries.map(\.id) == [1, 2])
        #expect(finished.streaming == nil)
        #expect(!finished.running)
    }

    @Test func openingKeepsNothingFromBefore() {
        let snapshot = PiBotConversationSnapshot(botId: "b", conversationId: 1, mainConversationId: 1,
            entries: [entry(3)], running: false)
        let next = PiBotConversationState.opened(snapshot: snapshot)
        #expect(next.entries.map(\.id) == [3])
        #expect(!next.running)
        #expect(next.streaming == nil)
        #expect(next.pending.isEmpty)
    }

    @Test func snapshotsDecodeFromTheWire() throws {
        let snapshot: PiBotConversationSnapshot = try decoded(#"""
        {"subscriptionId":3,"botId":"b","conversationId":7,"mainConversationId":1,
         "threadOrigin":{"id":2,"conversationId":1,"role":"assistant","text":"o"},
         "entries":[],"running":true,"streaming":"s","added":{"later":true}}
        """#)
        #expect(snapshot.subscriptionId == .number(3))
        #expect(snapshot.threadOrigin?.id == 2)
        #expect(snapshot.running)
    }
}

@Suite("Pi Bot models and profiles")
struct PiBotModelFactsTests {
    @Test func modelsSortNewestFirst() {
        let ids = ["gpt-5.6-luna", "gpt-6.1-terra", "gpt-6-sol", "gpt-6.1-sol", "claude-opus-4-5", "claude-opus-5-5", "chat-latest"]
        let sorted = PiBotModelCatalog.newestFirst(ids.map { PiBotModelOption(id: $0, name: $0) }).map(\.id)
        #expect(sorted == ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-5.6-luna", "claude-opus-5-5", "claude-opus-4-5", "chat-latest"])
        // Dates and parameter counts are not versions.
        let dated = ["gpt-4o-2024-08-06", "gpt-4.1", "mistral-medium-2508", "llama-3.3-70b", "claude-haiku-4-5-20251001", "claude-haiku-5-5"]
        #expect(PiBotModelCatalog.newestFirst(dated.map { PiBotModelOption(id: $0, name: $0) }).map(\.id)
            == ["claude-haiku-5-5", "claude-haiku-4-5-20251001", "gpt-4.1", "gpt-4o-2024-08-06", "llama-3.3-70b", "mistral-medium-2508"])
    }

    @Test func pricesKeepTheCatalogValues() {
        #expect(PiBotModelFacts.usd(2.5) == "$2.5")
        #expect(PiBotModelFacts.usd(0.125) == "$0.125")
        #expect(PiBotModelFacts.usd(0.000001) == "$0.000001")
        #expect(PiBotModelFacts.usd(15) == "$15")
        #expect(PiBotModelFacts.usd(0) == "$0")
        #expect(PiBotModelFacts.usd(0.1 + 0.2) == "$0.3")
    }

    @Test func tokensAbbreviate() {
        #expect(PiBotModelFacts.tokens(200_000) == "200k")
        #expect(PiBotModelFacts.tokens(1_000_000) == "1M")
        #expect(PiBotModelFacts.tokens(1_500_000) == "1500k")
        #expect(PiBotModelFacts.tokens(900) == "900")
    }

    @Test func factsDescribeOneModel() {
        let rates = PiBotPriceRates(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        let model = PiBotModelOption(id: "m", name: "M", reasoning: true, contextWindow: 200_000, maxTokens: 64_000, input: ["text", "image"],
            pricing: PiBotModelPricing(status: "listed", rates: rates, tiers: [.init(input: 6, output: 22.5, cacheRead: 0.6, cacheWrite: 7.5, inputTokensAbove: 200_000)]))
        let providers = [PiBotProviderModels(id: "p", name: "P", access: .init(kind: "api_key", label: "API key"), models: [model])]
        #expect(PiBotModelFacts.text(providers, "p/m") == "$3 in · $15 out · $0.3 cache read · $3.75 cache write per 1M tokens (other rates above set input sizes) · 200k context · 64k max output · text, image · reasoning · API key")
        #expect(PiBotModelFacts.text(providers, "p/other") == "Not signed in: no catalog details")
        #expect(PiBotModelFacts.tierTexts(model.pricing) == ["Above 200k input tokens: $6 in · $22.5 out · $0.6 cache read · $7.5 cache write per 1M tokens"])
        #expect(PiBotModelFacts.priceText(nil) == "API price unknown")
        #expect(PiBotModelFacts.priceText(PiBotModelPricing(status: "zero")) == "API price listed as $0 (free or unpriced)")
    }

    @Test func aDraftRoundTripsAndChecksItsFallbacks() throws {
        let profile = PiBotProfile(id: "c", name: "Coding", main: "p/a", fallbacks: ["p/b"], memoryModel: "p/c", guidance: " g ",
            pool: [.init(model: "p/d", useFor: "notes")])
        var draft = PiBotProfileDraft(profile: profile)
        #expect(draft.canSave(isNew: false))
        guard case .object(let wire) = draft.wire else { Issue.record("not an object"); return }
        #expect(wire["main"] == .string("p/a"))
        #expect(wire["fallbacks"] == .array([.string("p/b")]))
        #expect(wire["memoryModel"] == .string("p/c"))
        #expect(wire["guidance"] == .string("g"))
        #expect(wire["pool"] == .array([.object(["model": .string("p/d"), "useFor": .string("notes")])]))

        draft.fallbacks.append(.init(model: "p/a"))
        #expect(draft.fallbackProblem == "A fallback can't be the main model.")
        draft.fallbacks = [.init(model: "p/b"), .init(model: "p/b")]
        #expect(draft.fallbackProblem == "Each fallback can appear only once.")
        #expect(!draft.canSave(isNew: false))

        var empty = PiBotProfileDraft()
        empty.name = "x"; empty.main = "p/a"
        #expect(!empty.canSave(isNew: true))
        empty.id = "x"
        #expect(empty.canSave(isNew: true))
        guard case .object(let minimal) = empty.wire else { Issue.record("not an object"); return }
        #expect(minimal["memoryModel"] == nil)
        #expect(minimal["guidance"] == nil)
    }
}

@Suite("Pi Bot teams and status")
struct PiBotTeamsTests {
    private func bot(_ id: String, kind: String = "bot", manager: Bool = false, managerId: String? = nil, orchestrator: Bool = false) -> PiBotSummary {
        PiBotSummary(id: id, name: id, kind: kind, manager: manager, managerId: managerId, orchestrator: orchestrator)
    }

    @Test func settingsOrderMatchesPiBot() {
        let layout = PiBotTeamLayout([
            bot("admin", kind: "admin"), bot("free"), bot("member", managerId: "lead"), bot("lead", manager: true),
            bot("orch", manager: true, orchestrator: true), bot("orchMember", managerId: "orch"), bot("lost", managerId: "gone"),
        ])
        #expect(layout.rows.map(\.id) == ["orch", "orchMember", "lead", "member", "free", "lost"])
        #expect(layout.rows.filter(\.isMember).map(\.id) == ["orchMember", "member"])
        #expect(layout.admin?.id == "admin")
    }

    @Test func rolesAndPlacements() {
        #expect(bot("a", kind: "admin").role == "Admin")
        #expect(bot("a", orchestrator: true).role == "Orchestrator")
        #expect(bot("a", manager: true).role == "Manager")
        #expect(bot("a").role == "Bot")
        #expect(bot("a", manager: true).placement == "manager")
        #expect(bot("a", managerId: "m").placement == "m")
        #expect(bot("a").placement == "none")
    }

    @Test func modelStatusWordsMatchPiBot() {
        typealias Status = PiBotSummary.ModelStatus
        let utc = TimeZone(identifier: "UTC")!
        let at = 1_730_000_000_000.0 // Sun Oct 27 2024 03:33 UTC
        let primary = Status.Limit(model: "p/a", account: "ChatGPT account", kind: "five_hour", resetsAt: at, retryAt: at)
        let fallback = PiBotModelStatusText(status: Status(kind: "fallback", primary: "p/a", active: "p/b", limits: [primary]), botName: "Ada", timeZone: utc)
        #expect(fallback.tone == .warning)
        #expect(fallback.title == "Your ChatGPT account hit its 5-hour usage limit (p/a).")
        #expect(fallback.lines == ["Resets Sun, 3:33 AM GMT.", "Ada is now using p/b until then."])

        let other = Status.Limit(model: "p/b", account: "OpenRouter key", kind: "credits", retryAt: at)
        let paused = PiBotModelStatusText(status: Status(kind: "paused", primary: "p/a", active: "p/a", limits: [primary, other]), botName: "Ada", timeZone: utc)
        #expect(paused.tone == .error)
        #expect(paused.lines[1] == "Fallback p/b: your OpenRouter key ran out of credits. Reset time not reported; Pi Bot tries again around Sun, 3:33 AM GMT.")
        #expect(paused.lines[2] == "Ada is paused: every fallback is out too.")

        let alone = PiBotModelStatusText(status: Status(kind: "paused", primary: "p/a", active: "p/a", limits: []), botName: "Ada", timeZone: utc)
        #expect(alone.title == "p/a is unavailable.")
        #expect(alone.lines == ["Ada is paused: this profile has no fallback. Add one under Settings → Bots → Profiles."])

        let back = PiBotModelStatusText(status: Status(kind: "returned", primary: "p/a", active: "p/a"), botName: "Ada", timeZone: utc)
        #expect(back.tone == .success)
        #expect(back.title == "Ada is back on p/a.")
    }

    @Test func aBotDecodesItsProfileAndStatus() throws {
        let bot: PiBotSummary = try decoded(#"""
        {"id":"a","name":"Ada","createdAt":"x","kind":"bot","manager":false,"orchestrator":false,
         "profileId":"p","profileName":"Coding","defaultProfile":true,
         "modelStatus":{"kind":"paused","at":5,"primary":"m","active":"m","limits":[{"model":"m","account":"A","kind":"usage","retryAt":9}]}}
        """#)
        #expect(bot.profileName == "Coding")
        #expect(bot.defaultProfile == true)
        #expect(bot.modelStatus?.limits?.first?.retryAt == 9)
        let thread: PiBotThread = try decoded(#"{"conversationId":2,"parentConversationId":1,"forkedAt":7,"createdAt":"x"}"#)
        #expect(thread.parentConversationId == 1)
        #expect(thread.forkedAt == 7)
    }
}

@Suite("Pi Bot attachments")
struct PiBotAttachmentTests {
    private func file(_ name: String, _ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func readsTextAndRefusesTheRest() throws {
        #expect(try PiBotAttachmentDraft.read(file("a.md", Data("hi".utf8))).text == "hi")
        #expect(try PiBotAttachmentDraft.read(file("A.SWIFT.TXT", Data("hi".utf8))).name == "A.SWIFT.TXT")
        #expect(throws: PiBotAttachmentDraft.Problem.notText) { try PiBotAttachmentDraft.read(file("a.png", Data("hi".utf8))) }
        #expect(throws: PiBotAttachmentDraft.Problem.binary) { try PiBotAttachmentDraft.read(file("a.txt", Data([0x61, 0x00]))) }
        #expect(throws: PiBotAttachmentDraft.Problem.tooLarge) { try PiBotAttachmentDraft.read(file("a.txt", Data(repeating: 0x61, count: 80_001))) }
    }

    @Test func messageTextFollowsPiBotsFormat() {
        let url = URL(fileURLWithPath: "/tmp/a.md")
        let attachment = PiBotAttachmentDraft(name: "a.md", text: "body", url: url)
        #expect(PiBotAttachmentDraft.message(draft: " hi ", attachments: [attachment]) == "hi\n\nAttached text file: a.md\n\nbody")
        #expect(PiBotAttachmentDraft.message(draft: "  ", attachments: [attachment]) == "Attached text file: a.md\n\nbody")
        #expect(PiBotAttachmentDraft.message(draft: "  ", attachments: []).isEmpty)
    }
}

@Suite("Runtime additions")
struct PiBotRuntimeAdditionsTests {
    @Test func runtimeStatusAndUpdateProgressDecode() throws {
        let status = try JSONDecoder().decode(PiBotRuntimeStatus.self, from: Data(#"{"version":"0.1.0","environment":"mac-vm","bots":3,"extra":true}"#.utf8))
        #expect(status.environment == "mac-vm" && status.bots == 3)
        let rolled = try JSONDecoder().decode(PiBotRuntimeProgress.self, from: Data(#"{"type":"runtime.update","botId":"b","phase":"rolledBack","error":"Health check failed"}"#.utf8))
        #expect(rolled.botId == "b" && !rolled.isFinished && rolled.text.contains("Health check failed"))
        let done = try JSONDecoder().decode(PiBotRuntimeProgress.self, from: Data(#"{"type":"runtime.update","phase":"done"}"#.utf8))
        #expect(done.isFinished && done.text == "Update finished")
    }

    @Test func helloAndEnvironmentDecode() throws {
        let health = try JSONDecoder().decode(PiBotHealth.self, from: Data(#"{"ok":true,"version":"0.1.0","protocol":1,"installationId":"i","environment":"mac-vm","capabilities":["groups","message.context","bots.environment","runtime.update","previews"]}"#.utf8))
        #expect(health.environment == "mac-vm" && health.capabilities?.contains("runtime.update") == true)
        let environment = try JSONDecoder().decode(PiBotEnvironment.self, from: Data(#"{"botId":"b","state":"running","busy":"a turn is running","lastActivity":1,"services":[],"previews":[{"port":3000,"url":"https://mac.tail.ts.net:8443/"}]}"#.utf8))
        #expect(environment.previews.first?.port == 3000 && environment.stateText.contains("turn"))
    }
}
