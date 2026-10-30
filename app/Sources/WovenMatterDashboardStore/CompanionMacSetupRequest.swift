import Foundation
import WovenMatterCore

/// Same-user SSH writes only a short-lived, nonsecret intent. The receiving app
/// owns role transitions, write flushing and pairing credentials.
public struct CompanionMacSetupRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case pair, update }
    public static let preferenceKey = "wovenmatter.device-setup.request"
    public static let statusKey = "wovenmatter.device-setup.status"
    public let action: Action
    public let endpoint: URL?
    public let expiresAt: TimeInterval
    public init(action: Action, endpoint: URL? = nil, now: Date = Date()) {
        self.action = action; self.endpoint = endpoint; expiresAt = now.addingTimeInterval(900).timeIntervalSince1970
    }
    public func validate(now: Date = Date()) throws {
        guard expiresAt > now.timeIntervalSince1970, expiresAt <= now.addingTimeInterval(901).timeIntervalSince1970,
              (action == .update ? endpoint == nil : endpoint.map(CompanionPairingPayload.isValidEndpoint) == true) else {
            throw CompanionAPIError(code: "invalid_setup", message: "This device setup request is invalid or expired. Try pairing again.")
        }
    }
    public func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}
