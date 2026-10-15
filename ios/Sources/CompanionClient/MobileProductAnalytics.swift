import Foundation
import WovenMatterCompanion

public struct MobileProductAnalyticsState: Codable, Sendable {
  public var preference: ProductAnalyticsPreference?
  public var pendingEnabled: Bool?
  public var pendingRevision: Int64?
  public var lastAttempts: [String: Date]?
  public init() {}
}
/// Persists privacy choices and two signal timestamps; never an event queue.
public actor MobileProductAnalytics {
  private let file: URL
  private var state: MobileProductAnalyticsState
  private var transport: (any ProductAnalyticsTransport)?
  private var sends: [UUID: Task<Void, Never>] = [:]
  private var choiceGeneration = 0
  public init(file: URL) throws {
    self.file = file
    // A damaged telemetry file must not prevent the content library from opening.
    // Reset without an identity, so collection waits for the central preference.
    state =
      (try? JSONDecoder().decode(MobileProductAnalyticsState.self, from: Data(contentsOf: file)))
      ?? .init()
  }
  public func snapshot() -> MobileProductAnalyticsState {
    return state
  }
  public func setEnabled(_ enabled: Bool) throws {
    state.pendingEnabled = enabled
    state.pendingRevision = state.preference?.revision
    cancelSends()
    try persist()
  }
  public func apply(_ preference: ProductAnalyticsPreference) throws {
    // Reentrant requests may finish out of order. Never roll back a known
    // privacy epoch for the same library.
    if let previous = state.preference, previous.analyticsID == preference.analyticsID,
      previous.revision > preference.revision { return }
    if let previous = state.preference, previous.analyticsID != preference.analyticsID {
      state.pendingEnabled = nil
      state.pendingRevision = nil
      cancelSends()
      state.lastAttempts = nil
    }
    if state.preference?.revision != preference.revision || !preference.collects {
      cancelSends()
    }
    state.preference = preference
    try persist()
  }
  public func record(
    _ name: ProductAnalyticsEvent.Name, properties: [String: String] = [:], platform: String
  ) throws {
    guard state.pendingEnabled == nil, let preference = state.preference,
      preference.collects
    else { return }
    var values = properties
    values["platform"] = platform
    values["app_version"] =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    values["os_major"] = String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    send(ProductAnalyticsEvent(preferenceRevision: preference.revision, name: name, properties: values))
  }
  public func sendUpdateReceipt(_ event: ProductAnalyticsEvent, analyticsID: String) {
    guard state.preference?.analyticsID == analyticsID, event.name == .updateInstallCompleted else { return }
    send(event)
  }
  private func send(_ event: ProductAnalyticsEvent) {
    guard let transport, state.pendingEnabled == nil,
      let preference = state.preference, let event = event.validated(preference: preference),
      sends.count < 20 else { return }
    let now = Date()
    if event.rateLimited {
      if let previous = state.lastAttempts?[event.name.rawValue],
        now.timeIntervalSince(previous) < ProductAnalyticsEvent.signalInterval { return }
      if state.lastAttempts == nil { state.lastAttempts = [:] }
      state.lastAttempts?[event.name.rawValue] = now
    }
    let generation = choiceGeneration
    try? persist()
    let id = UUID()
    sends[id] = Task {
      defer { sends.removeValue(forKey: id) }
      do {
        try Task.checkCancellation()
        let ack = try await transport.sendAnalytics(.init(events: [event], analyticsID: preference.analyticsID))
        try Task.checkCancellation()
        guard generation == choiceGeneration else { return }
        try apply(ack.preference)
        if state.lastAttempts == nil { state.lastAttempts = [:] }
        for (name, next) in ack.nextSignalAt {
          state.lastAttempts?[name] = next.addingTimeInterval(-ProductAnalyticsEvent.signalInterval)
        }
        try? persist()
      } catch { /* No retention, retry, or replay. */ }
    }
  }
  public func connect(using transport: (any ProductAnalyticsTransport)?) {
    cancelSends()
    self.transport = transport
  }
  public func synchronizePreference() async throws {
    guard let transport else { return }
    try await synchronize(using: transport)
  }
  public func disconnect() {
    transport = nil
    cancelSends()
  }
  public func recordCommand(_ command: CompanionCommand) throws {
    let name: ProductAnalyticsEvent.Name
    switch command.kind {
    case .createSession, .send, .steer: name = .active
    default: return
    }
    #if os(iOS)
      let platform = "ios"
    #else
      let platform = "macos"
    #endif
    try record(name, platform: platform)
  }
  public func synchronize(using transport: any ProductAnalyticsTransport) async throws {
    let generation = choiceGeneration
    if let enabled = state.pendingEnabled {
      let current = try await transport.analyticsPreference()
      try Task.checkCancellation()
      guard generation == choiceGeneration else { return }
      if let previous = state.preference, previous.analyticsID != current.analyticsID {
        try apply(current)
        return
      }
      // A cached, older opt-in must not overwrite a newer choice.
      if enabled, let revision = state.pendingRevision, revision != current.revision {
        state.pendingEnabled = nil
        state.pendingRevision = nil
        try apply(current)
        return
      }
      let result = try await transport.setAnalyticsPreference(
        .init(
          enabled: enabled, expectedRevision: state.pendingRevision ?? current.revision))
      // An opt-out made while the request was suspended must survive this response.
      try Task.checkCancellation()
      guard generation == choiceGeneration else { return }
      if state.pendingEnabled == enabled {
        state.pendingEnabled = nil
        state.pendingRevision = nil
      }
      try apply(result)
    } else {
      let current = try await transport.analyticsPreference()
      try Task.checkCancellation()
      guard generation == choiceGeneration else { return }
      try apply(current)
    }
    self.transport = transport
  }
  private func cancelSends() {
    choiceGeneration += 1
    sends.values.forEach { $0.cancel() }
    sends.removeAll()
  }
  private func persist() throws {
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
    try await request("v1/analytics/preference", timeout: 5)
  }
  public func setAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) async throws
    -> ProductAnalyticsPreference
  {
    try await request("v1/analytics/preference", method: "POST", body: JSONEncoder().encode(change), timeout: 5)
  }
  public func sendAnalytics(_ batch: ProductAnalyticsBatch) async throws
    -> ProductAnalyticsAcknowledgement
  { try await request("v1/analytics/events", method: "POST", body: JSONEncoder().encode(batch), timeout: 5) }
}
