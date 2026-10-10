import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CompanionWorkspaceFeaturesTests {
    @Test func managementExportsAndReplayPreserveCanonicalState() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let service = fixture.model.companionCommands
        let id = try await fixture.database.createNote(folderID: nil, title: "Original", content: NoteDocument(blocks: [.richText(.init(text: "Keep this writing"))]).encoded())
        let revision = String(try #require(try await fixture.database.companionNote(id: id)).revision)
        let command = CompanionCommand(deviceID: fixture.device, kind: .workspace,
            workspaceAction: .note(id: id, action: "rename", revision: revision, title: "Renamed", folderID: nil))
        let result = try await service.execute(command, deviceID: fixture.device)
        #expect(result.status == .completed, "\(result.message ?? "")")
        #expect(try await service.execute(command, deviceID: fixture.device) == result)
        #expect(try await fixture.database.companionNote(id: id)?.title == "Renamed")
        let stale = CompanionCommand(deviceID: fixture.device, kind: .workspace,
            workspaceAction: .note(id: id, action: "trash", revision: revision, title: nil, folderID: nil))
        #expect(try await service.execute(stale, deviceID: fixture.device).status == .rejected)
        let current = String(try #require(try await fixture.database.companionNote(id: id)).revision)
        guard case .file(let file) = try await service.readWorkspace(.exportNote(id: id, format: "standard", revision: current)) else { Issue.record("Missing export"); return }
        #expect(String(decoding: file.data, as: UTF8.self).contains("Keep this writing"))
        try await service.performWorkspaceAction(.note(id: id, action: "trash", revision: current, title: nil, folderID: nil))
        guard case .trash(let items) = try await service.readWorkspace(.trash) else { Issue.record("Missing trash"); return }
        let deleted = try #require(items.first { $0.id == id })
        try await service.performWorkspaceAction(.note(id: id, action: "restore", revision: try #require(deleted.revision), title: nil, folderID: nil))
        #expect(try await fixture.database.companionNote(id: id)?.title == "Renamed")
    }

    @Test func calendarSeriesRetainsOriginalStartAndRejectsStaleEdits() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let service = fixture.model.companionCommands
        let id = UUID().uuidString.lowercased(), start = Date().addingTimeInterval(86_400)
        let draft = CompanionCalendarDraft(title: "Series", startsAt: start, recurrenceUnit: "day")
        try await service.performWorkspaceAction(.saveCalendar(id: id, revision: nil, draft: draft))
        guard case .calendar(let events) = try await service.readWorkspace(.calendar(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(4 * 86_400))) else { Issue.record("Missing calendar"); return }
        #expect(events.count >= 3)
        #expect(events.allSatisfy { abs($0.draft.startsAt.timeIntervalSince(start)) < 1 })
        #expect(events[1].startsAt > events[0].startsAt)
        let revision = try #require(events.first?.revision)
        var edited = draft; edited.title = "Updated series"
        try await service.performWorkspaceAction(.saveCalendar(id: id, revision: revision, draft: edited))
        await #expect(throws: (any Error).self) {
            try await service.performWorkspaceAction(.saveCalendar(id: id, revision: revision, draft: draft))
        }
        let next = try #require(try await fixture.database.calendarItems().first)
        try await service.performWorkspaceAction(.deleteCalendar(id: id, revision: next.calendar.revision, occurrence: nil))
        #expect(try await fixture.database.calendarItems().isEmpty)
        #expect(await fixture.recorder.deliveries.isEmpty)
    }

    @Test func settingsReadsNeverStartAgentAndInvalidToolsAreRejected() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let id = try await fixture.database.createLocalACPSession(runtimeKind: .defaultAgent, title: "Settings", ownerDeviceID: UUID())
        let service = fixture.model.companionCommands
        guard case .session(let settings) = try await service.readWorkspace(.session(id: id)) else { Issue.record("Missing settings"); return }
        #expect(settings.availableTools.map(\.id).contains("calendar"))
        try await service.performWorkspaceAction(.sessionTools(id: id, enabled: ["notes", "library"], confirmPausingTimers: true))
        #expect(try await fixture.database.sessionTools(id).enabled == [.notes, .library])
        // Enabling Executor must go through the desktop broker. An unconfigured
        // broker cannot grant mobile authority by merely changing database flags.
        await #expect(throws: (any Error).self) {
            try await service.performWorkspaceAction(.sessionTools(id: id, enabled: ["notes", "library", "executor"], confirmPausingTimers: true))
        }
        #expect(try await fixture.database.sessionTools(id).enabled == [.notes, .library])
        await #expect(throws: (any Error).self) { try await service.performWorkspaceAction(.sessionTools(id: id, enabled: ["unknown"], confirmPausingTimers: false)) }
        #expect(await fixture.recorder.deliveries.isEmpty)
        #expect(await fixture.recorder.configurations.isEmpty)
    }
}
