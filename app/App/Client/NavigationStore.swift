import Foundation
import Observation

/// Navigation intents one view leaves for another: which settings page or scope to open, composer text to prefill, a library item to send into a chat. UI only.
@MainActor
@Observable
final class NavigationStore {
    /// Open Settings on Subscriptions & API Keys for this machine id (or a
    /// named page such as "permissions"); the settings view clears it.
    var pendingConnectionsScope: String?
    /// Open Settings on Pi Durable, at this scope.
    var pendingDefaultAgentSettingsScope: String?
    /// The provider to select when Pi Durable settings open.
    var pendingDefaultAgentModelProvider: String?
    /// Open Settings on Bots.
    var pendingBotsSettings = false
    /// Open the bot profiles of the bots on this machine.
    var pendingBotProfilesMachine: String?
    /// Composer text to place in a session's composer when it next opens, by session id.
    var pendingComposerPrefills: [String: String] = [:]
    /// A library item chosen to send into the chat it came from.
    var libraryMessageTarget: WorkspaceLibraryItem?

    init() {}
}
