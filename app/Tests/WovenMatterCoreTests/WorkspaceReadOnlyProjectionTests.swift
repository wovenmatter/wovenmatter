import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Read-only dashboard projection")
struct WorkspaceReadOnlyProjectionTests {
  @Test func projectionReadsWriterChangesWithoutRecoveryOrFileCreation() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path:"wm-projection-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let owner = try WorkspaceDatabase(url:directory.appending(path:"workspace.sqlite"))
    let session = try owner.createLocalACPSession(runtimeKind:.codex,title:"Running",ownerDeviceID:UUID())
    let run = try owner.beginLocalACPRun(conversationID:session,content:"Keep running")
    let before = Set(try FileManager.default.contentsOfDirectory(atPath:directory.path))
    let projection = try DashboardStore(supportDirectory:directory,readOnlyProjection:true)
    #expect(projection.database.isReadOnlyProjection)
    _ = try await projection.snapshot()
    let running = try owner.withLock { try owner.historyRowsUnlocked("SELECT status FROM dashboard_runs WHERE id=?",values:[run.runID]).first?.objectValue?["status"]?.stringValue }
    #expect(running == "running")
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath:directory.path)) == before)
    let revision = try projection.database.dashboardRevision()
    try owner.saveCalendarEvent(draft:.init(title:"Changed by owner",startsAt:Date()),creating:true)
    #expect(try projection.database.dashboardRevision() > revision)
    #expect(try projection.database.calendarItems().count == 1)
    // Transaction-based queries still work; mutations cannot acquire write access.
    let count = try projection.database.transaction {
      try projection.database.historyRowsUnlocked("SELECT count(*) AS n FROM dashboard_calendar_items",values:[]).first?.objectValue?["n"]?.intValue
    }
    #expect(count == 1)
    #expect(throws:(any Error).self) {
      try projection.database.saveCalendarEvent(draft:.init(title:"Forbidden",startsAt:Date()),creating:true)
    }
    #expect(throws:WorkspaceDatabaseError.readOnlyProjection) {
      try projection.database.libraryFiles.retain(Data("blocked".utf8))
    }
    await projection.cancelLocalACPPrompt(conversationID:session)
    await projection.shutdownLocalACPSessions()
    let retained = try owner.withLock { try owner.historyRowsUnlocked("SELECT status FROM dashboard_runs WHERE id=?",values:[run.runID]).first?.objectValue?["status"]?.stringValue }
    #expect(retained == "running")
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath:directory.path)) == before)
  }

  @Test func missingProjectionDoesNotCreateWorkspace() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path:"wm-missing-projection-" + UUID().uuidString)
    #expect(throws:(any Error).self) { try DashboardStore(supportDirectory:directory,readOnlyProjection:true) }
    #expect(!FileManager.default.fileExists(atPath:directory.path))
  }
}
