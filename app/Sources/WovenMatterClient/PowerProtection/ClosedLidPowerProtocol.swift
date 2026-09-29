import Foundation
import Security

@objc protocol ClosedLidPowerProtocol {
    /// No paths, commands, or arbitrary settings cross this privilege boundary.
    func renew(externalPower: Bool, batteryPower: Bool,
               reply: @escaping @Sendable (Bool, String?) -> Void)
}

enum ClosedLidHelperIdentity {
    static let service = "wovenmatter.desktop.power-helper"
    static let plistName = service + ".plist"

    static func signingTeam() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            throw ClosedLidPowerError.unavailable("Closed-lid protection requires a signed Woven Matter build.")
        }
        return team
    }

    static func requirement(team: String, identifiers: [String]) throws -> String {
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              !identifiers.isEmpty,
              identifiers.allSatisfy({ $0.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil }) else {
            throw ClosedLidPowerError.unavailable("Invalid power helper signing identity.")
        }
        let names = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(names))"
    }
}

enum ClosedLidPowerError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}
