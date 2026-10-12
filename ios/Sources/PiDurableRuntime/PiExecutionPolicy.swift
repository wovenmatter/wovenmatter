import Foundation

/// Resource controls for generated programs. There is deliberately no total wall-clock
/// deadline: waiting for a provider, native tool, child or approval is not CPU work.
public struct PiExecutionPolicy: Codable, Equatable, Sendable {
  public var unresponsiveCodeSeconds: Double
  public var concurrentTools: Int
  public var concurrentSubagents: Int
  public var subagentDepth: Int

  public init(unresponsiveCodeSeconds: Double = 30, concurrentTools: Int = 16,
              concurrentSubagents: Int = 4, subagentDepth: Int = 2) {
    self.unresponsiveCodeSeconds = unresponsiveCodeSeconds
    self.concurrentTools = concurrentTools
    self.concurrentSubagents = concurrentSubagents
    self.subagentDepth = subagentDepth
  }

  public func validated() throws -> Self {
    guard unresponsiveCodeSeconds.isFinite, (1...300).contains(unresponsiveCodeSeconds),
          (1...64).contains(concurrentTools), (1...16).contains(concurrentSubagents),
          (1...4).contains(subagentDepth) else {
      throw PiDurableRuntimeError.unavailable("Invalid execution resource settings.")
    }
    var fixed = self
    fixed.subagentDepth = 2 // Root plus one child level; never grandchildren.
    return fixed
  }
}
