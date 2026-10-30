import Foundation
import WovenMatterCore

/// Same-user SSH writes only a short-lived, nonsecret intent. The receiving app
/// owns role transitions, write flushing and pairing credentials.
public struct CompanionMacSetupRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case pair, update }
    public static let preferenceKey = "wovenmatter.device-setup.request"
    public static let statusKey = "wovenmatter.device-setup.status"
    public let id: UUID
    public let action: Action
    public let endpoint: URL?
    public let expiresAt: TimeInterval
    public init(action: Action, endpoint: URL? = nil, now: Date = Date()) {
        id = UUID(); self.action = action; self.endpoint = endpoint; expiresAt = now.addingTimeInterval(900).timeIntervalSince1970
    }
    public func validate(now: Date = Date()) throws {
        // Allow a small clock difference between Macs; the intent still expires.
        guard expiresAt > now.timeIntervalSince1970, expiresAt <= now.addingTimeInterval(1200).timeIntervalSince1970,
              (action == .update ? endpoint == nil : endpoint.map(CompanionPairingPayload.isValidEndpoint) == true) else {
            throw CompanionAPIError(code: "invalid_setup", message: "This device setup request is invalid or expired. Try pairing again.")
        }
    }
    public func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
    @MainActor public static func clearIfCurrent(_ raw: String, defaults: UserDefaults) {
        if defaults.string(forKey: preferenceKey) == raw { defaults.removeObject(forKey: preferenceKey) }
    }
}

public struct CompanionMacSetupStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case preparing, submitting, waiting, paired, failed }
    public let requestID: UUID
    public let phase: Phase
    public let message: String
    public init(requestID: UUID, phase: Phase, message: String) {
        self.requestID = requestID; self.phase = phase; self.message = message
    }
    public func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}
