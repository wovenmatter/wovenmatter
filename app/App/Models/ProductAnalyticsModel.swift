import CompanionClient
import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

@MainActor @Observable
final class ProductAnalyticsModel {
  private(set) var preference: ProductAnalyticsPreference?
  var errorMessage: String?
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  private var client: MobileProductAnalytics?
  private var database: WorkspaceDatabase?
  private var rpc: BackendRPCClient?
  private var uploads: [UUID: Task<Void, Never>] = [:]
  private var publisher = false
  private var generation = 0
  private var interface = false
  private var locallyDisabled = false
  private var pendingLocalChoice = false
  var enabled: Bool { !locallyDisabled && (preference?.enabled ?? true) }
  private var session = URLSession(configuration: .ephemeral)
  static let updateReceiptKey = "wovenmatter.analytics.pending-update.v1"
  static let projectToken = "phc_ukNR3Tu7AjaLmAVjbapvKsyaB8LdhFwM3vUjM5Jfxpeh"
  func configure(database: WorkspaceDatabase, publisher: Bool) {
    self.database = database
    self.publisher = publisher
  }
  func configure(rpc: BackendRPCClient) { self.rpc = rpc }
  /// The secondary Mac relays updater events through its central library too.
  /// Its interface/open lifecycle belongs to MobileAnalyticsModel.
  func configure(client: MobileProductAnalytics) async {
    self.client = client
    database = nil
    rpc = nil
    cancelUploads()
    interface = true
    await refresh()
  }
  func openInterface() async {
    interface = true
    await refresh()
    await confirmUpdateInstallation()
    await record(.appOpened)
  }
  func refresh() async {
    let epoch = generation
    do {
      if let client {
        let state = await client.snapshot()
        locallyDisabled = state.pendingEnabled != nil || state.preference?.collects != true
        preference = state.preference
      } else if let rpc {
        let current = try JSONDecoder().decode(
          ProductAnalyticsPreference.self,
          from: await rpc.call(method: "analytics.preference", payload: Data(), timeout: 5))
        guard acceptPreference(current, epoch: epoch) else { return }
        if !pendingLocalChoice { locallyDisabled = !current.enabled }
      } else if let database {
        let current = try await database.productAnalyticsPreference()
        guard acceptPreference(current, epoch: epoch) else { return }
        if !pendingLocalChoice { locallyDisabled = !current.enabled }
      }
      await confirmUpdateInstallation()
    } catch { errorMessage = "Analytics settings are temporarily unavailable." }
  }
  private func acceptPreference(_ current: ProductAnalyticsPreference, epoch: Int) -> Bool {
    guard epoch == generation else { return false }
    if let previous = preference, previous.analyticsID == current.analyticsID,
      previous.revision > current.revision { return false }
    preference = current
    return true
  }
  func setEnabled(_ enabled: Bool) async {
    generation += 1
    let epoch = generation
    pendingLocalChoice = true
    locallyDisabled = !enabled
    if !enabled {
      defaults.removeObject(forKey: Self.updateReceiptKey)
      cancelUploads()
    }
    guard let preference else { return }
    do {
      let change = ProductAnalyticsPreferenceChange(
        enabled: enabled, expectedRevision: preference.revision)
      let updated: ProductAnalyticsPreference
      if let rpc {
        updated = try JSONDecoder().decode(
          ProductAnalyticsPreference.self,
          from: await rpc.call(
            method: "analytics.setPreference", payload: JSONEncoder().encode(change), timeout: 5))
      } else if let database {
        updated = try await database.setProductAnalyticsPreference(change)
      } else {
        return
      }
      guard epoch == generation else { return }
      pendingLocalChoice = false
      self.preference = updated
      errorMessage = nil
      if enabled, let database {
        configure(database: database, publisher: !database.isReadOnlyProjection)
      }
      await refresh()
    } catch { errorMessage = "The analytics preference could not be saved. Please retry." }
  }
  func record(_ name: ProductAnalyticsEvent.Name, properties: [String: String] = [:]) async {
    if let client {
      try? await client.record(name, properties: properties, platform: "macos")
      return
    }
    guard !locallyDisabled,
      let preference, preference.collects else {
      return
    }
    // This frontend also avoids making an RPC for every qualifying action.
    // Central admission enforces the same limit across all connected devices.
    if name == .appOpened || name == .active {
      let key = "wovenmatter.analytics.last-attempt." + preference.analyticsID + "." + name.rawValue
      let now = Date()
      if let previous = defaults.object(forKey: key) as? Date,
        now.timeIntervalSince(previous) < ProductAnalyticsEvent.signalInterval { return }
      defaults.set(now, forKey: key)
    }
    var values = properties
    values["platform"] = "macos"
    values["app_version"] =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    values["os_major"] = String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    let event = ProductAnalyticsEvent(
      preferenceRevision: preference.revision, name: name, properties: values)
    await send(event)
  }
  /// One attempt only. Failures never retain an event for later delivery.
  private func send(_ event: ProductAnalyticsEvent) async {
    let epoch = generation
    guard let preference else { return }
    do {
      if let client {
        await client.sendUpdateReceipt(event, analyticsID: preference.analyticsID)
      } else if let rpc {
        let acknowledgement = try JSONDecoder().decode(
          ProductAnalyticsAcknowledgement.self,
          from: await rpc.call(
            method: "analytics.events",
            payload: JSONEncoder().encode(ProductAnalyticsBatch(events: [event], analyticsID: preference.analyticsID)),
            timeout: 5))
        acceptAcknowledgement(acknowledgement, epoch: epoch)
      } else if database != nil {
        acceptAcknowledgement(try await ingest(.init(events: [event], analyticsID: preference.analyticsID)), epoch: epoch)
      }
    } catch { /* Drop failed sends without interrupting a user action. */ }
  }
  private func acceptAcknowledgement(_ acknowledgement: ProductAnalyticsAcknowledgement, epoch: Int) {
    guard acceptPreference(acknowledgement.preference, epoch: epoch) else { return }
    for (name, next) in acknowledgement.nextSignalAt {
      let key = "wovenmatter.analytics.last-attempt." + acknowledgement.preference.analyticsID + "." + name
      defaults.set(next.addingTimeInterval(-ProductAnalyticsEvent.signalInterval), forKey: key)
    }
  }
  func prepareUpdateInstallation(_ manifest: WovenMatterReleaseManifest) async -> UUID {
    await refresh()
    let installationID = UUID()
    defaults.removeObject(forKey: Self.updateReceiptKey)
    guard !locallyDisabled, let preference,
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
    guard interface,
      let data = defaults.data(forKey: Self.updateReceiptKey),
      let receipt = try? JSONDecoder().decode(ProductAnalyticsUpdateReceipt.self, from: data),
      receipt.confirmed
    else { return }
    // Confirmation gets one opportunity, even if settings or the connection are unavailable.
    cancelUpdateInstallation()
    guard let preference else { return }
    // Opt-out, a new preference epoch, or a different library fences the receipt.
    guard !locallyDisabled, preference.collects,
      receipt.analyticsID == preference.analyticsID,
      receipt.event.preferenceRevision == preference.revision else {
      cancelUpdateInstallation()
      return
    }
    guard receipt.version == version, receipt.build == build
    else { return }
    guard receipt.event.validated(preference: preference) != nil else {
      cancelUpdateInstallation()
      return
    }
    await send(receipt.event)
  }
  func ingest(_ batch: ProductAnalyticsBatch) async throws -> ProductAnalyticsAcknowledgement {
    guard let database else { throw WorkspaceDatabaseError.corruptRow }
    let current = try await database.productAnalyticsPreference()
    guard batch.analyticsID == current.analyticsID else {
      return .init(acceptedEventIDs: [], preference: current, discardedEventIDs: batch.events.map(\.id))
    }
    // Concurrent immediate sends are bounded; overflow is dropped, never queued.
    guard publisher, uploads.count < 20 else {
      return .init(acceptedEventIDs: [], preference: try await database.productAnalyticsPreference(),
        discardedEventIDs: batch.events.map(\.id))
    }
    let id = UUID()
    let epoch = generation
    // Reserve a slot before the database await so reentrant calls cannot create a backlog.
    uploads[id] = Task {}
    do {
      let ack = try await database.acceptProductAnalytics(batch.events)
      guard epoch == generation, !locallyDisabled, !Task.isCancelled else {
        uploads.removeValue(forKey: id)
        return .init(acceptedEventIDs: [], preference: ack.preference,
          discardedEventIDs: batch.events.map(\.id))
      }
      var accepted = Set(ack.acceptedEventIDs)
      let events = batch.events.filter { accepted.remove($0.id) != nil }
      guard !events.isEmpty else { uploads.removeValue(forKey: id); return ack }
      uploads[id] = Task { [weak self] in
        guard let self else { return }
        defer { self.uploads.removeValue(forKey: id) }
        await self.upload(events, preference: ack.preference, epoch: epoch)
      }
      return ack
    } catch {
      uploads.removeValue(forKey: id)
      throw error
    }
  }
  private func cancelUploads() {
    uploads.values.forEach { $0.cancel() }
    uploads.removeAll()
    session.invalidateAndCancel()
    session = URLSession(configuration: .ephemeral)
  }
  func change(_ change: ProductAnalyticsPreferenceChange) async throws
    -> ProductAnalyticsPreference
  {
    generation += 1
    let epoch = generation
    if !change.enabled {
      defaults.removeObject(forKey: Self.updateReceiptKey)
      cancelUploads()
    }
    guard let database else { throw WorkspaceDatabaseError.corruptRow }
    let value = try await database.setProductAnalyticsPreference(change)
    if epoch == generation {
      locallyDisabled = !value.enabled
      preference = value
      if value.collects { configure(database: database, publisher: true) }
    }
    return value
  }
  private func upload(_ events: [ProductAnalyticsEvent], preference: ProductAnalyticsPreference, epoch: Int) async {
    guard let database, !database.isReadOnlyProjection else { return }
    var status = "dropped"
    #if DEBUG
      status = "not sent (Debug build)"
    #else
      do {
        let current = try await database.productAnalyticsPreference()
        guard epoch == generation, current.collects, current.revision == preference.revision,
          !locallyDisabled, !Task.isCancelled else { return }
        let batch = events.compactMap { $0.validated(preference: current) }
          .map { $0.postHogObject(analyticsID: current.analyticsID) }
        guard !batch.isEmpty else { return }
        var request = URLRequest(url: URL(string: "https://us.i.posthog.com/batch/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
          "api_key": Self.projectToken, "batch": batch,
        ])
        let (_, response) = try await session.data(for: request)
        if let response = response as? HTTPURLResponse,
          (200..<300).contains(response.statusCode) { status = "delivered" }
      } catch { /* Offline and failed sends are dropped permanently. */ }
    #endif
    try? await database.markProductAnalytics(events.map(\.id), status: status)
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
