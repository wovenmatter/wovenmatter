import Foundation
import WovenMatterCore

/// ACP load/update notifications are the adapter's supported history interface.
/// Retain every exposed update, including kinds absent from the UI projection.
enum ACPNativeHistoryCapture {
    static func record(_ update: ACPJSONValue, runID: String?, replayOrdinal: Int? = nil) throws -> WorkspaceNativeRunRecord {
        let kind = update["sessionUpdate"]?.stringValue ?? "update"
        let data = try NativeHarnessArchive.encode(update)
        let nativeEventID = update["eventId"]?.stringValue
            ?? update["_meta"]?["eventId"]?.stringValue
            ?? update["_meta"]?["eventID"]?.stringValue
        let toolID = update["toolCallId"]?.stringValue
        let isToolSnapshot = ["tool_call", "tool_call_update"].contains(kind) && toolID != nil
        let isDelta = ["agent_message_chunk", "agent_thought_chunk", "user_message_chunk"].contains(kind)
        // Delta chunks without a native event ID are separate observations, even
        // when their text is identical. A content hash cannot identify a delta.
        let id = nativeEventID.map { "event:" + $0 }
            ?? (isToolSnapshot ? "tool:\(toolID!)" : replayOrdinal.map { "replay:\($0)" }
                ?? "observed:" + UUID().uuidString.lowercased())
        var record = NativeHarnessArchive.record(id: id, kind: "acp." + kind, data: data,
            contentMode: isDelta ? "delta" : isToolSnapshot ? "snapshot" : "event")
        record.runID = runID
        record.projectionJSON = String(decoding: try NativeHarnessArchive.encode([
            "kind": ACPJSONValue.string(kind),
            "content": update["content"] ?? .null,
            "summary": update["summary"] ?? .null,
            "rawInput": update["rawInput"] ?? .null,
            "rawOutput": update["rawOutput"] ?? .null,
        ]), as: UTF8.self)
        return record
    }
}
