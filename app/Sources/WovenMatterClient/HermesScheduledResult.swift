import Foundation

public struct HermesScheduledResult: Codable, Identifiable, Sendable {
  public let jobID: String
  public let runID: String
  public let output: String
  public let savedAt: Double
  public var id: String { jobID + ":" + runID }
  public init(jobID: String, runID: String, output: String, savedAt: Double) {
    self.jobID = jobID
    self.runID = runID
    self.output = output
    self.savedAt = savedAt
  }
}
