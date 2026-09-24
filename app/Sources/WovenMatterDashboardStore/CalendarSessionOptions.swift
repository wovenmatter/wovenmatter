import Foundation
import WovenMatterCore
import WovenMatterClient

/// Reads native session options without sending a prompt or inserting a local
/// conversation. Some harnesses expose their catalog through an empty session.
public enum CalendarSessionOptions {
  public static func load(launch: LocalACPRuntimeLaunchConfiguration, directory: URL,
                          model: String?) async throws -> LocalACPSessionMetadata {
    let client = try LocalACPSessionDriver.start(launch: launch, workingDirectory: directory)
    return try await withTaskCancellationHandler {
      let timeout = Task {
        do { try await Task.sleep(for: .seconds(30)); await client.shutdown() }
        catch { }
      }
      defer { timeout.cancel() }
      do {
        var configuration = try await client.initializeSession(directory, nil, nil, nil).configuration
        if let model, model != configuration.model { configuration = try await client.setConfiguration(model, nil) }
        try Task.checkCancellation()
        await client.shutdown()
        return LocalACPSessionMetadata(sessionKey: "calendar", model: configuration.model, thinking: configuration.thinking,
          modelOptions: configuration.modelOptions, thinkingLevels: configuration.thinkingOptions,
          modelOptionMetadata: configuration.modelOptionMetadata, thinkingOptionMetadata: configuration.thinkingOptionMetadata,
          permission: configuration.permission, permissionOptions: configuration.permissionOptions,
          permissionOptionMetadata: configuration.permissionOptionMetadata, workingDirectory: directory.path)
      } catch { await client.shutdown(); throw error }
    } onCancel: { Task { await client.shutdown() } }
  }
}
