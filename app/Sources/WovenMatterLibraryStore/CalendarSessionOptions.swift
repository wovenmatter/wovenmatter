import Foundation
import WovenMatterCore
import WovenMatterClient

/// Reads native session options without sending a prompt or inserting a local
/// conversation. Some harnesses expose their catalog through an empty session.
public enum CalendarSessionOptions {
  /// A Linux host's options for a harness before a session exists
  /// (`GET v1/execution/providers/<id>/options`), as the editors read them:
  /// each choice's label and description go in its metadata.
  public static func metadata(from settings: SessionSettings, directory: String?) -> LocalACPSessionMetadata {
    func metadata(_ options: [SessionSettingOption]) -> [String: SessionOptionMetadata] {
      Dictionary(options.map { ($0.id, SessionOptionMetadata(name: $0.label, description: $0.description)) }) { first, _ in first }
    }
    return LocalACPSessionMetadata(sessionKey: "calendar", model: settings.model, thinking: settings.thinking,
      modelOptions: settings.models.map(\.id), thinkingLevels: settings.thinkingLevels.map(\.id),
      modelOptionMetadata: metadata(settings.models), thinkingOptionMetadata: metadata(settings.thinkingLevels),
      permission: settings.permission, permissionOptions: settings.permissions.map(\.id),
      permissionOptionMetadata: metadata(settings.permissions), workingDirectory: directory)
  }

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
