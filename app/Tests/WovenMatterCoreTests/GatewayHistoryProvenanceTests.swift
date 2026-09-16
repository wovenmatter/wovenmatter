import Testing
@testable import WovenMatterClient
@testable import WovenMatterDashboardStore

struct GatewayHistoryProvenanceTests {
  @Test func recoveryRetainsFinalOnlyTranscriptProvenance() async throws {
    let finalOnly = historyMessage(idempotencyKey: "owned:assistant", text: "final suffix")
    let recovered = await GatewayHistoryRecovery.assistantMessage(
      remoteRunID: "owned", knownInputIDs: ["owned"],
      fetch: { .object(["messages": .array([finalOnly])]) },
      pause: { _ in }
    )

    #expect(recovered?.text == "final suffix")
    #expect(recovered?.isFinalOnlyAssistantTranscript == true)
  }

  @Test func recoveryRetainsWholeMessageSnapshotProvenance() async throws {
    let snapshot = historyMessage(idempotencyKey: "owned", text: "whole message")
    let recovered = await GatewayHistoryRecovery.assistantMessage(
      remoteRunID: "owned", knownInputIDs: ["owned"],
      fetch: { .object(["messages": .array([snapshot])]) },
      pause: { _ in }
    )

    #expect(recovered?.text == "whole message")
    #expect(recovered?.isFinalOnlyAssistantTranscript == false)
  }

  private func historyMessage(idempotencyKey: String, text: String) -> GatewayJSONValue {
    .object([
      "role": .string("assistant"),
      "text": .string(text),
      "__openclaw": .object([
        "id": .string("fixture-\(idempotencyKey)"),
        "idempotencyKey": .string(idempotencyKey),
      ]),
    ])
  }
}
