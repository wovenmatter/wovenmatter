import Foundation
import WovenMatterCore

public struct HermesSessionImport: Sendable {
    public let identity: String
    public let title: String
    public let createdAt: Date
    public let messages: [HermesValue]
    public let nativeSnapshot: HermesValue?
    public let nativeSnapshotData: Data?
    public init(identity: String, title: String, createdAt: Date, messages: [HermesValue], nativeSnapshot: HermesValue? = nil,
                nativeSnapshotData: Data? = nil) {
        self.identity = identity; self.title = title; self.createdAt = createdAt; self.messages = messages
        self.nativeSnapshot = nativeSnapshot
        self.nativeSnapshotData = nativeSnapshotData
    }

    public func nativeArchiveBatch() throws -> WorkspaceNativeRunRecordBatch {
        let parsed = HermesSessionArchive.parseIdentity(identity)
        var records = try messages.map { row in
            let bytes = try NativeHarnessArchive.encode(row)
            let id = row["id"].number.flatMap { Int64(exactly: $0) }.map(String.init) ?? NativeHarnessArchive.digest(bytes)
            return NativeHarnessArchive.record(id: "message:" + id, kind: "message", data: bytes, completeness: "native-export")
        }
        if let nativeSnapshot {
            records.append(NativeHarnessArchive.record(id: "session.export", kind: "session",
                data: try nativeSnapshotData ?? NativeHarnessArchive.encode(nativeSnapshot), completeness: "native-export"))
        }
        return WorkspaceNativeRunRecordBatch(sourceID: "hermes:" + (parsed.home ?? "unresolved-profile"),
            nativeSessionID: parsed.storedID, records: records)
    }
}



/// Extraction helpers for archived Hermes records retained in Woven history.
public enum HermesSessionArchive {
    public static func identity(home: String, storedID: String, imported: Bool = false) -> String {
        (imported ? "hermes-import:" : "hermes-gateway:") + Data(home.utf8).base64EncodedString() + ":" + storedID
    }
    public static func parseIdentity(_ value: String) -> (home: String?, storedID: String) {
        guard value.hasPrefix("hermes-gateway:") || value.hasPrefix("hermes-import:") else { return (nil, value) }
        let pieces = value.split(separator: ":", maxSplits: 2).map(String.init)
        guard pieces.count == 3, let bytes = Data(base64Encoded: pieces[1]),
              let home = String(data: bytes, encoding: .utf8), home.hasPrefix("/"), !pieces[2].isEmpty else { return (nil, "") }
        return (home, pieces[2])
    }

    public static func checklistUpdate(_ payload: HermesValue) -> AgentRunActivity? {
        guard ["todo_list", "todo"].contains(payload["name"].text),
              case .array = payload["args"]["todos"],
              payload["result"]["error"].isNull,
              let revision = payload["result"]["revision"].number,
              revision.isFinite, revision >= 1, revision.rounded() == revision,
              case .array(let todos) = payload["result"]["todos"] else { return nil }
        var seen: Set<String> = []
        var entries: [AgentRunPlanEntry] = []
        for todo in todos {
            guard let id = todo["id"].string, !id.isEmpty, seen.insert(id).inserted,
                  let content = todo["content"].string, !content.isEmpty,
                  let status = todo["status"].string, !status.isEmpty else { return nil }
            entries.append(AgentRunPlanEntry(content: content, status: status, nativeID: id))
        }
        return AgentRunActivity(id: "hermes-checklist", kind: .plan,
            phase: entries.isEmpty ? "clear" : "update", title: "Plan",
            planEntries: entries, rawInputJSON: payload["args"].json,
            rawOutputJSON: payload["result"].json, planKind: "checklist",
            planOperation: entries.isEmpty ? "clear" : "replace")
    }

}
