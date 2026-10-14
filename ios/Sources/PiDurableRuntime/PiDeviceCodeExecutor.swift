import Foundation

/// Native host entry point for durable Executor jobs using the same isolated
/// worker and tool bridge as Pi code mode, without invoking an inference model.
@MainActor public enum PiDeviceCodeExecutor {
  public static func run(requestJSON: String, policy: PiExecutionPolicy = .init(),
    checkpoint: @escaping @MainActor (String) async throws -> Void,
    tool: @escaping @MainActor (String, String) async throws -> String) async throws -> String {
    try await PiCodeModeExecutor().run(requestJSON: requestJSON, policy: policy, checkpoint: checkpoint, tool: tool)
  }
}
