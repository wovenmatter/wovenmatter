import Testing
@testable import WovenMatterAppFacade

/// Typing "@" in a composer that can name someone: what is offered, and what picking writes.
@Suite("Composer mentions")
struct ComposerMentionTests {
    private let bots = [ComposerMention(name: "Ada"), ComposerMention(name: "Ada Two"), ComposerMention(name: "Max Power"),
                        ComposerMention(name: "everyone", detail: "Every bot in the Forum")]
    private func names(_ draft: String) -> [String] { ComposerMention.matching(draft, among: bots).map(\.name) }

    @Test func anAtSignOffersEveryoneWhoCanBeNamed() {
        #expect(names("@") == ["Ada", "Ada Two", "Max Power", "everyone"])
        #expect(names("morning @") == ["Ada", "Ada Two", "Max Power", "everyone"])
        #expect(names("morning\n@") == ["Ada", "Ada Two", "Max Power", "everyone"])
    }

    @Test func typingNarrowsTheNamesWhateverTheCase() {
        #expect(names("@a") == ["Ada", "Ada Two"])
        #expect(names("hi @MA") == ["Max Power"])
        #expect(names("@ev") == ["everyone"])
        // A later word of a name finds it too, after the names that start that way.
        #expect(names("@po") == ["Max Power"])
        #expect(names("@t") == ["Ada Two"])
    }

    @Test func aNameTypedInFullStopsOfferingUnlessAnotherStillFits() {
        #expect(names("@max power") == [])
        #expect(names("@Ada") == ["Ada", "Ada Two"])
        #expect(names("@Ada Two") == [])
    }

    @Test func textThatIsNoNameOffersNothing() {
        #expect(names("@Dana") == [])
        #expect(names("@Ada how are you") == [])
        #expect(names("no mention here") == [])
        #expect(names("write to ada@example.com") == [])
        #expect(names("@Ada\nnext line") == [])
        #expect(ComposerMention.matching("@", among: []) == [])
    }

    @Test func onlyTheLastAtSignIsBeingTyped() {
        #expect(names("@Ada and @m") == ["Max Power"])
        #expect(ComposerMention.query(in: "@Ada and @m") == "m")
        #expect(ComposerMention.query(in: "a@b") == nil)
    }

    @Test func pickingWritesTheNameOutAndKeepsWhatCameBefore() {
        #expect(ComposerMention.completing("@a", with: bots[1]) == "@Ada Two ")
        #expect(ComposerMention.completing("hello @Ada and @ma", with: bots[2]) == "hello @Ada and @Max Power ")
        #expect(ComposerMention.completing("@", with: bots[3]) == "@everyone ")
        #expect(ComposerMention.completing("nothing typed", with: bots[0]) == "nothing typed")
    }
}
