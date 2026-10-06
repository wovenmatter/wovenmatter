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

    public static let options = ["ask", "allow", "deny"]
    public static let metadata: [String: SessionOptionMetadata] = [
        "ask": .init(name: "Ask for approval", description: "Use OpenCode’s native ask effect for session actions and resources."),
        "allow": .init(name: "Full access", description: "Use OpenCode’s native allow effect for session actions and resources. Required input forms remain interactive."),
        "deny": .init(name: "Deny", description: "Use OpenCode’s native deny effect for session actions and resources.")
    ]

    public static func validate(_ value: String) throws -> String {
        guard options.contains(value) else {
            throw OpenCodeError.message("Choose a native OpenCode allow, ask, or deny policy.")
        }
        return value
    }

    /// The last wildcard rule defines this projection. Keep arbitrary native
    /// rules unchanged and unknown rather than claiming an invented mode.
    public static func nativeMode(session: OpenCodeValue) -> String? {
        guard let rule = session["permissions"].array.last,
              rule["action"].string == "*", rule["resource"].string == "*",
              let effect = rule["effect"].string, options.contains(effect) else { return nil }
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
}
