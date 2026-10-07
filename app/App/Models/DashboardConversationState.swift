import Foundation
import Observation
import WovenMatterCore
import WovenMatterDashboardStore

struct DashboardMessagePresentation: Sendable {
    let source: String
    let displayedBody: String
    let status: String?
    let createdAt: String
    let document: ConversationMarkdownDocument?
    let activities: [WorkspaceRunActivityRecord]
    let commentaryIDs: Set<String>
    let workTimeline: ConversationWorkTimeline
    let textDeliveredAt: Date
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

    init(page: WorkspaceConversationHistoryPage, previousActivities: [WorkspaceRunActivityRecord] = []) {
        conversationID = page.conversationID
        runs = page.runs
        let runIDs = Set(page.runs.map(\.id))
        let removed = Set(page.removedActivityIDs)
        activities = (page.activitiesAreDelta
            ? Self.merged(activities: previousActivities, with: page.activities) : page.activities)
            .filter { runIDs.contains($0.runID) && !removed.contains($0.id) }
        attachments = page.attachments
        references = page.references
        messages = Self.ordered(messages: page.messages, runs: page.runs)
        hasOlderMessages = page.hasOlderMessages
        loadedOlderMessages = false
    }

    /// `knownMessageIDs` are the loaded message IDs the refresh request sent.
    /// An older page prepended while the request was in flight is absent from
    /// `page`, so its messages keep their own runs, activities, attachments,
    /// and references.
    func refreshing(
        with page: WorkspaceConversationHistoryPage,
        knownMessageIDs: Set<String>
    ) -> DashboardConversationWindow {
        guard page.conversationID == conversationID, loadedOlderMessages,
              let tailStart = page.oldestMessageCursor else {
            return DashboardConversationWindow(page: page, previousActivities: activities)
        }
        let validIDs = page.retainedMessageIDs.map(Set.init)
        let older = messages.filter { Self.cursor(for: $0).precedes(tailStart) }
        let unseenIDs = Set(older.lazy.map(\.id).filter { !knownMessageIDs.contains($0) })
        let retainedMessages = Self.merged(messages: older.filter {
            unseenIDs.contains($0.id) || (validIDs?.contains($0.id) ?? true)
        }, with: page.retainedMessages.filter { Self.cursor(for: $0).precedes(tailStart) })
        let retainedMessageIDs = Set(retainedMessages.map(\.id))
        let pageRunIDs = Set(page.runs.map(\.id))
        func belongs(_ run: WorkspaceRunRecord, to ids: Set<String>) -> Bool {
            run.userMessageID.map(ids.contains) == true || run.assistantMessageID.map(ids.contains) == true
        }
        let unseenRuns = runs.filter { !pageRunIDs.contains($0.id) && belongs($0, to: unseenIDs) }
        let unseenRunIDs = Set(unseenRuns.map(\.id))
        let retainedRuns = page.runs.filter { belongs($0, to: retainedMessageIDs) } + unseenRuns
        let retainedRunIDs = Set(retainedRuns.map(\.id))
        let removed = Set(page.removedActivityIDs)
        let latestActivities = (page.activitiesAreDelta
            ? Self.merged(activities: activities, with: page.activities) : page.activities)
            .filter { !removed.contains($0.id) }
        let retainedActivities = Self.merged(
            activities: activities.filter { unseenRunIDs.contains($0.runID) },
            with: latestActivities.filter { retainedRunIDs.contains($0.runID) }
        )
        // The page read attachments and references only for messages it knew.
        let ownedMessageIDs = page.retainedMessageIDs == nil ? retainedMessageIDs : unseenIDs
        let retainedAttachments = Self.merged(
            attachments: attachments.filter { ownedMessageIDs.contains($0.messageID) },
            with: page.attachments.filter { retainedMessageIDs.contains($0.messageID) }
        )
        let retainedReferences = Self.merged(
            references: references.filter { ownedMessageIDs.contains($0.messageID) },
            with: page.references.filter { retainedMessageIDs.contains($0.messageID) }
        )
        return DashboardConversationWindow(
            conversationID: conversationID,
            messages: Self.merged(messages: retainedMessages, with: page.messages),
            runs: Self.merged(runs: retainedRuns, with: page.runs),
            activities: Self.merged(activities: retainedActivities,
                with: latestActivities.filter { pageRunIDs.contains($0.runID) }),
            attachments: Self.merged(attachments: retainedAttachments, with: page.attachments),
            references: Self.merged(references: retainedReferences, with: page.references),
            hasOlderMessages: retainedMessages.isEmpty ? page.hasOlderMessages : hasOlderMessages,
            loadedOlderMessages: true
        )
    }

    func prepending(_ page: WorkspaceConversationHistoryPage, requestedFrom prior: DashboardConversationWindow? = nil) -> DashboardConversationWindow {
        guard page.conversationID == conversationID else {
            return DashboardConversationWindow(page: page)
        }
        // The current window is authoritative for identities it already knew
        // when paging began. A stale older page must not restore a removed
        // message or activity belonging to one of those runs.
        let knownMessages = Set(prior?.messages.map(\.id) ?? [])
        let knownRuns = Set(prior?.runs.map(\.id) ?? [])
        let currentMessages = Set(messages.map(\.id))
        let currentRuns = Set(runs.map(\.id))
        let pageMessages = page.messages.filter { !knownMessages.contains($0.id) || currentMessages.contains($0.id) }
        let pageRuns = page.runs.filter { !knownRuns.contains($0.id) || currentRuns.contains($0.id) }
        let addedMessageIDs = Set(pageMessages.map(\.id)).subtracting(knownMessages)
        return DashboardConversationWindow(
            conversationID: conversationID,
            messages: Self.merged(messages: pageMessages, with: messages),
            runs: Self.merged(runs: pageRuns, with: runs),
            activities: Self.merged(activities: page.activities.filter { !knownRuns.contains($0.runID) }, with: activities),
            attachments: Self.merged(attachments: page.attachments.filter { prior == nil || addedMessageIDs.contains($0.messageID) }, with: attachments),
            references: Self.merged(references: page.references.filter { prior == nil || addedMessageIDs.contains($0.messageID) }, with: references),
            hasOlderMessages: page.hasOlderMessages,
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
        return byID.values.sorted(by: WorkspaceRunActivityRecord.precedes)
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
    let transcriptState = ConversationTranscriptState()
    private(set) var content: WorkspaceConversationContent?
    private(set) var messagePresentations: [String: DashboardMessagePresentation] = [:]
    private(set) var runPresentations: [String: DashboardRunPresentation] = [:]
    private(set) var runActivities: [WorkspaceRunActivityRecord] = []
    private(set) var taskProgress: ConversationTaskProgress?
    private(set) var hasOlderMessages = false
    private(set) var isLoadingOlderMessages = false
    private(set) var error: String?
    @ObservationIgnored private(set) var presentation: DashboardConversationPresentation?
    /// Advances with every applied presentation, so a refresh rendered from an
    /// older one can tell that a history page landed meanwhile.
    @ObservationIgnored private(set) var presentationRevision: UInt64 = 0
    @ObservationIgnored var lastAccessSequence: UInt64 = 0
    @ObservationIgnored var activityRevision: Int64?
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    init(conversationID: String) {
        self.conversationID = conversationID
    }

    func apply(_ presentation: DashboardConversationPresentation) {
        self.presentation = presentation
        presentationRevision &+= 1
        content = presentation.content
        messagePresentations = presentation.messagesByID
        runPresentations = presentation.runsByID
        runActivities = presentation.window.activities
        let activeRun = presentation.window.runs.last { $0.status == "running" }
        taskProgress = activeRun.flatMap {
            ConversationTaskProgress.latest(in: presentation.window.activities, activeRunID: $0.id)
        }
        if taskProgress == nil { transcriptState.tasksExpanded = false }
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
