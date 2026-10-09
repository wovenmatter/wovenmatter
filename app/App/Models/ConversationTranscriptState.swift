import Observation
import SwiftUI

/// Disclosure state for one conversation's work transcript and Tasks badge.
///
/// The root owns one instance per conversation and injects it with
/// `.environment(\.conversationTranscriptState, state)`, so expansion survives
/// paging the message window, status updates, and leaving and returning to
/// the chat. Without an instance, views fall back to local state.
@MainActor
@Observable
final class ConversationTranscriptState {
    /// Explicit fold choices for settled runs, keyed by run ID. Absent runs
    /// use the default: folded once completed with a final reply.
    private(set) var runExpansion: [String: Bool] = [:]
    /// Expanded work groups and row details, keyed by `disclosureKey`.
    private(set) var expandedItems: Set<String> = []
    var tasksExpanded = false

    init() {}

    func isRunExpanded(_ runID: String, default defaultValue: Bool) -> Bool {
        runExpansion[runID] ?? defaultValue
    }

    func setRunExpanded(_ runID: String, _ expanded: Bool) {
        runExpansion[runID] = expanded
    }

    func isExpanded(_ key: String) -> Bool {
        expandedItems.contains(key)
    }

    func setExpanded(_ key: String, _ expanded: Bool) {
        if expanded {
            expandedItems.insert(key)
        } else {
            expandedItems.remove(key)
        }
    }

    /// Clears all disclosure state, for example when the conversation changes.
    func reset() {
        runExpansion = [:]
        expandedItems = []
        tasksExpanded = false
    }

    static func disclosureKey(runID: String, itemID: String) -> String {
        "\(runID)\u{1F}\(itemID)"
    }
}

private struct ConversationTranscriptStateKey: EnvironmentKey {
    static let defaultValue: ConversationTranscriptState? = nil
}

extension EnvironmentValues {
    var conversationTranscriptState: ConversationTranscriptState? {
        get { self[ConversationTranscriptStateKey.self] }
        set { self[ConversationTranscriptStateKey.self] = newValue }
    }
}
