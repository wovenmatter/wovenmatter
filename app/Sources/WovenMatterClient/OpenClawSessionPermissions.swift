import Foundation
import WovenMatterCore

/// The gateway enforces these policies, including active-run downgrade handling.
/// Never emulate a permission mode by answering pending approval requests.
public enum OpenClawSessionPermissions {
    public static let options = ["guarded", "workspace", "full"]
    // Existing sessions may still inherit a policy or be read-only. Keep those
    // values readable/restorable without adding unrelated modes to the picker.
    private static let supportedPolicies = options + ["default", "read-only"]
    public static let metadata: [String: SessionOptionMetadata] = [
        "default": .init(name: "Default", description: "Use the gateway's inherited permission policy."),
        "read-only": .init(name: "Read only", description: "Read session files; block edits and command execution."),
        "guarded": .init(name: "Ask for approval", description: "Use the session workspace; ask before commands outside the native allowlist."),
        "workspace": .init(name: "Auto", description: "OpenClaw reviews commands automatically and asks when approval is needed. File access stays within the session workspace."),
        "full": .init(name: "Full access", description: "Allow unrestricted files and commands within the gateway's host policy.")
    ]

    static func patchParameters(key: String, preferences: OpenClawSessionPreferences) throws -> GatewayJSONValue {
        var params: [String: GatewayJSONValue] = ["key": .string(key)]
        if let model = preferences.model { params["model"] = .string(model) }
        if let thinking = preferences.thinkingLevel { params["thinkingLevel"] = .string(thinking) }
        if let permission = preferences.permissionMode {
            guard supportedPolicies.contains(permission) else {
                throw OpenClawGatewayClientError.rejected("This OpenClaw permission mode is not supported.")
            }
            params["permissionMode"] = permission == "default" ? .null : .string(permission)
        }
        return .object(params)
    }

    static func confirm(_ expected: String?, description: GatewayJSONValue) throws {
        guard let expected else { return }
        let session = description.objectValue?["session"]?.objectValue
        guard let session, (session["permissionMode"]?.stringValue ?? "default") == expected,
              session["permissionModePending"] != .bool(true) else {
            throw OpenClawGatewayClientError.rejected("OpenClaw has not confirmed this permission change. Stop the current run and try again.")
        }
    }
}
