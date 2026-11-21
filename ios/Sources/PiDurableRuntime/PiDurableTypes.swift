import Foundation

/// What a host tells the runtime when it opens a conversation.
public struct PiDurableStart: Sendable {
  /// The conversation, and the name of its directory under the runtime's.
  public var conversationID: String
  /// Continue the conversation's saved log, or start a new one. Opening a missing log to
  /// continue throws `PiDurableError.conversationGone`; a fresh one is never started in its place.
  public var resume: Bool
  /// The pi-ai model descriptor (`InferenceModel.descriptorJSON()`).
  public var modelJSON: String
  /// A level the model supports, or "off".
  public var thinkingLevel: String
  public var instructions: String
  public var tools: [PiToolDefinition]

  public init(conversationID: String, resume: Bool, modelJSON: String, thinkingLevel: String = "off",
              instructions: String = "", tools: [PiToolDefinition] = []) {
    self.conversationID = conversationID
    self.resume = resume
    self.modelJSON = modelJSON
    self.thinkingLevel = thinkingLevel
    self.instructions = instructions
    self.tools = tools
  }
}

/// A tool the model may call. The host's tool executor runs it, except `askUser`, which the
/// runtime answers with a `.prompt` the person replies to.
public struct PiToolDefinition: Sendable, Hashable {
  public var name: String
  public var description: String
  /// A JSON Schema object, as JSON text.
  public var parameters: String
  /// The call may run again when a relaunch cut it short; otherwise the model is told it was interrupted.
  public var replaySafe: Bool
  var question = false

  public init(name: String, description: String, parameters: String, replaySafe: Bool = false) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.replaySafe = replaySafe
  }

  /// Asks the person a question and waits for the answer.
  public static let askUser: PiToolDefinition = {
    var tool = PiToolDefinition(name: "ask_user", description: "Ask the person a question and wait for their answer.",
                                parameters: #"{"type":"object","properties":{"question":{"type":"string"}},"required":["question"]}"#)
    tool.question = true
    return tool
  }()

  /// The definition as the JavaScript side takes it.
  func descriptor() throws -> [String: Any] {
    guard let schema = try? JSONSerialization.jsonObject(with: Data(parameters.utf8)) as? [String: Any] else {
      throw PiDurableError.failed("The parameters of \(name) are not a JSON Schema object.")
    }
    return ["name": name, "description": description, "parameters": schema, "replaySafe": replaySafe, "question": question]
  }
}

/// One call the model made to a host tool.
public struct PiToolRequest: Sendable, Hashable {
  public var callID: String
  public var name: String
  /// The arguments, as JSON object text.
  public var arguments: String
}

/// What a host tool answers. A thrown error is the model's error result too.
public struct PiToolResult: Sendable, Hashable {
  public var output: String
  public var isError: Bool

  public init(output: String, isError: Bool = false) {
    self.output = output
    self.isError = isError
  }
}

/// Tokens one turn used, by kind, as the SDK counts them.
public struct PiTokenUsage: Sendable, Hashable {
  /// `provider/model` of the turn's answer.
  public var model: String?
  public var input: Int64
  public var output: Int64
  public var cacheRead: Int64
  public var cacheWrite: Int64
}

/// What a conversation says, in order, on one stream for as long as it is open. Each finished
/// item arrives once, after everything before it and before anything after it, so a host saves
/// items as they finish. A turn the runtime resumes on open (a relaunch cut one short) has no
/// `userMessage`; its first event begins it, and it ends with `turnFinished` like any other.
public enum PiDurableEvent: Sendable, Hashable {
  /// A message the person sent: the start of a turn, or one that steered it.
  case userMessage(text: String)
  /// More text of the assistant message in progress (one starts if none is).
  case text(String)
  /// The assistant message in progress is complete.
  case messageFinished(text: String)
  /// More of the model's reasoning; the first delta for `id` starts it.
  case thinking(id: String, delta: String)
  case thinkingFinished(id: String, text: String)
  case toolStarted(callID: String, name: String, input: String)
  case toolFinished(callID: String, name: String, input: String, output: String, failed: Bool)
  /// `ask_user` waits for `answer(promptID:text:)`.
  case prompt(id: String, question: String)
  /// The question was answered or withdrawn.
  case promptResolved(id: String)
  /// The turn ended; `failure` says why when it failed. An interrupted turn did not fail.
  case turnFinished(failure: String?, usage: PiTokenUsage?)
}

public enum PiDurableError: Error, LocalizedError, Sendable, Equatable {
  /// The conversation's log is not in the runtime's directory.
  case conversationGone
  /// The conversation is open in another session.
  case inUse
  case closed
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .conversationGone: "This conversation is no longer on this device."
    case .inUse: "This conversation is already open."
    case .closed: "This conversation has been closed."
    case .failed(let message): message
    }
  }
}
