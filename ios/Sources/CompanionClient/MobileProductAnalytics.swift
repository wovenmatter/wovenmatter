import Foundation
import WovenMatterCompanion

public struct MobileProductAnalyticsState: Codable, Sendable {
  public var preference: ProductAnalyticsPreference?
  public var disclosed = false
  public var pendingEnabled: Bool?
  public var pendingRevision: Int64?
  public var events: [ProductAnalyticsEvent] = []
  public var log: [ProductAnalyticsLogEntry] = []
  public init() {}
}
/// Separate bounded file: user content and operational identities never enter telemetry.
public actor MobileProductAnalytics {
  private let file: URL
  private var state: MobileProductAnalyticsState
  private var lastEdit: Date?
  private var choiceGeneration = 0
  public init(file: URL) throws {
    self.file = file
    // A damaged telemetry file must not prevent the content library from opening.
    // Reset without disclosure or an identity, so collection remains suspended.
    state =
      (try? JSONDecoder().decode(MobileProductAnalyticsState.self, from: Data(contentsOf: file)))
      ?? .init()
  }
  public func snapshot() -> MobileProductAnalyticsState {
    if state.events.contains(where: { $0.timestamp < Date().addingTimeInterval(-7 * 86400) }) {
      try? persist()
    }
    return state
  }
  public func disclose(enabled: Bool) throws {
    state.disclosed = true
    try setEnabled(enabled && (state.preference?.enabled ?? true))
  }
  public func setEnabled(_ enabled: Bool) throws {
    choiceGeneration += 1
    state.pendingEnabled = enabled
    state.pendingRevision = state.preference?.revision
    discardPending()
    try persist()
  }
  public func apply(_ preference: ProductAnalyticsPreference) throws {
    if let previous = state.preference, previous.analyticsID != preference.analyticsID {
      state.disclosed = false
      state.pendingEnabled = nil
      state.pendingRevision = nil
      discardPending()
      state.log.removeAll()
      lastEdit = nil
    }
    if state.preference?.revision != preference.revision || !preference.collects {
      discardPending()
    }
    state.preference = preference
    try persist()
  }
  public func record(
    _ name: ProductAnalyticsEvent.Name, properties: [String: String] = [:], platform: String
  ) throws {
    guard state.disclosed, state.pendingEnabled == nil, let preference = state.preference,
      preference.collects
    else { return }
    let now = Date()
    if name == .contentChanged, properties["action"] == "edit" {
      if let lastEdit, now.timeIntervalSince(lastEdit) < 30 { return }
      lastEdit = now
    }
    var values = properties
    values["platform"] = platform
    values["app_version"] =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    values["os_major"] = String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    let event = ProductAnalyticsEvent(
      preferenceRevision: preference.revision, name: name, properties: values)
    state.events.append(event)
    state.events = Array(state.events.suffix(1000))
    state.log.append(.init(event: event, status: "pending"))
    state.log = Array(state.log.suffix(500))
    try persist()
  }
  /// Durable updater acknowledgements keep the original UUID on retry. A privacy
  /// rejection consumes the receipt without retaining it for later backfill.
  public func enqueueUpdateReceipt(_ event: ProductAnalyticsEvent, analyticsID: String) throws -> Bool {
    guard state.disclosed, state.pendingEnabled == nil, let preference = state.preference,
      preference.analyticsID == analyticsID,
      event.name == .updateInstallCompleted,
      let value = event.validated(preference: preference) else { return true }
    if state.log.contains(where: { $0.id == value.id }) { return true }
    state.events.append(value)
    state.events = Array(state.events.suffix(1000))
    state.log.append(.init(event: value, status: "pending"))
    state.log = Array(state.log.suffix(500))
    try persist()
    return true
  }
  public func recordCommand(_ command: CompanionCommand) throws {
    let name: ProductAnalyticsEvent.Name
    switch command.kind {
    case .createSession: name = .sessionCreated
    case .send, .steer: name = .messageSubmitted
    default: return
    }
    #if os(iOS)
      let platform = "ios"
    #else
      let platform = "macos"
    #endif
    try record(name, platform: platform)
  }
  public func acknowledge(_ ack: ProductAnalyticsAcknowledgement) throws {
    let ids = Set(ack.acceptedEventIDs + ack.discardedEventIDs)
    state.events.removeAll { ids.contains($0.id) }
    for index in state.log.indices where ids.contains(state.log[index].id) {
      state.log[index].status =
        ack.discardedEventIDs.contains(state.log[index].id)
        ? "discarded by central library" : "central library accepted"
    }
    try apply(ack.preference)
  }
  public func synchronize(using transport: any ProductAnalyticsTransport) async throws {
    if let enabled = state.pendingEnabled {
      let generation = choiceGeneration
      let current = try await transport.analyticsPreference()
      guard generation == choiceGeneration else { return }
      if let previous = state.preference, previous.analyticsID != current.analyticsID {
        try apply(current)
        return
      }
      // A disclosure adopts an existing library opt-out. A cached, older opt-in
      // must not overwrite a newer choice merely because we refreshed first.
      if enabled, let revision = state.pendingRevision, revision != current.revision {
        state.pendingEnabled = nil
        state.pendingRevision = nil
        try apply(current)
        return
      }
      let effectiveEnabled = enabled && state.pendingRevision == nil ? current.enabled : enabled
      let result = try await transport.setAnalyticsPreference(
        .init(
          enabled: effectiveEnabled, expectedRevision: state.pendingRevision ?? current.revision,
          acknowledgeDisclosure: state.disclosed))
      // An opt-out made while the request was suspended must survive this response.
      guard generation == choiceGeneration else { return }
      if state.pendingEnabled == enabled {
        state.pendingEnabled = nil
        state.pendingRevision = nil
      }
      try apply(result)
    } else {
      try apply(await transport.analyticsPreference())
    }
    guard state.pendingEnabled == nil, state.disclosed, state.preference?.collects == true else {
      return
    }
    let events = Array(state.events.prefix(100))
    if !events.isEmpty {
      let generation = choiceGeneration
      let acknowledgement = try await transport.sendAnalytics(.init(events: events))
      guard generation == choiceGeneration else { return }
      try acknowledge(acknowledgement)
    }
  }
  private func discardPending() {
    state.events.removeAll()
    for index in state.log.indices where state.log[index].status == "pending" {
      state.log[index].status = "discarded after preference change"
    }
  }
  private func persist() throws {
    state.events.removeAll { $0.timestamp < Date().addingTimeInterval(-7 * 86400) }
    try MobileStorePersistence.writeDurably(JSONEncoder().encode(state), at: file)
  }
}
public protocol ProductAnalyticsTransport: Sendable {
  func analyticsPreference() async throws -> ProductAnalyticsPreference
  func setAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) async throws
    -> ProductAnalyticsPreference
  func sendAnalytics(_ batch: ProductAnalyticsBatch) async throws -> ProductAnalyticsAcknowledgement
}
extension HTTPSCompanionTransport: ProductAnalyticsTransport {
  public func analyticsPreference() async throws -> ProductAnalyticsPreference {
    try await request("v1/analytics/preference")
  }
  public func setAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) async throws
    -> ProductAnalyticsPreference
  {
    try await request("v1/analytics/preference", method: "POST", body: JSONEncoder().encode(change))
  }
  public func sendAnalytics(_ batch: ProductAnalyticsBatch) async throws
    -> ProductAnalyticsAcknowledgement
  { try await request("v1/analytics/events", method: "POST", body: JSONEncoder().encode(batch)) }
}
