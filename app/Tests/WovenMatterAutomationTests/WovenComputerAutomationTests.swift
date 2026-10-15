import Foundation
import Testing
import WovenMatterAutomation
import WovenMatterClient

struct WovenComputerAutomationTests {
  @MainActor @Test func admissionFailsBeforeAnyDesktopOperation() async throws {
    let computer = WovenComputerAutomation()
    for action in ["apps", "launch", "screenshot", "click", "type", "press", "scroll"] {
      await #expect(throws: CancellationError.self) {
        try await computer.execute(.object(["action": .string(action)]), callerID: "fixture", admit: { throw CancellationError() })
      }
    }
  }
}
