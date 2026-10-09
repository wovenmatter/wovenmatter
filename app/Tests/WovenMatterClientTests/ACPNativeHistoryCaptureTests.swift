import Foundation
import Testing
@testable import WovenMatterClient

struct ACPNativeHistoryCaptureTests {
    @Test func archivesCompactionAndNativeUnknownFields() throws {
        let update: ACPJSONValue = .object([
            "sessionUpdate": .string("context_compacted"), "summary": .string("exposed context summary"),
            "nativeContext": .object(["cutoff": .integer(42)]),
        ])
        let record = try ACPNativeHistoryCapture.record(update, runID: "woven-run")
        #expect(record.kind == "acp.context_compacted")
        #expect(record.runID == "woven-run")
        #expect(record.payload.contains("nativeContext"))
        #expect(record.text?.contains("exposed context summary") == true)
        #expect(record.projectionJSON?.contains("exposed context summary") == true)
    }

    @Test func repeatedTextDeltasAreDistinctWithoutNativeEventIdentity() throws {
        let update: ACPJSONValue = .object([
            "sessionUpdate": .string("agent_thought_chunk"),
            "content": .object(["type": .string("text"), "text": .string("same")]),
        ])
        let first = try ACPNativeHistoryCapture.record(update, runID: "run")
        let second = try ACPNativeHistoryCapture.record(update, runID: "run")
        #expect(first.id != second.id)
        #expect(first.contentMode == "delta" && second.contentMode == "delta")
        #expect(first.payload == second.payload)
    }

    @Test func nativeEventsAndToolSnapshotsHaveStableSourceIdentity() throws {
        let tool: ACPJSONValue = .object([
            "sessionUpdate": .string("tool_call_update"), "toolCallId": .string("native-tool"),
            "status": .string("completed"), "rawOutput": .object(["attachment": .string("file:///tmp/result")]),
        ])
        let first = try ACPNativeHistoryCapture.record(tool, runID: "run")
        #expect(first == (try ACPNativeHistoryCapture.record(tool, runID: "run")))
        #expect(first.contentMode == "snapshot")
        guard case .object(var native) = tool else { return }
        native["eventId"] = .string("native-event")
        #expect(try ACPNativeHistoryCapture.record(.object(native), runID: "run").id == "event:native-event")
    }

    @Test func reloadedHistoryUsesRepeatableSessionOrdinals() throws {
        let chunk: ACPJSONValue = .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("retained")]),
        ])
        let first = try ACPNativeHistoryCapture.record(chunk, runID: nil, replayOrdinal: 3)
        #expect(first == (try ACPNativeHistoryCapture.record(chunk, runID: nil, replayOrdinal: 3)))
        #expect(first.id != (try ACPNativeHistoryCapture.record(chunk, runID: nil, replayOrdinal: 4)).id)
        #expect(first.runID == nil)
    }
}
