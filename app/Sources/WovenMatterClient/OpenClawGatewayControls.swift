import Foundation

/// A reviewer snapshot belongs to one enrolled Gateway and connection generation.
/// Callers must refresh it after relinking, and must not replay uncertain writes.
public struct OpenClawGatewayControls: Sendable {
  public let agentID: UUID
  public let generation: UUID
  public let conversationID: String
  public let sessionKey: String
  public let approvals: [GatewayJSONValue]
  public let questions: [GatewayJSONValue]
  public let approvalsTruncated: Bool
  public let controlUIURL: URL?

  public init(agentID: UUID, generation: UUID, conversationID: String, sessionKey: String,
              approvals: [GatewayJSONValue], questions: [GatewayJSONValue],
              approvalsTruncated: Bool, controlUIURL: URL?) {
    self.agentID = agentID; self.generation = generation
    self.conversationID = conversationID; self.sessionKey = sessionKey
    self.approvals = approvals; self.questions = questions
    self.approvalsTruncated = approvalsTruncated; self.controlUIURL = controlUIURL
  }

  /// Never carry Gateway credentials or arbitrary URL schemes into a browser.
  public static func safeControlUIURL(_ url: URL?) -> URL? {
    guard let url, ["https", "http"].contains(url.scheme?.lowercased()),
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.host != nil else { return nil }
    return url
  }
}
