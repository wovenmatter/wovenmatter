import SwiftUI
import UserNotifications
import CompanionClient
import WovenMatterCompanion

/// Quick Chat timers and reminders. iOS does not run agent work reliably in the
/// background, so a timer becomes a local notification that fires even while the
/// app is closed. When the app is open, a due timer's text is delivered to its chat
/// and the agent acts then. Recurring agent work belongs to a Mac or Linux
/// scheduled task; this phone never runs calendar tasks.
extension CompanionModel {
  func startDeviceScheduler() {
    guard !fixture, !isolatedTestHost, deviceScheduleTask == nil else { return }
    deviceScheduleTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.processDeviceSchedule()
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
  }

  func stopDeviceScheduler() {
    deviceScheduleTask?.cancel(); deviceScheduleTask = nil
  }

  var quickChatSessionIDs: Set<String> {
    Set(executionRecords.values.filter { $0.quickChatVersion == 1 && $0.isTrashed != true }.map(\.id))
  }

  func processDeviceSchedule() async {
    guard !fixture, !isolatedTestHost, initialized, !processingDeviceSchedule, let store else { return }
    processingDeviceSchedule = true
    defer { processingDeviceSchedule = false }
    do {
      try Task.checkCancellation()
      await processDeviceToolSubmissions()
      let sessions = quickChatSessionIDs
      for timer in try await store.claimDueToolTimers() where sessions.contains(timer.sessionID) {
        try Task.checkCancellation()
        guard let fireID = timer.pendingFireID else { continue }
        do {
          // Pause/remove/update may invalidate a captured claim while earlier timers await.
          // Validate, enqueue, and advance the timer in one actor transaction before execution.
          if try await store.enqueueClaimedToolTimer(id: timer.id, fireID: fireID) != nil {
            try Task.checkCancellation()
            await processDeviceToolSubmissions()
          }
        } catch is CancellationError { throw CancellationError() }
        catch { /* Retain this fire ID, while allowing unrelated timers to proceed. */ }
      }
      await refreshQuickChatReminders()
    } catch is CancellationError { }
    catch { /* Persistent claims remain available for the next foreground window. */ }
  }

  /// Mirrors timers into the synced calendar and replaces this app's pending
  /// timer notifications with the current set.
  func refreshQuickChatReminders() async {
    guard !fixture, !isolatedTestHost, let store else { return }
    let previous = await store.calendar.allRecords()
    guard let reminders = try? await store.reconcileTimerReminders(sessionIDs: quickChatSessionIDs) else { return }
    if await store.calendar.allRecords() != previous { calendarRevision &+= 1 }
    let titles = Dictionary(uniqueKeysWithValues: reminders.map { ($0.timerID, executionRecords[$0.sessionID]?.title ?? "Quick Chat") })
    await QuickChatNotifications.shared.schedule(reminders, chatTitles: titles)
  }

  /// A notification tap opens the chat that set the timer.
  func openTimerNotification(conversationID: String) async {
    guard executionRecords[conversationID] != nil else { tab = .chat; return }
    await selectConversation(conversationID, workspaceID: "local")
    await processDeviceSchedule()
  }
}

/// Owns this app's timer notifications. Other notification requests are untouched.
@MainActor final class QuickChatNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = QuickChatNotifications()
  /// Set by the app; called with the chat a tapped timer belongs to.
  var open: ((String) -> Void)?
  /// Nil until this process has reconciled once, so stale requests from an earlier launch are removed.
  private var lastScheduled: [String: Date]?
  private var authorizationRequested = false

  func install() { UNUserNotificationCenter.current().delegate = self }

  func schedule(_ reminders: [MobileTimerReminder], chatTitles: [String: String]) async {
    // iOS keeps up to 64 pending requests per app; the soonest timers matter most.
    let upcoming = Array(reminders.prefix(60))
    let wanted = Dictionary(uniqueKeysWithValues: upcoming.map { ($0.notificationID, $0.fireAt) })
    guard wanted != lastScheduled else { return }
    let center = UNUserNotificationCenter.current()
    if !upcoming.isEmpty, !authorizationRequested {
      authorizationRequested = true
      _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
    let pending = await center.pendingNotificationRequests().map(\.identifier)
    let stale = pending.filter { $0.hasPrefix(MobileTimerReminder.notificationPrefix) && wanted[$0] == nil }
    center.removePendingNotificationRequests(withIdentifiers: stale)
    for reminder in upcoming where lastScheduled?[reminder.notificationID] != reminder.fireAt || !pending.contains(reminder.notificationID) {
      let content = UNMutableNotificationContent()
      content.title = chatTitles[reminder.timerID] ?? "Quick Chat"
      content.body = MobileStore.reminderTitle(reminder.text)
      content.sound = .default
      content.threadIdentifier = reminder.sessionID
      content.userInfo = ["conversationID": reminder.sessionID, "timerID": reminder.timerID]
      let interval = max(1, reminder.fireAt.timeIntervalSinceNow)
      let request = UNNotificationRequest(identifier: reminder.notificationID, content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
      try? await center.add(request)
    }
    lastScheduled = wanted
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .sound, .list]
  }
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    guard let id = response.notification.request.content.userInfo["conversationID"] as? String else { return }
    await MainActor.run { open?(id) }
  }
}
