import Foundation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

extension CompanionCommandService {
    func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult {
        guard let store = model.dashboardStore else { throw CommandError.unavailable }
        switch request {
        case let .library(search, kind, offset):
            guard search.utf8.count <= 4_096, (0...100_000).contains(offset),
                  kind == nil || LibraryItemKind(rawValue: kind!) != nil else { throw CommandError.invalidCommand }
            var query = LibraryQuery(); query.search = search; query.kind = kind.flatMap { LibraryItemKind(rawValue: $0) }
            let items = try await store.database.libraryItems(query: query, limit: 101, offset: offset)
            return .library(items: items.prefix(100).map { item in
                .init(id: item.id, conversationID: item.conversationID, title: item.title,
                      kind: item.kind.rawValue, sender: item.sender.rawValue, workspace: item.workspaceName,
                      agent: item.agentName, sentAt: item.sentAt, sizeBytes: item.sizeBytes,
                      webURL: item.isWebLink ? URL(string: item.source) : nil,
                      available: item.canOpen, error: item.error)
            }, hasMore: items.count > 100)
        case .libraryFile(let id):
            guard let item = try await store.database.libraryItem(id: id), item.contentHash != nil else {
                throw CompanionAPIError(code: "file_unavailable", message: "This file is not retained on your Mac. Retry it from the Library.")
            }
            let url = try await store.library.openURL(id: id)
            return .file(try await Self.readRetainedFile(url, name: item.title, mimeType: item.mimeType ?? "application/octet-stream"))
        case let .calendar(from, to):
            guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite,
                  to > from, to.timeIntervalSince(from) <= 93 * 86_400 else { throw CommandError.invalidCommand }
            let events = try await store.database.calendarItems()
            let runs = try await store.database.calendarRuns()
            let occurrences = WorkspaceCalendarSchedule.visibleOccurrences(events: events, runs: runs, in: .init(start: from, end: to))
            return .calendar(occurrences.prefix(2_000).map { value in
                let recorded = value.recordedRun ?? runs.first { $0.eventID == value.event.id && $0.occurrenceIndex == value.index }
                return .init(id: value.event.id, revision: value.event.calendar.revision,
                    draft: Self.calendarDraft(WorkspaceCalendarDraft(value.event)), occurrence: value.index, startsAt: value.startsAt,
                    status: recorded?.statusLabel, sessionID: recorded?.sessionID)
            })
        case .session(let id):
            return .session(try await sessionSettings(id))
        case .trash:
            var values = try await store.trashedConversations().prefix(500).map {
                CompanionTrashedItem(id: $0.id, title: $0.title, kind: "conversation")
            }
            for note in try await store.trashedNotes().prefix(500) {
                values.append(.init(id: note.id, title: note.title, kind: "note",
                    revision: try await store.database.noteActionRevision(id: note.id, trashed: true)))
            }
            return .trash(values)
        case let .exportNote(id, format, revision):
            guard let format = WorkspaceNoteExportFormat(rawValue: format) else { throw CommandError.invalidCommand }
            let content = try await store.database.noteExport(id: id, format: format, expectedRevision: revision)
            guard content.data.count <= Self.mobileFileLimit else { throw Self.fileTooLarge }
            return .file(.init(name: content.suggestedFilename, mimeType: "application/octet-stream", data: content.data))
        case let .exportConversation(id, format):
            guard let format = WorkspaceConversationExportFormat(rawValue: format) else { throw CommandError.invalidCommand }
            let conversation = try await conversation(id)
            let bytes = try await store.database.conversationExport(id: id, format: format)
            guard bytes.count <= Self.mobileFileLimit else { throw Self.fileTooLarge }
            return .file(.init(name: format.suggestedFilename(title: conversation.title),
                              mimeType: format == .messages ? "text/markdown" : "application/json", data: bytes))
        }
    }

    func performWorkspaceAction(_ action: CompanionWorkspaceAction) async throws {
        guard let store = model.dashboardStore, !model.backendStopping else { throw CommandError.unavailable }
        switch action {
        case let .conversation(id, action, title, folderID):
            if action == "move" {
                guard try await store.moveConversation(id: id, toFolderID: folderID) else { throw CommandError.unknownConversation }
            } else {
                let mutation: WorkspaceConversationMutation
                switch action {
                case "rename": guard let title else { throw CommandError.invalidCommand }; mutation = .rename(title)
                case "pin": mutation = .setPinned(true)
                case "unpin": mutation = .setPinned(false)
                case "trash": mutation = .moveToTrash
                case "restore": mutation = .restore
                default: throw CommandError.invalidCommand
                }
                try await model.mutateConversation(id: id, mutation: mutation)
            }
        case let .note(id, action, revision, title, folderID):
            guard await model.flushNoteDrafts() else { throw ApplicationModelError.noteDraftSaveFailed }
            let mutation: WorkspaceNoteMutation
            switch action {
            case "rename": guard let title else { throw CommandError.invalidCommand }; mutation = .rename(title)
            case "pin": mutation = .setPinned(true)
            case "unpin": mutation = .setPinned(false)
            case "move": mutation = .moveToFolder(folderID)
            case "trash": mutation = .moveToTrash
            case "restore": mutation = .restore
            default: throw CommandError.invalidCommand
            }
            try await store.mutateNote(id: id, mutation: mutation, expectedRevision: revision)
        case let .configureSession(id, selectedModel, thinking, permission):
            let settings = try await sessionSettings(id)
            guard settings.canConfigure,
                  selectedModel.map({ value in settings.models.contains { $0.id == value } }) ?? true,
                  thinking.map({ value in settings.thinkingLevels.contains { $0.id == value } }) ?? true,
                  permission.map({ value in settings.permissions.contains { $0.id == value } }) ?? true else {
                throw CompanionAPIError(code: "settings_changed", message: "These settings are unavailable or the session is running. Refresh and try again.")
            }
            let context = try await model.sessionSelectionContext(conversationID: id)
            guard !model.runningToolSessionIDs.contains(id) else { throw ApplicationModelError.steeringUnavailable }
            let previous = model.sessionSelectionPreferences.conversation(id: id)?.desiredSelections ?? .init()
            let next = previous.applyingPendingCorrection(SessionSelections(model: selectedModel, thinking: thinking, permission: permission))
            model.sessionSelectionPreferences.stageCalendarSelections(id: id, harness: context.harness, workspace: context.workspace, selections: next)
            try await model.applyPendingSessionSelections(conversationID: id)
        case let .sessionTools(id, enabled, confirmed):
            _ = try await conversation(id)
            let requested = try WorkspaceSessionTools(identifiers: enabled)
            guard let tools = model.agentTools else { throw CommandError.unavailable }
            let current = try await store.database.sessionTools(id)
            // Preserve the Mac's selected Executor profiles. Executor enablement
            // uses the same broker acknowledgement/cancellation path as desktop.
            var ordinary = current
            ordinary.enabled = requested.enabled
            if current.enabled.contains(.executor) { ordinary.enabled.insert(.executor) }
            else { ordinary.enabled.remove(.executor) }
            try await store.database.setSessionTools(ordinary, sessionID: id, confirmedPausingTimers: confirmed)
            if current.enabled.contains(.executor) != requested.enabled.contains(.executor) {
                try await tools.setEnabled(.executor, enabled: requested.enabled.contains(.executor), sessionID: id)
            }
            try await tools.reload()
        case let .saveCalendar(id, revision, draft):
            guard UUID(uuidString: id) != nil else { throw CommandError.invalidCommand }
            let existing = try await store.database.calendarItems().first { $0.id == id }
            guard revision == existing?.calendar.revision else { throw CommandError.invalidCommand }
            var native = WorkspaceCalendarDraft(title: draft.title, details: draft.details,
                startsAt: draft.startsAt, endsAt: draft.endsAt, allDay: draft.allDay, timeZoneID: draft.timeZoneID)
            if let unit = draft.recurrenceUnit {
                guard let unit = WorkspaceCalendarRecurrence.Unit(rawValue: unit) else { throw CommandError.invalidCommand }
                native.recurrence = .init(unit: unit, interval: draft.recurrenceInterval)
            }
            if let task = draft.task {
                guard let runtime = AgentRuntimeKind(rawValue: task.runtime),
                      task.workspaceID == nil || UUID(uuidString: task.workspaceID!) != nil else { throw CommandError.invalidCommand }
                let workspaceID = task.workspaceID.flatMap(UUID.init)
                let prior = existing?.calendar.task?.configuration
                var configuration = prior?.runtimeKind == runtime && prior?.workspaceID == workspaceID
                    ? prior! : model.calendarTaskDefaults(runtime: runtime, workspaceID: workspaceID).configuration
                configuration.title = draft.title; configuration.model = task.model ?? configuration.model
                configuration.thinking = task.thinking ?? configuration.thinking; configuration.permission = task.permission ?? configuration.permission
                configuration.folderID = task.folderID
                native.task = .init(prompt: task.prompt, configuration: configuration, sessionMode: task.newSessionEachTime ? .new : .same)
                native.showsOnCalendar = existing?.calendar.showsOnCalendar ?? true
            }
            _ = try await store.database.saveCalendarEvent(id: id, draft: native, creating: existing == nil, expectedRevision: revision)
        case let .deleteCalendar(id, revision, occurrence):
            try await store.database.deleteCalendarEvent(id: id, occurrence: occurrence, expectedRevision: revision)
        case .retryLibrary(let id): try await store.library.retry(id: id)
        }
        await model.refreshWorkspace()
    }

    private func sessionSettings(_ id: String) async throws -> CompanionSessionSettings {
        _ = try await conversation(id)
        guard let store = model.dashboardStore else { throw CommandError.unavailable }
        // Reading settings does not launch or authenticate a provider. Options
        // come from the Mac's already-negotiated session metadata.
        let saved = try? await store.database.localACPSession(conversationID: id)
        let metadata = model.openCodeModel(for: id)?.metadata(id)
            ?? model.openClawGatewaySessionMetadata[id] ?? model.localACPSessionMetadata[id]
        let tools = try await store.database.sessionTools(id)
        func options(_ values: [String]?, _ labels: [String: SessionOptionMetadata]?, current: String?) -> [CompanionSelection] {
            var ids = values ?? []
            if let current, !ids.contains(current) { ids.append(current) }
            return ids.map { .init(id: $0, label: labels?[$0]?.name ?? $0) }
        }
        return .init(conversationID: id, model: metadata?.model ?? saved?.model,
            thinking: metadata?.thinking ?? saved?.thinking, permission: metadata?.permission ?? saved?.permission,
            models: options(metadata?.selectableModels, metadata?.modelOptionMetadata, current: metadata?.model ?? saved?.model),
            thinkingLevels: options(metadata?.thinkingLevels, metadata?.thinkingOptionMetadata, current: metadata?.thinking ?? saved?.thinking),
            permissions: options(metadata?.permissionOptions, metadata?.permissionOptionMetadata, current: metadata?.permission ?? saved?.permission),
            availableTools: WorkspaceToolGroup.allCases.map { .init(id: $0.rawValue, label: $0.title) },
            enabledTools: tools.enabled.map(\.rawValue).sorted(), canConfigure: !model.runningToolSessionIDs.contains(id))
    }

    private static func calendarDraft(_ value: WorkspaceCalendarDraft) -> CompanionCalendarDraft {
        .init(title: value.title, details: value.details, startsAt: value.startsAt, endsAt: value.endsAt,
            allDay: value.allDay, timeZoneID: value.timeZoneID, recurrenceUnit: value.recurrence?.unit.rawValue,
            recurrenceInterval: value.recurrence?.interval ?? 1, task: value.task.map { task in
                .init(prompt: task.prompt, runtime: task.configuration.runtimeKind.rawValue,
                    workspaceID: task.configuration.workspaceID?.uuidString.lowercased(), model: task.configuration.model,
                    thinking: task.configuration.thinking, permission: task.configuration.permission,
                    folderID: task.configuration.folderID, newSessionEachTime: task.sessionMode == .new)
            })
    }

    nonisolated private static let mobileFileLimit = 32 * 1_024 * 1_024
    nonisolated private static var fileTooLarge: CompanionAPIError {
        .init(code: "file_too_large", message: "Open files larger than 32 MB on your Mac.")
    }
    private static func readRetainedFile(_ url: URL, name: String, mimeType: String) async throws -> CompanionFile {
        try await Task.detached(priority: .utility) {
            guard url.isFileURL else { throw CommandError.invalidCommand }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: mobileFileLimit + 1) ?? Data()
            guard bytes.count <= mobileFileLimit else { throw fileTooLarge }
            return .init(name: name, mimeType: mimeType, data: bytes)
        }.value
    }
}
