import Foundation
import CryptoKit
import WovenMatterCompanion

/// A Quick Chat timer that still needs its local notification.
public struct MobileTimerReminder: Equatable, Sendable {
  public var timerID: String
  public var sessionID: String
  public var text: String
  public var fireAt: Date
  public var notificationID: String { MobileTimerReminder.notificationPrefix + timerID }
  public static let notificationPrefix = "woven.timer."
}

/// Timers are this phone's reminders. Each live timer is mirrored as a regular
/// calendar event, so it synchronizes with the library through the calendar
/// outbox and appears on every device's calendar. The phone never runs agent work
/// in the background: the notification alerts the user, and the timer's text
/// reaches its chat when the app is next open.
extension MobileStore {
  /// One calendar event per timer, derived from the timer ID so every launch agrees.
  public static func reminderEventID(timerID: String) -> String {
    let bytes = Array(SHA256.hash(data: Data(("quick-chat-timer:" + timerID).utf8)).prefix(16))
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
  }
  /// The first line of the timer text, short enough for a calendar title.
  public static func reminderTitle(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    let title = line.isEmpty ? "Reminder" : line
    return title.count > 120 ? String(title.prefix(119)) + "…" : title
  }
  /// Recurring work belongs to a Mac or Linux scheduled task; phone timers fire once.
  public static let recurringTimerMessage = "Timers on this phone fire once. Offer the user a scheduled task on a Mac or Linux workspace agent for recurring work."

  public func removeToolTimer(id: String) throws {
    try transaction { next in
      guard var timer = next.toolTimers?[id], !timer.removed else { return }
      timer.removed = true; timer.pendingFireID = nil; timer.pendingFireAt = nil
      next.toolTimers?[id] = timer
    }
  }

  /// Brings the calendar mirror up to date for timers in `sessionIDs` and returns
  /// the timers that should still notify. A mirror event deleted on another
  /// device removes its timer here; a fired one-time timer keeps its event as history.
  public func reconcileTimerReminders(sessionIDs: Set<String>, now: Date = Date()) async throws -> [MobileTimerReminder] {
    var reminders: [MobileTimerReminder] = []
    let timers = (state.toolTimers ?? [:]).values.filter { sessionIDs.contains($0.sessionID) }.sorted { $0.id < $1.id }
    let records = Dictionary(uniqueKeysWithValues: await calendar.allRecords().map { ($0.id, $0) })
    for timer in timers where !timer.removed {
      let eventID = Self.reminderEventID(timerID: timer.id), existing = records[eventID]
      if existing?.deleted == true {
        // The user removed the reminder from the library calendar.
        try removeToolTimer(id: timer.id)
        continue
      }
      // A paused timer keeps its event, and a one-time timer pauses itself once
      // delivered, so its event stays as history. Only removal deletes the event.
      if timer.isPaused { continue }
      let title = Self.reminderTitle(timer.instruction)
      if existing?.event.draft.startsAt != timer.nextFireAt || existing?.event.draft.title != title {
        var draft = existing?.event.draft ?? CompanionCalendarDraft(details: "Quick Chat timer")
        draft.title = title; draft.startsAt = timer.nextFireAt; draft.endsAt = nil; draft.allDay = false
        draft.recurrenceUnit = nil; draft.recurrenceInterval = 1; draft.task = nil
        // A calendar conflict waits for the user; the notification still fires.
        _ = try? await calendar.save(id: eventID, expectedRevision: existing?.event.revision, draft: draft)
      }
      if timer.nextFireAt > now {
        reminders.append(.init(timerID: timer.id, sessionID: timer.sessionID, text: timer.instruction, fireAt: timer.nextFireAt))
      }
    }
    // Removed timers drop their pending event; a past one stays as history.
    for timer in timers where timer.removed {
      let eventID = Self.reminderEventID(timerID: timer.id)
      if let existing = records[eventID], !existing.deleted, existing.event.draft.startsAt > now {
        _ = try? await calendar.delete(id: eventID, expectedRevision: existing.event.revision)
      }
    }
    return reminders.sorted { $0.fireAt < $1.fireAt }
  }
}
