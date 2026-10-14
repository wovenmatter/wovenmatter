import Foundation
import Testing
@testable import WovenMatterCompanion

@Suite("Companion wire compatibility")
struct CompanionProtocolTests {
  @Test("pairing and hello agree on the current format and reject older pairing codes")
  func versionNegotiation() throws {
    let endpoint = URL(string: "https://fixture.test.ts.net/wovenmatter")!
    let token = String(repeating: "a", count: 32)
    let payload = try CompanionPairingPayload(endpoint: endpoint, token: token)
    #expect(payload.protocolVersion == CompanionProtocol.version)
    #expect(try CompanionPairingPayload.parseURL(payload.encodedURL) == payload)
    #expect(CompanionPairRequest(token: token, deviceID: "phone", deviceName: "iPhone").protocolVersion == CompanionProtocol.version)
    #expect(CompanionPairResponse(workspaceID: "workspace", deviceID: "phone", credential: token).protocolVersion == CompanionProtocol.version)
    #expect(CompanionHello(workspaceID: "workspace", hostName: "Mac", capabilities: []).protocolVersion == CompanionProtocol.version)
    #expect(throws: CompanionAPIError.self) {
      try CompanionPairingPayload(endpoint: endpoint, token: token, protocolVersion: 1)
    }
  }

  @Test("a pending native interaction round-trips without an invented run ID")
  func nativeInteractionBeforeRunProjection() throws {
    let pending = CompanionPendingInteraction(id: "request", conversationID: "chat", runID: nil,
      kind: .approval, title: "Read file", options: [.init(id: "once", label: "Allow once")])
    let bytes = try JSONEncoder().encode(pending)
    #expect(try JSONDecoder().decode(CompanionPendingInteraction.self, from: bytes) == pending)
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(object["runID"] == nil)
  }
  @Test("scheduled task visibility survives editing and legacy drafts preserve host visibility")
  func scheduledTaskVisibility() throws {
    let hidden = CompanionCalendarDraft(title: "Daily check", task: .init(prompt: "Review"), showsOnCalendar: false)
    let action = CompanionWorkspaceAction.saveCalendar(id: "task", revision: 4, draft: hidden)
    #expect(try JSONDecoder().decode(CompanionWorkspaceAction.self, from: JSONEncoder().encode(action)) == action)
    let event = CompanionCalendarEvent(id: "task", revision: 4, draft: hidden)
    let response = CompanionWorkspaceResult.scheduledTasks([.init(event: event, showsOnCalendar: false,
      runtimeName: "Pi Durable", workspaceName: "Local workspace", lastRunAt: nil)])
    #expect(try JSONDecoder().decode(CompanionWorkspaceResult.self, from: JSONEncoder().encode(response)) == response)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(hidden)) as? [String: Any])
    legacy.removeValue(forKey: "showsOnCalendar")
    let decoded = try JSONDecoder().decode(CompanionCalendarDraft.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.showsOnCalendar == nil)
    #expect(decoded.task?.prompt == hidden.task?.prompt)
  }

}
