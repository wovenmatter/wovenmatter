import Foundation
import Observation
import WovenMatterCore
import WovenMatterDashboardStore

struct DashboardMessagePresentation: Sendable {
    let source: String
    let status: String?
    let createdAt: String
    let document: ConversationMarkdownDocument?
}

struct DashboardRunPresentation: Sendable {
    let source: WorkspaceRunRecord
    let startedAt: Date?
    let completedDuration: String?
}

struct DashboardConversationWindow: Equatable, Sendable {
    let conversationID: String
    let messages: [WorkspaceMessageRecord]
    let runs: [WorkspaceRunRecord]
    let activities: [WorkspaceRunActivityRecord]
    let attachments: [WorkspaceMessageAttachmentRecord]
    let references: [WorkspaceMessageReferenceRecord]
    let hasOlderMessages: Bool
    let loadedOlderMessages: Bool

    init(page: WorkspaceConversationHistoryPage) {
        conversationID = page.conversationID
        runs = page.runs
        activities = page.activities
        attachments = page.attachments
        references = page.references
        messages = Self.ordered(messages: page.messages, runs: page.runs)
        hasOlderMessages = page.hasOlderMessages
        loadedOlderMessages = false
    }

    func refreshing(with page: WorkspaceConversationHistoryPage) -> DashboardConversationWindow {
        guard page.conversationID == conversationID, loadedOlderMessages,
              let tailStart = page.oldestMessageCursor else {
            return DashboardConversationWindow(page: page)
        }
        // Completed history outside the live tail is product-defined as immutable.
        // Preserve the already paged prefix instead of requerying it on every refresh;
        // if sent-message editing or deletion is added, revalidate this prefix here.
        let retainedMessages = messages.filter {
            Self.cursor(for: $0).precedes(tailStart)
        }
        let retainedMessageIDs = Set(retainedMessages.map(\.id))
        let retainedRuns = runs.filter {
            $0.userMessageID.map(retainedMessageIDs.contains) == true
                || $0.assistantMessageID.map(retainedMessageIDs.contains) == true
        }
        let retainedRunIDs = Set(retainedRuns.map(\.id))
        let retainedActivities = activities.filter { retainedRunIDs.contains($0.runID) }
        let retainedAttachments = attachments.filter { retainedMessageIDs.contains($0.messageID) }
        let retainedReferences = references.filter { retainedMessageIDs.contains($0.messageID) }
        return DashboardConversationWindow(
            conversationID: conversationID,
            messages: Self.merged(messages: retainedMessages, with: page.messages),
            runs: Self.merged(runs: retainedRuns, with: page.runs),
            activities: Self.merged(activities: retainedActivities, with: page.activities),
            attachments: Self.merged(attachments: retainedAttachments, with: page.attachments),
            references: Self.merged(references: retainedReferences, with: page.references),
            hasOlderMessages: retainedMessages.isEmpty ? page.hasOlderMessages : hasOlderMessages,
            loadedOlderMessages: true
        )
    }

    func prepending(_ page: WorkspaceConversationHistoryPage) -> DashboardConversationWindow {
        guard page.conversationID == conversationID else {
            return DashboardConversationWindow(page: page)
        }
        return DashboardConversationWindow(
            conversationID: conversationID,
            messages: Self.merged(messages: page.messages, with: messages),
            runs: Self.merged(runs: page.runs, with: runs),
            activities: Self.merged(activities: page.activities, with: activities),
            attachments: Self.merged(attachments: page.attachments, with: attachments),
            references: Self.merged(references: page.references, with: references),
            hasOlderMessages: page.hasOlderMessages,
            loadedOlderMessages: true
        )
    }

    func mergingNewer(_ newer: DashboardConversationWindow) -> DashboardConversationWindow {
        guard newer.conversationID == conversationID else { return newer }
        return DashboardConversationWindow(
            conversationID: conversationID,
            messages: Self.merged(messages: messages, with: newer.messages),
            runs: Self.merged(runs: runs, with: newer.runs),
            activities: Self.merged(activities: activities, with: newer.activities),
            attachments: Self.merged(attachments: attachments, with: newer.attachments),
            references: Self.merged(references: references, with: newer.references),
            hasOlderMessages: hasOlderMessages,
            loadedOlderMessages: true
        )
    }

    private init(
        conversationID: String,
        messages: [WorkspaceMessageRecord],
        runs: [WorkspaceRunRecord],
        activities: [WorkspaceRunActivityRecord],
        attachments: [WorkspaceMessageAttachmentRecord],
        references: [WorkspaceMessageReferenceRecord],
        hasOlderMessages: Bool,
        loadedOlderMessages: Bool
    ) {
        self.conversationID = conversationID
        self.runs = runs
        self.activities = activities
        self.attachments = attachments
        self.references = references
        self.messages = Self.ordered(messages: messages, runs: runs)
        self.hasOlderMessages = hasOlderMessages
        self.loadedOlderMessages = loadedOlderMessages
    }

    private static func cursor(for message: WorkspaceMessageRecord) -> WorkspaceConversationHistoryCursor {
        WorkspaceConversationHistoryCursor(createdAt: message.createdAt, messageID: message.id)
    }

    private static func merged(
        messages first: [WorkspaceMessageRecord],
        with second: [WorkspaceMessageRecord]
    ) -> [WorkspaceMessageRecord] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for message in second {
            byID[message.id] = message
        }
        return byID.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
    }

    private static func merged(
        runs first: [WorkspaceRunRecord],
        with second: [WorkspaceRunRecord]
    ) -> [WorkspaceRunRecord] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for run in second {
            byID[run.id] = run
        }
        return byID.values.sorted {
            let firstCreatedAt = $0.createdAt ?? ""
            let secondCreatedAt = $1.createdAt ?? ""
            return firstCreatedAt == secondCreatedAt ? $0.id < $1.id : firstCreatedAt < secondCreatedAt
        }
    }

    private static func merged(
        activities first: [WorkspaceRunActivityRecord],
        with second: [WorkspaceRunActivityRecord]
    ) -> [WorkspaceRunActivityRecord] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for activity in second { byID[activity.id] = activity }
        return byID.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
    }

    private static func merged(
        attachments first: [WorkspaceMessageAttachmentRecord],
        with second: [WorkspaceMessageAttachmentRecord]
    ) -> [WorkspaceMessageAttachmentRecord] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for attachment in second { byID[attachment.id] = attachment }
        return byID.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    private static func merged(
        references first: [WorkspaceMessageReferenceRecord],
        with second: [WorkspaceMessageReferenceRecord]
    ) -> [WorkspaceMessageReferenceRecord] {
        var byID = Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0) })
        for reference in second { byID[reference.id] = reference }
        return byID.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    /// Server and Mac clocks can differ enough for a response timestamp to
    /// precede the prompt that caused it. Use timestamps as the baseline, then
    /// enforce the causal user -> assistant relationship carried by each run.
    private static func ordered(
        messages: [WorkspaceMessageRecord],
        runs: [WorkspaceRunRecord]
    ) -> [WorkspaceMessageRecord] {
        let chronological = messages.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        let messageIDs = Set(chronological.map(\.id))
        var prerequisites: [String: Set<String>] = [:]
        for run in runs {
            guard let userMessageID = run.userMessageID,
                  let assistantMessageID = run.assistantMessageID,
                  userMessageID != assistantMessageID,
                  messageIDs.contains(userMessageID),
                  messageIDs.contains(assistantMessageID) else { continue }
            prerequisites[assistantMessageID, default: []].insert(userMessageID)
        }
        guard !prerequisites.isEmpty else { return chronological }

        // Most histories already satisfy run causality. Avoid shifting an array
        // once per message in that common case, especially after paging history.
        var precedingIDs: Set<String> = []
        precedingIDs.reserveCapacity(chronological.count)
        let isAlreadyOrdered = chronological.allSatisfy { message in
            guard prerequisites[message.id, default: []].isSubset(of: precedingIDs) else {
                return false
            }
            precedingIDs.insert(message.id)
            return true
        }
        if isAlreadyOrdered { return chronological }

        var emitted: Set<String> = []
        var remaining = chronological
        var result: [WorkspaceMessageRecord] = []
        result.reserveCapacity(chronological.count)
        while !remaining.isEmpty {
            guard let nextIndex = remaining.firstIndex(where: { message in
                prerequisites[message.id, default: []].isSubset(of: emitted)
            }) else {
                // Malformed cyclic relationships must not make messages vanish.
                result.append(contentsOf: remaining)
                break
            }
            let next = remaining.remove(at: nextIndex)
            emitted.insert(next.id)
            result.append(next)
        }
        return result
    }
}

private extension WorkspaceConversationHistoryCursor {
    func precedes(_ other: WorkspaceConversationHistoryCursor) -> Bool {
        createdAt == other.createdAt ? messageID < other.messageID : createdAt < other.createdAt
    }
}

struct DashboardConversationPresentation: Sendable {
    let window: DashboardConversationWindow
    let messagesByID: [String: DashboardMessagePresentation]
    let runsByID: [String: DashboardRunPresentation]

    var content: WorkspaceConversationContent {
        WorkspaceConversationContent(
            conversationID: window.conversationID,
            messages: window.messages,
            runs: window.runs,
            attachments: window.attachments,
            references: window.references
        )
    }
}

@MainActor
@Observable
final class DashboardConversationState {
    let conversationID: String
    private(set) var content: WorkspaceConversationContent?
    private(set) var messagePresentations: [String: DashboardMessagePresentation] = [:]
    private(set) var runPresentations: [String: DashboardRunPresentation] = [:]
    private(set) var runActivities: [WorkspaceRunActivityRecord] = []
    private(set) var hasOlderMessages = false
    private(set) var isLoadingOlderMessages = false
    private(set) var error: String?
    @ObservationIgnored var presentation: DashboardConversationPresentation?
    @ObservationIgnored var lastAccessSequence: UInt64 = 0
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    init(conversationID: String) {
        self.conversationID = conversationID
    }

    func apply(_ presentation: DashboardConversationPresentation) {
        self.presentation = presentation
        content = presentation.content
        messagePresentations = presentation.messagesByID
        runPresentations = presentation.runsByID
        runActivities = presentation.window.activities
        hasOlderMessages = presentation.window.hasOlderMessages
    }

    func setLoadingOlderMessages(_ loading: Bool) {
        isLoadingOlderMessages = loading
    }

    func setError(_ error: String?) {
        self.error = error
    }

    func beginRefresh() -> UInt64 {
        refreshGeneration &+= 1
        return refreshGeneration
    }

    func isCurrentRefresh(_ generation: UInt64) -> Bool {
        refreshGeneration == generation
    }
}
