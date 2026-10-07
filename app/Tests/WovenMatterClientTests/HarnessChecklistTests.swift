import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct HarnessChecklistTests {
    @Test func codexCatalogEnablesNativeChecklistWithoutChangingOtherHarnesses() throws {
        let definition = try #require(LocalACPRuntimeCatalog.definition(for: .codex))
        let encoded = try #require(definition.environment["CODEX_CONFIG"])
        let config = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as! [String: Any]
        #expect(config["tools.update_plan.enabled"] as? Bool == true)
        #expect(config["approvals_reviewer"] as? String == "auto_review")
        #expect(definition.adapterPackage == "@agentclientprotocol/codex-acp")
        #expect(LocalACPRuntimeCatalog.definition(for: .pi)?.environment["CODEX_CONFIG"] == nil)
    }

    @Test func hermesUsesCanonicalResultForPartialMergeAndRejectsMalformedUpdates() throws {
        let payload: HermesValue = ["name": "todo_list", "args": ["merge": .bool(true), "todos": .array([
            ["id": "a", "status": "completed"]
        ])], "result": ["revision": .number(2), "todos": .array([
            ["id": "a", "content": "Same label", "status": "completed"],
            ["id": "b", "content": "Same label", "status": "cancelled"],
            ["id": "c", "content": "Future state", "status": "waiting"]
        ])]]
        let plan = try #require(HermesGatewayClient.checklistUpdate(payload))
        #expect(plan.planKind == "checklist")
        #expect(plan.planOperation == "replace")
        #expect(plan.planEntries.map(\.nativeID) == ["a", "b", "c"])
        #expect(plan.planEntries.map(\.status) == ["completed", "cancelled", "waiting"])
        for mutation: (inout HermesValue) -> Void in [
            { $0["args"] = [:] }, // Reading an earlier task's checklist is not current progress.
            { $0["name"] = "mcp__todo_list" },
            { $0["result"]["error"] = "failed" },
            { $0["result"]["todos"] = .null },
            { $0["result"]["todos"] = .array([["id": "a", "content": "missing status"]]) },
            { $0["result"]["todos"] = .array([payload["result"]["todos"].array[0], payload["result"]["todos"].array[0]]) },
        ] {
            var changed = payload; mutation(&changed)
            #expect(HermesGatewayClient.checklistUpdate(changed) == nil)
        }
        var clear = payload
        clear["result"]["todos"] = .array([])
        let empty = try #require(HermesGatewayClient.checklistUpdate(clear))
        #expect(empty.planOperation == "clear")
        #expect(empty.planEntries.isEmpty)
    }

    @Test func openCodeToolsAndChildOutputDoNotInventUnsupportedChecklistProgress() {
        // OpenCode 2.0.22 removed todowrite. Imported v1 tools and arbitrary
        // extension names remain inspectable tool activity, not active plans.
        let message: OpenCodeValue = ["id": "message", "type": "assistant", "content": .array([
            ["type": "text", "text": "Before"],
            ["type": "tool", "id": "todo", "name": "todowrite", "state": ["status": "completed", "input": ["todos": .array([])]]],
            ["type": "tool", "id": "child", "name": "subagent", "state": ["status": "completed", "output": "{\"todos\":[{\"content\":\"child work\",\"status\":\"completed\"}]}" ]],
            ["type": "text", "text": "After"]
        ])]
        let activities = OpenCodeSessionSnapshot.activities(message)
        #expect(activities.map(\.kind) == [.assistant, .tool, .tool, .assistant])
        #expect(activities.filter { $0.kind == .assistant }.map(\.content) == ["Before\n\n", "After"])
        #expect(activities.last?.assistantCheckpoint == AssistantTextCheckpoint(OpenCodeSessionSnapshot.text(message)))
    }
}
