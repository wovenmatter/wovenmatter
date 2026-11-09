import Foundation
import Testing
import WovenMatterCompanion
@testable import CompanionClient

@Suite("Quick Chat timers and reminders")
struct MobileTimerReminderTests {
  private let session = "quick-chat"
  private func fixture() throws -> (MobileStore, URL, MobileToolContext) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wm-timer-tests-" + UUID().uuidString)
    return (try MobileStore(file: root.appendingPathComponent("library.json")), root,
      .init(sessionID: session, workspaceID: "phone", enabled: [.timers]))
  }
  private func call(_ store: MobileStore, _ args: [String], context: MobileToolContext, id: String = UUID().uuidString.lowercased()) async -> WovenMatterToolResponse {
    await store.executeLocalTool(.init(arguments: args, requestID: id), context: context)
  }
  private func date(_ value: String) throws -> Date { try MobileToolSupport.date(value) }

  @Test func timerMirrorsIntoTheSyncedCalendarAndNotifiesUntilItFires() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased(), now = try date("2026-11-09T12:00:00Z")
    #expect(await call(store, ["timers", "create", "--text", "Call Sam\nThey asked about Friday.", "--at", "2026-11-09T17:00:00Z"], context: scope, id: id).success)
    let reminders = try await store.reconcileTimerReminders(sessionIDs: [session], now: now)
    #expect(reminders.map(\.timerID) == [id])
    #expect(reminders.first?.notificationID == "woven.timer." + id)
    let event = try #require(await store.calendar.record(id: MobileStore.reminderEventID(timerID: id)))
    #expect(event.event.draft.title == "Call Sam")
    #expect(event.event.draft.startsAt == (try date("2026-11-09T17:00:00Z")))
    #expect(event.event.draft.task == nil, "A reminder is a regular event the phone never runs")
    #expect(event.ownerDeviceID == nil)
    #expect(await store.calendar.pendingCount() == 1, "The mirror uploads with the rest of the calendar")

    // Reconciling again changes nothing, and a timer in another chat is ignored.
    _ = try await store.reconcileTimerReminders(sessionIDs: [session], now: now)
    #expect(await store.calendar.record(id: MobileStore.reminderEventID(timerID: id))?.event.revision == event.event.revision)
    #expect(try await store.reconcileTimerReminders(sessionIDs: ["other"], now: now).isEmpty)

    // Once delivered, a one-time timer stops notifying but its event stays as history.
    let claimed = try await store.claimDueToolTimers(now: try date("2026-11-09T17:00:01Z"))
    let fireID = try #require(claimed.first?.pendingFireID)
    let submission = try await store.enqueueClaimedToolTimer(id: id, fireID: fireID, now: try date("2026-11-09T17:00:01Z"))
    #expect(submission?.sessionID == session)
    #expect(submission?.text.hasPrefix("Call Sam") == true)
    #expect(try await store.reconcileTimerReminders(sessionIDs: [session], now: try date("2026-11-09T17:00:02Z")).isEmpty)
    #expect(await store.calendar.record(id: MobileStore.reminderEventID(timerID: id)) != nil)
  }

  @Test func movingRemovingAndDeletingElsewhereKeepTimerAndCalendarInAgreement() async throws {
    let (store, root, scope) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let now = try date("2026-11-09T12:00:00Z")
    let moved = UUID().uuidString.lowercased(), removed = UUID().uuidString.lowercased(), elsewhere = UUID().uuidString.lowercased()
    for id in [moved, removed, elsewhere] {
      #expect(await call(store, ["timers", "create", "--text", "Stretch", "--at", "2026-11-09T13:00:00Z"], context: scope, id: id).success)
    }
    _ = try await store.reconcileTimerReminders(sessionIDs: [session], now: now)

    #expect(await call(store, ["timers", "update", "--id", moved, "--text", "Stretch later", "--at", "2026-11-09T14:00:00Z"], context: scope).success)
    #expect(await call(store, ["timers", "remove", "--id", removed], context: scope).success)
    let mirror = try #require(await store.calendar.record(id: MobileStore.reminderEventID(timerID: elsewhere)))
    try await store.calendar.delete(id: mirror.id, expectedRevision: mirror.event.revision)

    let reminders = try await store.reconcileTimerReminders(sessionIDs: [session], now: now)
    #expect(reminders.map(\.timerID) == [moved])
    let updated = try #require(await store.calendar.record(id: MobileStore.reminderEventID(timerID: moved)))
    #expect(updated.event.draft.title == "Stretch later")
    #expect(updated.event.draft.startsAt == (try date("2026-11-09T14:00:00Z")))
    #expect(await store.calendar.record(id: MobileStore.reminderEventID(timerID: removed)) == nil)
    #expect(await store.snapshot().toolTimers?[elsewhere]?.removed == true, "Deleting the reminder from the calendar removes its timer")
  }

  @Test func titlesStayShortAndEventIdentityIsStable() {
    #expect(MobileStore.reminderTitle("  \n") == "Reminder")
    #expect(MobileStore.reminderTitle(String(repeating: "a", count: 300)).count == 120)
    #expect(MobileStore.reminderEventID(timerID: "a") == MobileStore.reminderEventID(timerID: "a"))
    #expect(UUID(uuidString: MobileStore.reminderEventID(timerID: "a")) != nil)
    #expect(MobileStore.reminderEventID(timerID: "a") != MobileStore.reminderEventID(timerID: "b"))
  }
}
