import Foundation

public struct ClosedLidPolicy: Codable, Equatable, Sendable {
    public var externalPower: Bool
    public var batteryPower: Bool

    public init(externalPower: Bool = false, batteryPower: Bool = false) {
        self.externalPower = externalPower
        self.batteryPower = batteryPower
    }

    public var isEnabled: Bool { externalPower || batteryPower }

    func permits(_ source: WorkPowerSource) -> Bool {
        switch source {
        case .external: externalPower
        case .battery: batteryPower
        case .unknown: false
        }
    }
}

enum WorkPowerSource { case external, battery, unknown }

public struct ClosedLidProtectionSnapshot: Codable, Equatable, Sendable {
    public var policy: ClosedLidPolicy
    public var isProtecting: Bool
    public var message: String?

    public init(policy: ClosedLidPolicy = .init(), isProtecting: Bool = false, message: String? = nil) {
        self.policy = policy
        self.isProtecting = isProtecting
        self.message = message
    }
}
