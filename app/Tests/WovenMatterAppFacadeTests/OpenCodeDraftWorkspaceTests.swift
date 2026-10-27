import Testing
import WovenMatterClient
@testable import WovenMatterAppFacade

@MainActor
struct OpenCodeDraftWorkspaceTests {
    // Recorded structural shape from an actual newly created OpenCode 2.1.3
    // session after Woven applies its initial model, before any submitted input.
    private var configuredDraft: OpenCodeSessionSnapshot {
        var snapshot = OpenCodeSessionSnapshot()
        snapshot.messages = [["id": "msg_initial_model", "type": "model-switched",
            "model": ["id": "fixture-model", "providerID": "fixture-provider"],
            "time": ["created": .number(1)]]]
        return snapshot
    }

    @Test func initialModelConfigurationStillAllowsFirstSendFolderBinding() {
        #expect(OpenCodeModel.isUnsentDraft(OpenCodeSessionSnapshot()))
        #expect(OpenCodeModel.isUnsentDraft(configuredDraft))
        var changedAgain = configuredDraft
        changedAgain.messages.append(["id": "msg_second_model", "type": "model-switched"])
        #expect(OpenCodeModel.isUnsentDraft(changedAgain))
    }

    @Test(arguments: ["user", "assistant", "synthetic", "system", "shell", "skill",
                      "compaction", "agent", "location", "unknown", ""])
    func actualOrUnknownHistoryPreventsMovingTheDraft(type: String) {
        var snapshot = configuredDraft
        snapshot.messages.append(["id": "msg_history", "type": .string(type)])
        #expect(!OpenCodeModel.isUnsentDraft(snapshot))
    }

    @Test func activeQueuedAndIncompleteHistoryRemainBlocked() {
        var active = configuredDraft
        active.active = true
        #expect(!OpenCodeModel.isUnsentDraft(active))
        var queued = configuredDraft
        queued.inbox = [["id": "pending_input"]]
        #expect(!OpenCodeModel.isUnsentDraft(queued))
        var paged = configuredDraft
        paged.olderCursor = "earlier_native_history"
        #expect(!OpenCodeModel.isUnsentDraft(paged))
    }
}
