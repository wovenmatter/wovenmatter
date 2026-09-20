import Foundation
import WovenMatterCore

/// The gateway enforces these policies, including active-run downgrade handling.
/// Never emulate a permission mode by answering pending approval requests.
public enum OpenClawSessionPermissions {
    public static let options = ["default", "read-only", "guarded", "workspace", "full"]
    public static let metadata: [String: SessionOptionMetadata] = [
        "default": .init(name: "Default", description: "Use the gateway's inherited permission policy."),
        "read-only": .init(name: "Read only", description: "Read session files; block edits and command execution."),
        "guarded": .init(name: "Guarded", description: "Use the session workspace with native allowlists and approval prompts."),
        "workspace": .init(name: "Workspace", description: "Use the session workspace with native command review and approval when needed."),
        "full": .init(name: "Full access", description: "Allow unrestricted files and commands within the gateway's host policy.")
    ]

    static func patchParameters(key: String, preferences: OpenClawSessionPreferences) throws -> GatewayJSONValue {
        var params: [String: GatewayJSONValue] = ["key": .string(key)]
        if let model = preferences.model { params["model"] = .string(model) }
        if let thinking = preferences.thinkingLevel { params["thinkingLevel"] = .string(thinking) }
        if let permission = preferences.permissionMode {
            guard options.contains(permission) else {
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
