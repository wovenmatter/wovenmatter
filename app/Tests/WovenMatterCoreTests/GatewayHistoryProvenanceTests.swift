import Testing
@testable import WovenMatterClient
@testable import WovenMatterDashboardStore

struct GatewayHistoryProvenanceTests {
  @Test(arguments: [false, true])
  func recoveryRetainsTranscriptProvenance(finalOnly: Bool) async throws {
    let message = historyMessage(idempotencyKey: finalOnly ? "owned:assistant" : "owned", text: "retained text")
    let recovered = await GatewayHistoryRecovery.assistantMessage(
      remoteRunID: "owned", knownInputIDs: ["owned"],
      fetch: { .object(["messages": .array([message])]) },
      pause: { _ in }
    )
    #expect(recovered?.text == "retained text")
    #expect(recovered?.isFinalOnlyAssistantTranscript == finalOnly)
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
