import Foundation

/// Resource controls for generated programs. There is deliberately no total wall-clock
/// deadline: waiting for a provider, native tool, child or approval is not CPU work.
public struct PiExecutionPolicy: Codable, Equatable, Sendable {
  public var unresponsiveCodeSeconds: Double
  public var concurrentTools: Int
  public var concurrentSubagents: Int
  public var subagentDepth: Int

  public init(unresponsiveCodeSeconds: Double = 120, concurrentTools: Int = 16,
              concurrentSubagents: Int = 4, subagentDepth: Int = 2) {
    self.unresponsiveCodeSeconds = unresponsiveCodeSeconds
    self.concurrentTools = concurrentTools
    self.concurrentSubagents = concurrentSubagents
    self.subagentDepth = subagentDepth
  }

  private enum CodingKeys: String, CodingKey {
    case unresponsiveCodeSeconds, concurrentTools, concurrentSubagents, subagentDepth
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    // Existing chats and saved defaults may carry the former 30-second watchdog.
    // Keep longer saved budgets, while giving every restored worker at least two minutes.
    self.init(unresponsiveCodeSeconds: max(120, try values.decode(Double.self, forKey: .unresponsiveCodeSeconds)),
              concurrentTools: try values.decode(Int.self, forKey: .concurrentTools),
              concurrentSubagents: try values.decode(Int.self, forKey: .concurrentSubagents),
              subagentDepth: try values.decode(Int.self, forKey: .subagentDepth))
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
