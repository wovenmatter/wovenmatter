import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor struct PageTaskTests {
    @Test func theFirstMessageCarriesTheTaskAndHowToReportBack() {
        let work = ApplicationModel.PageTaskWork(pageID: "page-1", pageTitle: "Launch", componentID: "task-1",
            title: "  Write the launch email ", details: "Keep it short.",
            assignee: BoardTaskAssignee(id: "a", kind: .agent, name: "Codex", workspaceID: "w", runtime: "codex"))
        #expect(work.chatTitle == "Write the launch email")
        #expect(work.prompt.contains("Page “Launch”"))
        #expect(work.prompt.contains("Task: Write the launch email\n\nInstructions:\nKeep it short."))
        #expect(work.prompt.contains("Page ID: page-1. Task component ID: task-1."))
        #expect(work.prompt.contains("If you need more input from the person, write what you need in the outcome and set status blocked."))
        let untitled = ApplicationModel.PageTaskWork(pageID: "p", pageTitle: "", componentID: "c", title: " ", details: "",
            assignee: BoardTaskAssignee(kind: .user))
        #expect(untitled.chatTitle == "Task" && untitled.prompt.contains("“Untitled Page”"))
    }

    @Test func aBotThreadOpensThroughTheChatCallback() {
        let target = BotTarget(machineID: "machine", botID: "bot", conversationID: 7)
        #expect(BotTarget(pageTaskLink: target.pageTaskLink) == target)
        let main = BotTarget(machineID: "machine", botID: "bot")
        #expect(BotTarget(pageTaskLink: main.pageTaskLink) == main)
        #expect(BotTarget(pageTaskLink: UUID().uuidString) == nil)
    }

    /// The Forum is a target like a bot: it survives the same link and names its own rooms.
    @Test func theForumIsATargetOfItsOwn() {
        let forum = BotTarget.forum(machineID: "machine")
        #expect(forum.isForum && forum.botID == BotTarget.forumBotID && forum.conversationID == nil)
        #expect(BotTarget(pageTaskLink: forum.pageTaskLink) == forum)
        let thread = BotTarget.forum(machineID: "machine", roomID: 4)
        #expect(BotTarget(pageTaskLink: thread.pageTaskLink) == thread)
        #expect(thread.isForum && thread.conversationID == 4)
        #expect(!BotTarget(machineID: "machine", botID: UUID().uuidString).isForum)
        #expect(BotTarget.forum(machineID: "m", roomID: 4, showsThreadBesideMain: true).showsThreadBesideMain)
    }
}
