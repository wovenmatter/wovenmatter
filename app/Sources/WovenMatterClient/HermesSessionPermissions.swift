import WovenMatterCore

/// Hermes supports inherited manual/smart approvals and a per-session full-access
/// override. Its global "off" and process YOLO settings cannot be lowered here.
enum HermesSessionPermissions {
    static func configuration(info: HermesValue, inheritedMode: String?, downgradeUnavailable: Bool = false) -> LocalACPSessionConfiguration {
        let mode = info["approval_mode"].string ?? inheritedMode
        let inheritedFull = mode == "off" || downgradeUnavailable
        let current: String?
        if info["yolo"] == .bool(true) || mode == "off" { current = "full" }
        else if info["yolo"] == .bool(false) { current = "default" }
        else { current = nil }
        let inheritedName = mode == "smart" ? "Smart approvals" : mode == "manual" ? "Manual approvals" : "Inherited approvals"
        return LocalACPSessionConfiguration(model: nil, thinking: nil, modelOptions: [], thinkingOptions: [],
            permission: current,
            permissionOptions: inheritedFull ? ["full"] : ["default", "full"],
            permissionOptionMetadata: [
                "default": .init(name: inheritedName, description: "Use the Hermes profile's approval policy for this conversation."),
                "full": .init(name: "Full access", description: inheritedFull
                    ? "Full access is enabled by the Hermes profile or process policy."
                    : "Enable Hermes full access for this conversation only.")
            ])
    }
}
