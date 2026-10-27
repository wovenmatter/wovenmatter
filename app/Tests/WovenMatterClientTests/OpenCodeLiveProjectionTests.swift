import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct OpenCodeLiveProjectionTests {
    private func event(_ type: String, kind: String = "text", ordinal: Int = 0, text: String? = nil) -> OpenCodeValue {
        var data: OpenCodeValue = ["sessionID": "session", "assistantMessageID": "message", "ordinal": .number(Double(ordinal))]
        if let text { data[type == "delta" ? "delta" : "text"] = .string(text) }
        return ["type": .string("session.\(kind).\(type)"), "data": data, "created": .number(1000)]
    }

    @Test func nativePartsStreamInOrderAndEndedTextReplacesDeltas() {
        var projection = OpenCodeLiveProjection()
        let accepted1 = projection.receive(event("started", kind: "reasoning"), sessionID: "session")
        #expect(accepted1)
        let accepted2 = projection.receive(event("delta", kind: "reasoning", text: "Think 🧵"), sessionID: "session")
        #expect(accepted2)
        let accepted3 = projection.receive(event("started"), sessionID: "session")
        #expect(accepted3)
        let accepted4 = projection.receive(event("delta", text: "Hello"), sessionID: "session")
        #expect(accepted4)
        let accepted5 = projection.receive(event("delta", text: " Hello"), sessionID: "session")
        #expect(accepted5)
        var snapshot = projection.applying(to: OpenCodeSessionSnapshot())
        #expect(snapshot.active)
        #expect(snapshot.messages[0]["content"].array.map { $0["type"].text } == ["reasoning", "text"])
        #expect(OpenCodeSessionSnapshot.text(snapshot.messages[0]) == "Hello Hello")
        #expect(OpenCodeSessionSnapshot.activities(snapshot.messages[0])[0].status == "running")
        let accepted6 = !projection.receive(event("started"), sessionID: "session")
        #expect(accepted6)
        let accepted7 = projection.receive(event("ended", text: "Corrected answer"), sessionID: "session")
        #expect(accepted7)
        let accepted8 = projection.receive(event("ended", kind: "reasoning", text: "Final thought"), sessionID: "session")
        #expect(accepted8)
        snapshot = projection.applying(to: snapshot)
        #expect(OpenCodeSessionSnapshot.text(snapshot.messages[0]) == "Corrected answer")
        #expect(OpenCodeSessionSnapshot.activities(snapshot.messages[0])[0].status == "completed")
        #expect(projection.applying(to: snapshot) == snapshot)
    }

    @Test func reconnectAndCanonicalCompletionDoNotDuplicateOrResurrectText() {
        var projection = OpenCodeLiveProjection()
        let accepted9 = !projection.receive(event("delta", text: "unknown baseline"), sessionID: "session")
        #expect(accepted9)
        let accepted10 = !projection.receive(event("started"), sessionID: "another-session")
        #expect(accepted10)
        let accepted11 = projection.receive(event("ended", text: "live final"), sessionID: "session")
        #expect(accepted11)
        var snapshot = OpenCodeSessionSnapshot()
        snapshot.messages = [["id": "message", "type": "assistant", "content": .array([["type": "text", "text": "stale"]])]]
        #expect(OpenCodeSessionSnapshot.text(projection.applying(to: snapshot).messages[0]) == "live final")
        snapshot.messages[0]["time"] = ["completed": .number(2000)]
        snapshot.messages[0]["content"] = .array([["type": "text", "text": "canonical correction"]])
        projection.reconcile(snapshot)
        #expect(projection.applying(to: snapshot) == snapshot)
    }

    @Test func toolInputStreamsInNativeOrderAndFailureSettlesTheSameTool() {
        var projection = OpenCodeLiveProjection()
        func tool(_ type: String, _ values: [String: OpenCodeValue] = [:]) -> OpenCodeValue {
            var data: OpenCodeValue = ["sessionID": "session", "assistantMessageID": "message", "id": "tool"]
            for (key, value) in values { data[key] = value }
            return ["type": .string("session.tool." + type), "data": data, "created": .number(1000)]
        }
        let accepted12 = projection.receive(event("started", kind: "reasoning"), sessionID: "session")
        #expect(accepted12)
        let accepted13 = projection.receive(tool("input.started", ["name": "shell"]), sessionID: "session")
        #expect(accepted13)
        let accepted14 = projection.receive(tool("input.delta", ["delta": "{\"command\":"]), sessionID: "session")
        #expect(accepted14)
        var snapshot = projection.applying(to: OpenCodeSessionSnapshot())
        var activities = OpenCodeSessionSnapshot.activities(snapshot.messages[0])
        #expect(activities.map(\.kind) == [.thought, .tool])
        #expect(activities[1].status == "pending")
        #expect(activities[1].rawInputJSON == "{\"command\":")
        var interrupted = projection
        interrupted.finish()
        let stopped = interrupted.applying(to: snapshot)
        #expect(OpenCodeSessionSnapshot.activities(stopped.messages[0])[1].status == "cancelled")
        let accepted15 = projection.receive(tool("called", ["input": ["command": "false"]]), sessionID: "session")
        #expect(accepted15)
        let accepted16 = projection.receive(tool("failed", ["error": ["type": "execution", "message": "exit 1"]]), sessionID: "session")
        #expect(accepted16)
        snapshot = projection.applying(to: snapshot)
        activities = OpenCodeSessionSnapshot.activities(snapshot.messages[0])
        #expect(activities.count == 2)
        #expect(activities[1].id == "message:tool")
        #expect(activities[1].status == "failed")
        #expect(activities[1].content == "exit 1")
        projection.finish()
        #expect(!projection.applying(to: snapshot).active)
    }

    @Test func terminalOutputDeltasKeepDistinctArchiveIdentities() throws {
        let payload = #"{"sessionUpdate":"tool_call_update","toolCallId":"tool","_meta":{"terminal_output_delta":{"data":"repeated"}}}"#
        let update = try JSONDecoder().decode(ACPJSONValue.self, from: Data(payload.utf8))
        let first = try ACPNativeHistoryCapture.record(update, runID: "run")
        let second = try ACPNativeHistoryCapture.record(update, runID: "run")
        #expect(first.id != second.id)
        #expect(first.contentMode == "delta" && second.contentMode == "delta")
        #expect(try ACPNativeHistoryCapture.record(update, runID: nil, replayOrdinal: 2).id == "replay:2")
        let completion = try JSONDecoder().decode(ACPJSONValue.self,
            from: Data(#"{"sessionUpdate":"tool_call_update","toolCallId":"tool","status":"completed"}"#.utf8))
        let completed = try ACPNativeHistoryCapture.record(completion, runID: "run")
        #expect(completed.id != first.id && completed.contentMode == "event")
    }

    @Test func aNewStartAfterInterruptionCanReuseItsNativeIdentity() {
        var projection = OpenCodeLiveProjection()
        let accepted17 = projection.receive(event("started"), sessionID: "session")
        #expect(accepted17)
        let accepted18 = projection.receive(event("delta", text: "old"), sessionID: "session")
        #expect(accepted18)
        projection.finish()
        let accepted19 = projection.receive(event("started"), sessionID: "session")
        #expect(accepted19)
        let accepted20 = projection.receive(event("delta", text: "new"), sessionID: "session")
        #expect(accepted20)
        let snapshot = projection.applying(to: OpenCodeSessionSnapshot())
        #expect(snapshot.active)
        #expect(OpenCodeSessionSnapshot.text(snapshot.messages[0]) == "new")
    }

    @Test func acceptedIdleRecoveryDoesNotMaskTheNextActivePrompt() {
        var projection = OpenCodeLiveProjection()
        projection.finish()
        projection.reconcile(OpenCodeSessionSnapshot())
        var next = OpenCodeSessionSnapshot()
        next.active = true
        #expect(projection.applying(to: next).active)
    }

    @Test func inheritedSSECursorDoesNotBecomeAnotherEventsIdentity() throws {
        var parser = OpenCodeSSEParser(), identities: [String?] = []
        for byte in "id: first\ndata: {}\n\ndata: {}\n\n".utf8 {
            for _ in try parser.append(byte) { identities.append(parser.frameEventID) }
        }
        #expect(identities.count == 2)
        #expect(identities[0] == "first" && identities[1] == nil)
        #expect(parser.lastEventID == "first")
    }
}
