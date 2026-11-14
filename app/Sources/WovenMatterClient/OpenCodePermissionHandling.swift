import Foundation
import WovenMatterCore

/// OpenCode v2 session permission rules use its native allow/ask/deny effects.
public enum OpenCodePermissionHandling {
    /// Denial and dismissal may still settle native requests after Stop. All
    /// other permission/form answers can authorize work and require a live turn.
    public static func requiresActiveTurn(method: String, suffix: String, body: OpenCodeValue?) -> Bool {
        guard method == "POST", suffix.hasSuffix("/reply") else { return false }
        if suffix.hasPrefix("/permission/") { return body?["reply"].string != "reject" }
        return suffix.hasPrefix("/form/")
    }

    /// OpenCode's native wildcard effects. Ask and Deny remain recognizable so
    /// an older session's rule can be replaced, but only Full access is offered.
    static let nativeEffects = ["ask", "allow", "deny"]
    public static let options = AgentRuntimeKind.opencode.orderedPermissionOptions(nativeEffects)
    public static let metadata: [String: SessionOptionMetadata] = [
        "allow": .init(name: "Full access", description: "Use OpenCode’s native allow effect for session actions and resources. Required input forms remain interactive.")
    ]

    public static func validate(_ value: String) throws -> String {
        guard options.contains(value) else {
            throw OpenCodeError.message("Choose OpenCode’s Full access policy.")
        }
        return value
    }

    /// The last wildcard rule defines this projection. Keep arbitrary native
    /// rules unchanged and unknown rather than claiming an invented mode. An
    /// older session may still report Ask or Deny here.
    public static func nativeMode(session: OpenCodeValue) -> String? {
        guard let rule = session["permissions"].array.last,
              rule["action"].string == "*", rule["resource"].string == "*",
              let effect = rule["effect"].string, nativeEffects.contains(effect) else { return nil }
        return effect
    }

    public static func selectingNativePolicy(_ effect: String, session: OpenCodeValue) throws -> OpenCodeValue {
        guard options.contains(effect) else { throw OpenCodeError.message("Unsupported native OpenCode permission effect.") }
        var rules = session["permissions"].array
        let rule: OpenCodeValue = ["action": "*", "resource": "*", "effect": .string(effect)]
        if nativeMode(session: session) != nil { rules[rules.count - 1] = rule }
        else { rules.append(rule) }
        return ["permissions": .array(rules)]
    }
    /// Mobile can explicitly answer ordinary permission requests. Keep authentication
    /// and interactive forms on the Mac; the native wildcard policy stays authoritative.
    public static func libraryRequestID(_ request: OpenCodeValue, sessionID: String) -> String? {
        guard request["sessionID"].string == sessionID,
              let id = request["id"].string, id.hasPrefix("per"),
              let action = request["action"].string, !action.isEmpty,
              case .array(let resources) = request["resources"],
              resources.allSatisfy({ $0.string != nil }),
              request["effect"].string != "deny" else { return nil }
        let category = action.lowercased().split(whereSeparator: { ".:/_-".contains($0) }).first.map(String.init) ?? ""
        guard !["auth", "authenticate", "authentication", "login", "oauth", "credential", "credentials", "secret", "secrets", "form", "question", "questions", "ask", "askuser", "userinput"].contains(category),
              request["type"].isNull || request["type"].string == "permission",
              request["source"]["type"].isNull || request["source"]["type"].string == "tool" else { return nil }
        return id
    }
}
