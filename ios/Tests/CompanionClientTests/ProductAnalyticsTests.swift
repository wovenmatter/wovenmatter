import Foundation
import Testing
import WovenMatterCompanion

@testable import CompanionClient

@Suite("Client analytics privacy") struct ProductAnalyticsClientTests {
  @Test(
    "offline disabling stops local events and removes queued activity; enabling never backfills")
  func offline() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let store = try MobileProductAnalytics(file: file)
    let p = ProductAnalyticsPreference(
      analyticsID: UUID().uuidString, disclosedAt: Date().addingTimeInterval(-60))
    try await store.apply(p)
    try await store.record(.appOpened, platform: "ios")
    #expect(await store.snapshot().events.isEmpty)
    try await store.disclose(enabled: true)
    let transport = AnalyticsFixture(preference: p)
    try await store.synchronize(using: transport)
    try await store.record(
      .contentChanged, properties: ["action": "edit", "content": "private"], platform: "ipados")
    try await store.record(.contentChanged, properties: ["action": "edit"], platform: "ipados")
    #expect(await store.snapshot().events.count == 1)
    try await store.setEnabled(false)
    try await store.record(.messageSubmitted, platform: "ios")
    #expect(await store.snapshot().events.isEmpty)
    let reopened = try MobileProductAnalytics(file: file)
    #expect(await reopened.snapshot().pendingEnabled == false)
    try await reopened.synchronize(using: transport)
    #expect(await transport.sent.isEmpty)
    #expect(await reopened.snapshot().preference?.enabled == false)
    try await reopened.setEnabled(true)
    try await reopened.record(.messageSubmitted, platform: "ios")
    #expect(await reopened.snapshot().events.isEmpty)
    try await reopened.synchronize(using: transport)
    try await reopened.record(.messageSubmitted, platform: "ios")
    try await reopened.synchronize(using: transport)
    #expect(await transport.sent.count == 1)
    #expect(await transport.sent.first?.properties["platform"] == "ios")
  }
  @Test("a damaged analytics file does not block startup or resume collection")
  func damagedFile() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("invalid telemetry".utf8).write(to: file)
    let store = try MobileProductAnalytics(file: file)
    try await store.record(.messageSubmitted, platform: "ios")
    let state = await store.snapshot()
    #expect(state.preference == nil)
    #expect(!state.disclosed)
    #expect(state.events.isEmpty)
  }
  @Test("a stale offline opt-in cannot override a newer central opt-out")
  func staleOptIn() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let store = try MobileProductAnalytics(file: file)
    let p = ProductAnalyticsPreference(
      analyticsID: UUID().uuidString, disclosedAt: Date().addingTimeInterval(-60))
    try await store.apply(p)
    try await store.disclose(enabled: true)
    let fixture = AnalyticsFixture(preference: p)
    _ = await fixture.setAnalyticsPreference(.init(enabled: false, expectedRevision: p.revision))
    try await store.synchronize(using: fixture)
    #expect(await fixture.preference.enabled == false)
    #expect(await store.snapshot().pendingEnabled == nil)
    #expect(await store.snapshot().preference?.enabled == false)
  }
  @Test("an in-flight enable acknowledgement cannot erase a newer opt-out")
  func choiceRace() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let store = try MobileProductAnalytics(file: file)
    let p = ProductAnalyticsPreference(
      analyticsID: UUID().uuidString, disclosedAt: Date().addingTimeInterval(-60))
    try await store.apply(p)
    try await store.disclose(enabled: true)
    let fixture = AnalyticsFixture(preference: p)
    await fixture.pauseNextPreferenceUpdate()
    let synchronization = Task { try await store.synchronize(using: fixture) }
    await fixture.waitForUpdate()
    try await store.setEnabled(false)
    await fixture.finishUpdate()
    try await synchronization.value
    #expect(await store.snapshot().pendingEnabled == false)
    try await store.record(.messageSubmitted, platform: "ios")
    #expect(await store.snapshot().events.isEmpty)
    try await store.synchronize(using: fixture)
    #expect(await store.snapshot().preference?.enabled == false)
    #expect(await fixture.sent.isEmpty)
  }

}
private actor AnalyticsFixture: ProductAnalyticsTransport {
  var preference: ProductAnalyticsPreference
  var sent: [ProductAnalyticsEvent] = []
  private var pause = false
  private var waiting: CheckedContinuation<Void, Never>?
  func pauseNextPreferenceUpdate() { pause = true }
  func waitForUpdate() async { while waiting == nil { await Task.yield() } }
  func finishUpdate() {
    pause = false
    waiting?.resume()
    waiting = nil
  }
  init(preference: ProductAnalyticsPreference) { self.preference = preference }
  func analyticsPreference() -> ProductAnalyticsPreference { preference }
  func setAnalyticsPreference(_ change: ProductAnalyticsPreferenceChange) async
    -> ProductAnalyticsPreference
  {
    if pause { await withCheckedContinuation { waiting = $0 } }
    if preference.enabled != change.enabled {
      preference.enabled = change.enabled
      preference.revision += 1
      preference.disclosedAt = Date()
    }
    return preference
  }
  func sendAnalytics(_ batch: ProductAnalyticsBatch) -> ProductAnalyticsAcknowledgement {
    sent += batch.events
    return .init(acceptedEventIDs: batch.events.map(\.id), preference: preference)
  }
}
