import Foundation
import WovenMatterCore

/// Mirrors the native OpenCode TUI's normal/auto request handling. These are
/// client approval choices, not replacements for the server's deny rules.
public enum OpenCodePermissionHandling {
    public static let options = ["normal", "auto"]
    public static let metadata: [String: SessionOptionMetadata] = [
        "normal": .init(name: "Normal approvals", description: "Show requests that OpenCode asks you to approve."),
        "auto": .init(name: "Auto-approve requests", description: "While connected, approve this conversation's tool requests once. Native deny rules remain enforced.")
    ]

    public static func validate(_ value: String) throws -> String {
        guard options.contains(value) else {
            throw OpenCodeError.message("Choose Normal approvals or Auto-approve requests for OpenCode.")
        }
        return value
    }

    /// Only requests from the session permission endpoint are candidates. Keep
    /// malformed records, authentication, and interactive form steps manual.
    public static func requestID(_ request: OpenCodeValue, sessionID: String) -> String? {
        guard request["sessionID"].string == sessionID,
              let id = request["id"].string, id.hasPrefix("per"),
              let action = request["action"].string, !action.isEmpty,
              case .array(let resources) = request["resources"],
              resources.allSatisfy({ $0.string != nil }),
              request["effect"].string != "deny" else { return nil }
        let category = action.lowercased().split(whereSeparator: { ".:/_-".contains($0) }).first.map(String.init) ?? ""
        guard !["auth", "authenticate", "authentication", "login", "oauth", "credential", "credentials", "secret", "secrets", "form"].contains(category),
              request["type"].isNull || request["type"].string == "permission",
              request["source"]["type"].isNull || request["source"]["type"].string == "tool" else { return nil }
        return id
    }
}
