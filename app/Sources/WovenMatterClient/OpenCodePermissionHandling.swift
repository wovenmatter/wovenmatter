import Foundation
import WovenMatterCore

/// Per-conversation replies to native OpenCode permission requests. These are
/// client approval choices, not smart evaluation or replacements for server rules.
public enum OpenCodePermissionHandling {
    public static let options = ["normal", "acceptEdits", "full"]
    public static let metadata: [String: SessionOptionMetadata] = [
        "normal": .init(name: "Ask for approval", description: "Show requests that OpenCode asks you to approve."),
        "acceptEdits": .init(name: "Auto-accept edits", description: "Allow file edits while connected; ask before other actions that need approval. Native deny rules still apply."),
        "full": .init(name: "Full access", description: "Allow commands and edits without ordinary approval prompts while connected. Native deny rules still apply.")
    ]

    /// Earlier versions called the same blanket request handling `auto`. Keep
    /// its existing authority without confusing it with native smart approval.
    public static func normalized(_ value: String?) -> String {
        if value == "auto" { return "full" }
        return value.flatMap { options.contains($0) ? $0 : nil } ?? "normal"
    }

    public static func validate(_ value: String) throws -> String {
        guard options.contains(value) || value == "auto" else {
            throw OpenCodeError.message("Choose Ask for approval, Auto-accept edits, or Full access for OpenCode.")
        }
        return normalized(value)
    }

    /// Only requests from the session permission endpoint are candidates. Keep
    /// malformed records, authentication, and interactive form steps manual.
    public static func requestID(_ request: OpenCodeValue, sessionID: String, mode: String?) -> String? {
        let mode = normalized(mode)
        guard mode != "normal",
              request["sessionID"].string == sessionID,
              let id = request["id"].string, id.hasPrefix("per"),
              let action = request["action"].string, !action.isEmpty,
              case .array(let resources) = request["resources"],
              resources.allSatisfy({ $0.string != nil }),
              request["effect"].string != "deny" else { return nil }
        let category = action.lowercased().split(whereSeparator: { ".:/_-".contains($0) }).first.map(String.init) ?? ""
        guard !["auth", "authenticate", "authentication", "login", "oauth", "credential", "credentials", "secret", "secrets", "form", "question", "questions", "ask", "askuser", "userinput"].contains(category),
              request["type"].isNull || request["type"].string == "permission",
              request["source"]["type"].isNull || request["source"]["type"].string == "tool" else { return nil }
        // Native edit tools request action `edit`. Names such as write, patch,
        // bash, or edit.file are not evidence of that native permission action.
        guard mode == "full" || action == "edit" else { return nil }
        return id
    }
}
