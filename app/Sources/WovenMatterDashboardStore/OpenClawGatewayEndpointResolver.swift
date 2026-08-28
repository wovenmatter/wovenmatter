import Foundation
import WovenMatterCore

public enum OpenClawGatewayEndpointResolutionError: LocalizedError, Equatable, Sendable {
  case openClawRequired

  public var errorDescription: String? {
    switch self {
    case .openClawRequired: "Direct Gateway linking is available only for OpenClaw agents."
    }
  }
}

/// Location-specific URL construction lives here; Gateway framing and
/// capability negotiation stay in the shared native client.
public enum OpenClawGatewayEndpointResolver {
  public static func localAgentWorkspace(
    port: Int = 18_789
  ) -> OpenClawGatewayEndpoint {
    OpenClawGatewayEndpoint(
      url: URL(string: "ws://127.0.0.1:\(port)")!,
      authorization: .localService
    )
  }

}
