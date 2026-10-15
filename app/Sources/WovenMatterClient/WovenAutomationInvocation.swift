import Foundation
import WovenMatterCore

public struct WovenAutomationInvocation: Codable, Sendable {
    public let callerID: String
    public let request: WovenMatterToolRequest
    public let admitted: Bool
    public init(callerID: String, request: WovenMatterToolRequest, admitted: Bool) {
        self.callerID = callerID; self.request = request; self.admitted = admitted
    }
}
