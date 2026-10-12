import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

@MainActor @Observable
final class ProductAnalyticsModel {
  private(set) var preference: ProductAnalyticsPreference? {
    didSet {
      if interface { disclosurePresented = !localDisclosureAcknowledged }
    }
  }
  private(set) var log: [ProductAnalyticsLogEntry] = []
  var errorMessage: String?
  var disclosurePresented = false
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  private var database: WorkspaceDatabase?
  private var rpc: BackendRPCClient?
  private var task: Task<Void, Never>?
  private var generation = 0
  private let startedAt = Date()
  private var lastEdit: Date?
  private var completedRunIDs: Set<String> = []
  private var opened = false
  private var interface = false
  private var locallyDisabled = false
  var enabled: Bool { !locallyDisabled && (preference?.enabled ?? true) }
  private var disclosureKey: String? {
    preference.map { "wovenmatter.analytics.disclosed." + $0.analyticsID }
  }
  // The library acknowledgement does not replace this frontend’s disclosure.
  private var localDisclosureAcknowledged: Bool {
    disclosureKey.map { defaults.bool(forKey: $0) } ?? false
  }
  private var session = URLSession(configuration: .ephemeral)
  static let updateReceiptKey = "wovenmatter.analytics.pending-update.v1"
  static let projectToken = "phc_ukNR3Tu7AjaLmAVjbapvKsyaB8LdhFwM3vUjM5Jfxpeh"
  func configure(database: WorkspaceDatabase, publisher: Bool) {
    self.database = database
    if publisher, task == nil { session = URLSession(configuration: .ephemeral) }
    if publisher, task == nil {
      task = Task { [weak self] in
        while !Task.isCancelled {
          guard self != nil else { return }
          await self?.upload()
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
      }
    }
  }
  func configure(rpc: BackendRPCClient) { self.rpc = rpc }
  func openInterface() async {
    interface = true
    await refresh()
    guard preference != nil else { return }
    disclosurePresented = !localDisclosureAcknowledged
    if !disclosurePresented, !opened {
      opened = true
      await record(.appOpened)
    }
  }
  func refresh() async {
    do {
      if let rpc {
        preference = try JSONDecoder().decode(
          ProductAnalyticsPreference.self,
          from: await rpc.call(method: "analytics.preference", payload: Data()))
        log = try JSONDecoder().decode(
          [ProductAnalyticsLogEntry].self,
          from: await rpc.call(method: "analytics.log", payload: Data()))
      } else if let database {
        preference = try await database.productAnalyticsPreference()
        log = try await database.productAnalyticsLog()
      }
      await confirmUpdateInstallation()
    } catch { errorMessage = "Analytics settings are temporarily unavailable." }
  }
  func setEnabled(_ enabled: Bool, disclose: Bool = false) async {
    generation += 1
    let effectiveEnabled = disclose && enabled ? (preference?.enabled ?? true) : enabled
    let epoch = generation
    locallyDisabled = !effectiveEnabled
    if !effectiveEnabled {
      defaults.removeObject(forKey: Self.updateReceiptKey)
      task?.cancel()
      task = nil
      session.invalidateAndCancel()
    }
    guard let preference else { return }
    do {
      let change = ProductAnalyticsPreferenceChange(
        enabled: effectiveEnabled, expectedRevision: preference.revision,
        acknowledgeDisclosure: disclose)
      let updated: ProductAnalyticsPreference
      if let rpc {
        updated = try JSONDecoder().decode(
          ProductAnalyticsPreference.self,
          from: await rpc.call(
            method: "analytics.setPreference", payload: JSONEncoder().encode(change)))
      } else if let database {
        updated = try await database.setProductAnalyticsPreference(change)
      } else {
        return
      }
      guard epoch == generation else { return }
      self.preference = updated
      if disclose, let key = disclosureKey { defaults.set(true, forKey: key) }
      disclosurePresented = false
      errorMessage = nil
      if effectiveEnabled, let database {
        configure(database: database, publisher: !database.isReadOnlyProjection)
      }
      if disclose, effectiveEnabled, interface {
        opened = true
        await record(.appOpened)
      }
      await refresh()
    } catch { errorMessage = "The analytics preference could not be saved. Please retry." }
  }
  func record(_ name: ProductAnalyticsEvent.Name, properties: [String: String] = [:]) async {
    guard !locallyDisabled, !disclosurePresented, !interface || localDisclosureAcknowledged,
      let preference, preference.collects else {
      return
    }
    if name == .contentChanged, properties["action"] == "edit" {
      if let lastEdit, Date().timeIntervalSince(lastEdit) < 30 { return }
      lastEdit = Date()
    }
    var values = properties
    values["platform"] = "macos"
    values["app_version"] =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    values["os_major"] = String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    let event = ProductAnalyticsEvent(
      preferenceRevision: preference.revision, name: name, properties: values)
    _ = await enqueue(event)
  }
  /// Acknowledged UUIDs (including privacy rejections) consume a local receipt;
  /// a transport failure retains it for retry without inventing another install.
  private func enqueue(_ event: ProductAnalyticsEvent) async -> Bool {
    let epoch = generation
    do {
      if let rpc {
        let acknowledgement = try JSONDecoder().decode(
          ProductAnalyticsAcknowledgement.self,
          from: await rpc.call(
            method: "analytics.events",
            payload: JSONEncoder().encode(ProductAnalyticsBatch(events: [event]))))
        if epoch == generation { self.preference = acknowledgement.preference }
        return acknowledgement.acceptedEventIDs.contains(event.id)
          || acknowledgement.discardedEventIDs.contains(event.id)
      } else if let database {
        let acknowledgement = try await database.enqueueProductAnalytics([event])
        return acknowledgement.acceptedEventIDs.contains(event.id)
          || acknowledgement.discardedEventIDs.contains(event.id)
      }
    } catch { /* Analytics must never interrupt a user action. */ }
    return false
  }
  func prepareUpdateInstallation(_ manifest: WovenMatterReleaseManifest) -> UUID {
    let installationID = UUID()
    defaults.removeObject(forKey: Self.updateReceiptKey)
    guard !locallyDisabled, localDisclosureAcknowledged, let preference,
      preference.collects else { return installationID }
    let receipt = ProductAnalyticsUpdateReceipt(
      analyticsID: preference.analyticsID, version: manifest.version, build: manifest.build,
      event: ProductAnalyticsEvent(id: installationID.uuidString.lowercased(),
        preferenceRevision: preference.revision, name: .updateInstallCompleted,
        properties: ["platform": "macos", "target_version": manifest.version]))
    if let data = try? JSONEncoder().encode(receipt) {
      defaults.set(data, forKey: Self.updateReceiptKey)
    }
    return installationID
  }
  func cancelUpdateInstallation() {
    defaults.removeObject(forKey: Self.updateReceiptKey)
  }
  static func markUpdateLaunched(marker: URL, version: String, build: Int) {
    let defaults = UserDefaults.standard
    guard let data = defaults.data(forKey: updateReceiptKey),
      var receipt = try? JSONDecoder().decode(ProductAnalyticsUpdateReceipt.self, from: data),
      receipt.confirmLaunch(marker: marker, version: version, build: build),
      let updated = try? JSONEncoder().encode(receipt) else { return }
    defaults.set(updated, forKey: updateReceiptKey)
  }
  func confirmUpdateInstallation(
    version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
    build: Int? = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
  ) async {
    guard interface, let preference,
      let data = defaults.data(forKey: Self.updateReceiptKey),
      let receipt = try? JSONDecoder().decode(ProductAnalyticsUpdateReceipt.self, from: data)
    else { return }
    // Opt-out, a new preference epoch, or a different library fences the receipt.
    guard !locallyDisabled, preference.collects,
      receipt.analyticsID == preference.analyticsID,
      receipt.event.preferenceRevision == preference.revision else {
      cancelUpdateInstallation()
      return
    }
    guard localDisclosureAcknowledged, receipt.confirmed,
      receipt.version == version, receipt.build == build
    else { return }
    guard receipt.event.validated(preference: preference) != nil else {
      cancelUpdateInstallation()
      return
    }
    if await enqueue(receipt.event), defaults.data(forKey: Self.updateReceiptKey) == data {
      cancelUpdateInstallation()
    }
  }
  private static func analyticsDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
  func completedRun(_ run: WorkspaceRunRecord, harness: String?) async {
    guard let completed = run.completedAt.flatMap(Self.analyticsDate), completed >= startedAt
    else { return }
    guard completedRunIDs.insert(run.id).inserted else { return }
    if completedRunIDs.count > 1000 { completedRunIDs = [run.id] }
    let outcome: String
    switch run.status {
    case "completed", "succeeded", "success": outcome = "success"
    case "cancelled", "canceled", "stopped": outcome = "cancelled"
    default: outcome = "failure"
    }
    var values = ["outcome": outcome]
    values["harness"] = harness
    if let start = run.startedAt.flatMap(Self.analyticsDate) {
      values["duration_range"] = ProductAnalyticsEvent.durationRange(
        max(0, completed.timeIntervalSince(start)))
    }
    await record(.agentRunCompleted, properties: values)
  }
  func ingest(_ batch: ProductAnalyticsBatch) async throws -> ProductAnalyticsAcknowledgement {
    guard let database else { throw WorkspaceDatabaseError.corruptRow }
    return try await database.enqueueProductAnalytics(batch.events)
  }
  func change(_ change: ProductAnalyticsPreferenceChange) async throws
    -> ProductAnalyticsPreference
  {
    generation += 1
    let epoch = generation
    if !change.enabled {
      task?.cancel()
      task = nil
      session.invalidateAndCancel()
    }
    guard let database else { throw WorkspaceDatabaseError.corruptRow }
    let value = try await database.setProductAnalyticsPreference(change)
    if epoch == generation {
      preference = value
      if value.collects { configure(database: database, publisher: true) }
    }
    return value
  }
  private func upload() async {
    #if DEBUG
      return  // Test and developer builds never transmit to production PostHog.
    #else
      guard let database, !database.isReadOnlyProjection else { return }
      let epoch = generation
      do {
        let current = try await database.productAnalyticsPreference()
        preference = current
        guard current.collects else { return }
        let rows = try await database.productAnalyticsLog(limit: 1000)
        let events = rows.filter { $0.status == "pending" }.reversed().compactMap {
          $0.event.validated(preference: current)
        }.prefix(20)
        guard !locallyDisabled, !events.isEmpty, epoch == generation, !Task.isCancelled
        else { return }
        let batch = events.map { $0.postHogObject(analyticsID: current.analyticsID) }
        var request = URLRequest(url: URL(string: "https://us.i.posthog.com/batch/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
          "api_key": Self.projectToken, "batch": batch,
        ])
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
          (200..<300).contains(response.statusCode), epoch == generation
        else { return }
        try await database.markProductAnalyticsDelivered(events.map(\.id))
      } catch { /* Retain bounded events for retry with their original UUID/timestamp. */  }
    #endif
  }
}


struct ProductAnalyticsUpdateReceipt: Codable, Equatable {
  let analyticsID: String
  let version: String
  let build: Int
  var event: ProductAnalyticsEvent
  var confirmed = false

  mutating func confirmLaunch(marker: URL, version: String, build: Int, now: Date = Date()) -> Bool {
    guard !confirmed, self.version == version, self.build == build,
      UUID(uuidString: event.id) != nil, marker.lastPathComponent == ".ready-" + event.id
    else { return false }
    confirmed = true
    event.timestamp = now
    event.properties["app_version"] = version
    event.properties["os_major"] = String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    return true
  }
}
