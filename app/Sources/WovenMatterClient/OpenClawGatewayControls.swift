import Foundation

/// A reviewer snapshot belongs to one enrolled Gateway and connection generation.
/// Callers must refresh it after relinking, and must not replay uncertain writes.
public struct OpenClawGatewayControls: Sendable {
  public let agentID: UUID
  public let generation: UUID
  public let transportGeneration: UUID
  public let conversationID: String
  public let sessionKey: String
  public let approvals: [GatewayJSONValue]
  public let questions: [GatewayJSONValue]
  public let approvalsTruncated: Bool
  public let controlUIURL: URL?

  public init(agentID: UUID, generation: UUID, conversationID: String, sessionKey: String,
              approvals: [GatewayJSONValue], questions: [GatewayJSONValue],
              approvalsTruncated: Bool, controlUIURL: URL?, transportGeneration: UUID = UUID()) {
    self.agentID = agentID; self.generation = generation
    self.conversationID = conversationID; self.sessionKey = sessionKey
    self.approvals = approvals; self.questions = questions
    self.approvalsTruncated = approvalsTruncated; self.controlUIURL = controlUIURL
    self.transportGeneration = transportGeneration
  }

  /// Never carry Gateway credentials or arbitrary URL schemes into a browser.
  public static func safeControlUIURL(_ url: URL?) -> URL? {
    guard let url, ["https", "http"].contains(url.scheme?.lowercased()),
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.host != nil else { return nil }
    return url
  }
}

public enum OpenClawQuestionAnswers {
  public static func resolve(questions: [GatewayJSONValue], selected: [String: [String]], freeText: [String: String]) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for value in questions {
      guard let row = value.objectValue, let id = row["questionId"]?.stringValue else { continue }
      let choices = row["options"]?.arrayValue?.compactMap { $0.objectValue?["label"]?.stringValue } ?? []
      var answers = (selected[id] ?? []).filter(choices.contains)
      let text = (freeText[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty, choices.isEmpty || row["isOther"]?.boolValue == true {
        if row["multiSelect"]?.boolValue != true { answers = [] }
        if !answers.contains(text) { answers.append(text) }
      }
      result[id] = row["multiSelect"]?.boolValue == true ? answers : Array(answers.prefix(1))
    }
    return result
  }
}
