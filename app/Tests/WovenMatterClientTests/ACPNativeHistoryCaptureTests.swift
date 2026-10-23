import Foundation
import Testing
@testable import WovenMatterClient

struct ACPNativeHistoryCaptureTests {
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

}
