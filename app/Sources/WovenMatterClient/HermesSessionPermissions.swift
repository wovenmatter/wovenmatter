import Foundation
import WovenMatterCore

public enum HermesProfileApprovalMode: String, CaseIterable, Sendable {
    case manual, smart

    public var displayName: String {
        switch self {
        case .manual: "Ask for approval"
        case .smart: "Smart approvals"
        }
    }
}

/// Native profile-wide approval policy, separate from a conversation's YOLO
/// override. Reads never write a default or change the running session flags.
public enum HermesProfileApprovals {
    public static func read(connection: HermesGatewayConnection) async throws -> String {
        try await read(connection: connection, transport: HermesGatewayRPC(connection: connection))
    }

    public static func set(_ mode: HermesProfileApprovalMode, connection: HermesGatewayConnection) async throws -> String {
        try await set(mode, connection: connection, transport: HermesGatewayRPC(connection: connection))
    }

    static func read(connection: HermesGatewayConnection, transport: any HermesGatewayTransport) async throws -> String {
        try await perform(connection: connection, transport: transport, mode: nil)
    }

    static func set(_ mode: HermesProfileApprovalMode, connection: HermesGatewayConnection,
                    transport: any HermesGatewayTransport) async throws -> String {
        try await perform(connection: connection, transport: transport, mode: mode)
    }

    private static func perform(connection: HermesGatewayConnection, transport: any HermesGatewayTransport,
                                mode: HermesProfileApprovalMode?) async throws -> String {
        do {
            try await transport.connect()
            let profile = try await transport.call("config.get", ["key": "profile"])
            guard connection.home.hasPrefix("/"), let reportedHome = profile["home"].string,
                  reportedHome.hasPrefix("/"),
                  URL(fileURLWithPath: reportedHome).standardizedFileURL.path
                    == URL(fileURLWithPath: connection.home).standardizedFileURL.path else {
                throw HermesGatewayError.message("Hermes Gateway belongs to a different profile. Its approval policy has not been changed.")
            }
            // Native params.profile takes a profile NAME. Omitting it selects
            // the launch home just verified above, including through a remote
            // workspace proxy. identityHome is a Woven key, never a native path.
            try Task.checkCancellation()
            if let mode {
                let response = try await transport.call("config.set", [
                    "key": "approvals.mode", "value": .string(mode.rawValue), "scope": "global"
                ])
                guard !response["confirm_required"].bool, response["value"].string == mode.rawValue else {
                    throw HermesGatewayError.message("Hermes did not acknowledge the profile approval policy. Refresh its settings before trying again.")
                }
            }
            let response = try await transport.call("config.get", ["key": "approvals.mode"])
            guard let actual = response["value"].string, ["manual", "smart", "off"].contains(actual) else {
                throw HermesGatewayError.message("Hermes did not report a supported profile approval policy.")
            }
            if let mode, actual != mode.rawValue {
                throw HermesGatewayError.message("Hermes still reports a different profile approval policy. A managed policy may override this setting; refresh before trying again.")
            }
            try Task.checkCancellation()
            await transport.disconnect()
            return actual
        } catch {
            await transport.disconnect()
            throw error
        }
    }
}

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
        let inheritedDescription = mode == "smart"
            ? "Restore this profile's Smart approvals from Settings. Hermes evaluates requests and asks when needed."
            : "Restore this profile's approval policy from Settings for this conversation."
        return LocalACPSessionConfiguration(model: nil, thinking: nil, modelOptions: [], thinkingOptions: [],
            permission: current,
            permissionOptions: inheritedFull ? ["full"] : ["default", "full"],
            permissionOptionMetadata: [
                "default": .init(name: "Ask for approval", description: inheritedDescription),
                "full": .init(name: "Full access", description: inheritedFull
                    ? "Full access is enabled by the Hermes profile or process policy."
                    : "Enable Hermes full access for this conversation only.")
            ])
    }
}
