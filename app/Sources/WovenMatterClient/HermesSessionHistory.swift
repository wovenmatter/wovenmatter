import Foundation
import WovenMatterCore

/// Extraction helpers for archived Hermes records retained in Woven history.
public enum HermesSessionArchive {
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
