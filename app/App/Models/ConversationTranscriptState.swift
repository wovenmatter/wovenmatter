import Observation
import SwiftUI

struct ConversationWorkScrollSnapshot {
    var offset: CGFloat = 0
    var isAtBottom = false
}

/// Disclosure state for one conversation's work transcript and Tasks badge.
///
/// The root owns one instance per conversation and injects it with
/// `.environment(\.conversationTranscriptState, state)`, so expansion survives
/// paging the message window, status updates, and leaving and returning to
/// the chat. Without an instance, views fall back to local state.
@MainActor
@Observable
final class ConversationTranscriptState {
    /// Expanded work groups and row details, keyed by `disclosureKey`.
    private(set) var expandedItems: Set<String> = []
    // Restoration data is consumed on appearance, not during rendering.
    @ObservationIgnored private var workScrollSnapshots: [String: ConversationWorkScrollSnapshot] = [:]
    var tasksExpanded = false

    init() {}

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

    func workScrollSnapshot(_ key: String) -> ConversationWorkScrollSnapshot {
        workScrollSnapshots[key] ?? .init()
    }

    func setWorkScrollSnapshot(_ key: String, _ snapshot: ConversationWorkScrollSnapshot) {
        workScrollSnapshots[key] = .init(offset: max(0, snapshot.offset), isAtBottom: snapshot.isAtBottom)
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
