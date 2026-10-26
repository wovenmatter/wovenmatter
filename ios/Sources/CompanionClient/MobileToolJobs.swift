import Foundation
import CryptoKit
import WovenMatterCompanion

public struct MobileToolSubmission: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var sessionID: String
  public var text: String
  public var state: String
  public var submittedAt: Date
  public var error: String?
}
public struct MobileExecutorJob: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var sessionID: String
  public var code: String
  public var state: String
  public var result: String?
  public var error: String?
  public var createdAt: Date
  public var checkpoint: String?
}
extension MobileStore {
  public func reserveToolInvocation(_ request: WovenMatterToolRequest, context: MobileToolContext) throws {
    try Task.checkCancellation()
    let command = try WovenMatterToolCommand(request.arguments)
    try context.authorize(command)
    guard let uuid = UUID(uuidString: request.requestID) else { throw WorkspaceToolError.invalid("Use a UUID request ID.") }
    let key = context.sessionID + ":" + uuid.uuidString.lowercased()
    if let args = state.toolInvocations?[key] { guard args == command.operationArguments else { throw WorkspaceToolError.invalid("This request ID was already used for different arguments.") }; return }
    try transaction { next in var requests = next.toolInvocations ?? [:]; requests[key] = command.operationArguments; next.toolInvocations = requests }
  }
  public func completeLocalToolRun(sessionID: String, requestID: String, status: String, error: String? = nil) throws {
    guard ["completed", "failed", "cancelled"].contains(status) else { throw WorkspaceToolError.invalid("A terminal run status is required.") }
    try transaction { next in
      var outcome = status
      if var submission = next.toolSubmissions?[requestID] {
        guard submission.sessionID == sessionID else { throw WorkspaceToolError.invalid("The submission belongs to another session.") }
        if ["completed", "failed", "cancelled"].contains(submission.state) { outcome = submission.state }
        else { submission.state = status; submission.error = error; next.toolSubmissions?[requestID] = submission }
      }
      guard let relation = next.localToolCoordinations?[sessionID], relation.notifications else { return }
      let bytes = Array(SHA256.hash(data: Data(("local-session-notification:" + relation.epoch + ":" + requestID).utf8)).prefix(16))
      let id = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
      var submissions = next.toolSubmissions ?? [:]
      if submissions[id] == nil {
        submissions[id] = .init(id: id, sessionID: relation.coordinatorID,
          text: "Your managed on-device session \(sessionID) is \(outcome). Use woven_sessions_status or woven_history_conversation to inspect its result.", state: "queued", submittedAt: Date())
        next.toolSubmissions = submissions
      }
    }
  }
  public func enqueueToolSubmission(id: String, sessionID: String, text: String) throws -> MobileToolSubmission {
    try Task.checkCancellation()
    if let previous = state.toolSubmissions?[id] {
      guard previous.sessionID == sessionID, previous.text == text else { throw WorkspaceToolError.invalid("This submission ID was already used for different content.") }; return previous
    }
    guard UUID(uuidString: id) != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_048_576 else { throw WorkspaceToolError.invalid("Invalid session submission.") }
    let submission = MobileToolSubmission(id: id, sessionID: sessionID, text: text, state: "queued", submittedAt: Date())
    try transaction { next in var jobs = next.toolSubmissions ?? [:]; jobs[id] = submission; next.toolSubmissions = jobs }
    return submission
  }
  public func toolSubmissions() -> [MobileToolSubmission] { (state.toolSubmissions ?? [:]).values.sorted { $0.submittedAt < $1.submittedAt } }
  public func toolSubmission(requestID: String) -> MobileToolSubmission? { state.toolSubmissions?[requestID] }
  public func updateToolSubmission(id: String, state status: String, error: String? = nil) throws {
    try transaction { next in guard var job = next.toolSubmissions?[id] else { throw WorkspaceToolError.notFound("Unknown submission.") }; if ["completed", "failed", "cancelled"].contains(job.state) { return }; job.state = status; job.error = error; next.toolSubmissions?[id] = job }
  }
  public func createExecutorJob(id: String, sessionID: String, code: String) throws -> MobileExecutorJob {
    try Task.checkCancellation()
    if let job = state.toolExecutorJobs?[id] { guard job.sessionID == sessionID, job.code == code else { throw WorkspaceToolError.invalid("This execution ID was used for different code.") }; return job }
    guard code.utf8.count <= 131_072, UUID(uuidString: id) != nil else { throw WorkspaceToolError.invalid("Executor code must be at most 128 KiB.") }
    let job = MobileExecutorJob(id: id, sessionID: sessionID, code: code, state: "queued", createdAt: Date())
    try transaction { next in var jobs = next.toolExecutorJobs ?? [:]; jobs[id] = job; next.toolExecutorJobs = jobs }
    return job
  }
  public func claimExecutorJobStart(id: String, sessionID: String) throws -> Bool {
    try Task.checkCancellation()
    var claimed = false
    try transaction { next in
      guard var job = next.toolExecutorJobs?[id], job.sessionID == sessionID else { throw WorkspaceToolError.notFound("Unknown execution.") }
      guard job.state == "queued" else { return }
      job.state = "starting"; next.toolExecutorJobs?[id] = job; claimed = true
    }
    return claimed
  }
  public func executorJob(id: String, sessionID: String) throws -> MobileExecutorJob {
    guard let job = state.toolExecutorJobs?[id], job.sessionID == sessionID else { throw WorkspaceToolError.notFound("This execution is not owned by the current session.") }; return job
  }
  public func updateExecutorJob(id: String, state status: String, result: String? = nil, error: String? = nil) throws {
    try transaction { next in guard var job = next.toolExecutorJobs?[id] else { throw WorkspaceToolError.notFound("Unknown execution.") }; if ["completed", "cancelled"].contains(job.state) { return }; job.state = status; job.result = result; job.error = error; next.toolExecutorJobs?[id] = job }
  }
  public func saveExecutorCheckpoint(id: String, checkpoint: String) throws {
    guard checkpoint.utf8.count <= 1_048_576 else { throw WorkspaceToolError.invalid("The checkpoint is too large.") }
    try transaction { next in guard var job = next.toolExecutorJobs?[id] else { throw WorkspaceToolError.notFound("Unknown execution.") }; job.checkpoint = checkpoint; next.toolExecutorJobs?[id] = job }
  }
  public func interruptExecutorJobs() throws {
    try transaction { next in for (id, var job) in next.toolExecutorJobs ?? [:] where ["queued", "starting", "running"].contains(job.state) { job.state = "interrupted"; job.error = "The app stopped before this program completed. Inspect tool receipts before starting new work."; next.toolExecutorJobs?[id] = job } }
  }
}
