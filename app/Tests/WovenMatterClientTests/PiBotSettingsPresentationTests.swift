import XCTest
@testable import WovenMatterClient

final class PiBotSettingsPresentationTests: XCTestCase {
    func testRestartRequiresDropThenReturn() {
        var state = PiBotRestartProgress(activeWork: 1, mode: "exit")
        state.connectionChanged(connected: true)
        XCTAssertEqual(state.phase, .restarting)
        XCTAssertTrue(state.message(show: false)!.contains("1 running turn finish"))
        XCTAssertTrue(state.message(show: false)!.contains("service manager"))
        state.connectionChanged(connected: false)
        XCTAssertTrue(state.dropped)
        state.connectionChanged(connected: true)
        XCTAssertEqual(state.phase, .back)
        state.timedOut()
        XCTAssertEqual(state.phase, .back)
        XCTAssertEqual(state.message(show: false), "Pi Bot is back and running with the saved config.")
    }

    func testTimeoutAndIdleNotices() {
        var state = PiBotRestartProgress(activeWork: 2, mode: "reload")
        XCTAssertTrue(state.message(show: false)!.contains("2 running turns"))
        state.timedOut()
        XCTAssertEqual(state.phase, .failed)
        state.connectionChanged(connected: false)
        state.connectionChanged(connected: true)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.message(show: false), "Pi Bot has not come back yet. Check the server log; this page keeps reconnecting.")
        XCTAssertNil(PiBotRestartProgress().message(show: false))
        XCTAssertEqual(PiBotRestartProgress().message(show: true), "Saved. Restart Pi Bot to apply.")
    }

    func testNumberedProviderSteps() {
        let parsed = PiBotLoginSteps("Follow these steps:\n\n1. Open the page\n2. Copy the code\nKeep this window open")
        XCTAssertEqual(parsed.lead, ["Follow these steps:", "Keep this window open"])
        XCTAssertEqual(parsed.steps, ["Open the page", "Copy the code"])
        let prose = "One instruction\n1. Open the page"
        XCTAssertEqual(PiBotLoginSteps(prose).lead, [prose])
        XCTAssertEqual(PiBotLoginSteps(prose).steps, [])
    }

    func testEarlyLoginEventsReplayOnceInOrder() {
        var backlog = PiBotLoginBacklog()
        backlog.append(.info("Starting"), loginID: "first")
        backlog.append(.deviceCode(userCode: "AB", verificationUri: "https://example.com"), loginID: "first")
        backlog.append(.done, loginID: "second")
        XCTAssertEqual(backlog.take(loginID: "first"), [
            .info("Starting"), .deviceCode(userCode: "AB", verificationUri: "https://example.com"),
        ])
        XCTAssertEqual(backlog.take(loginID: "first"), [])
        XCTAssertEqual(backlog.take(loginID: "second"), [.done])
    }

    func testLoginBacklogEvictsOldSessionsAndClears() {
        var backlog = PiBotLoginBacklog()
        for number in 0..<21 { backlog.append(.info("Waiting"), loginID: String(number)) }
        XCTAssertEqual(backlog.take(loginID: "0"), [])
        XCTAssertEqual(backlog.take(loginID: "1"), [.info("Waiting")])
        backlog.removeAll()
        XCTAssertEqual(backlog.take(loginID: "20"), [])
    }

}
