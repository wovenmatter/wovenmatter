import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore

@Suite("Product analytics privacy and persistence")
struct ProductAnalyticsTests {
  @Test(
    "one independent random identity persists per central database; disclosure precedes capture")
  func identity() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("library.sqlite")
    let db = try await WorkspaceDatabase(url: url)
    let p = try await db.productAnalyticsPreference()
    #expect(p.enabled && !p.collects)
    #expect(UUID(uuidString: p.analyticsID) != nil)
    #expect(p.analyticsID != (try await db.companionWorkspaceID()))
    let event = ProductAnalyticsEvent(preferenceRevision: p.revision, name: .appOpened)
    #expect(try await db.enqueueProductAnalytics([event]).acceptedEventIDs.isEmpty)
    let restarted = try await WorkspaceDatabase(url: url)
    #expect(try await restarted.productAnalyticsPreference() == p)
    let second = try await WorkspaceDatabase(url: dir.appendingPathComponent("other.sqlite"))
    #expect(try await second.productAnalyticsPreference().analyticsID != p.analyticsID)
  }
  @Test("multiple devices retry one event; opt-out clears pending and fences delayed uploads")
  func epochs() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try await WorkspaceDatabase(url: dir.appendingPathComponent("library.sqlite"))
    let initial = try await db.productAnalyticsPreference()
    let on = try await db.setProductAnalyticsPreference(
      .init(enabled: true, expectedRevision: initial.revision, acknowledgeDisclosure: true))
    var malicious = ProductAnalyticsEvent(preferenceRevision: on.revision, name: .contentChanged)
    malicious.properties = [
      "action": "edit", "item_category": "note", "content": "PRIVATE", "$ip": "127.0.0.1",
      "provider": "alice@example.com", "model": "CUSTOM", "harness": "pi",
    ]
    _ = try await db.enqueueProductAnalytics([malicious, malicious])
    let log = try await db.productAnalyticsLog()
    #expect(log.count == 1)
    #expect(
      log[0].event.properties == ["action": "edit", "item_category": "note", "harness": "pi"])
    #expect(log[0].event.qualifying)
    let off = try await db.setProductAnalyticsPreference(.init(enabled: false, expectedRevision: 0))
    #expect(!off.collects && off.analyticsID == on.analyticsID)
    #expect(try await db.productAnalyticsLog().isEmpty)
    #expect(try await db.enqueueProductAnalytics([malicious]).discardedEventIDs == [malicious.id])
    await #expect(throws: (any Error).self) {
      try await db.setProductAnalyticsPreference(
        .init(enabled: true, expectedRevision: on.revision))
    }
    let again = try await db.setProductAnalyticsPreference(
      .init(enabled: true, expectedRevision: off.revision))
    #expect(try await db.enqueueProductAnalytics([malicious]).acceptedEventIDs.isEmpty)
    let future = ProductAnalyticsEvent(preferenceRevision: again.revision, name: .sessionCreated)
    _ = try await db.enqueueProductAnalytics([future])
    try await db.markProductAnalyticsDelivered([future.id])
    #expect(try await db.productAnalyticsLog().first?.status == "delivered")
  }
  @Test(
    "opened and completed runs never qualify; free-form fields and stale timestamps are excluded")
  func boundary() {
    let p = ProductAnalyticsPreference(
      analyticsID: UUID().uuidString, disclosedAt: Date().addingTimeInterval(-20))
    #expect(!ProductAnalyticsEvent(preferenceRevision: 1, name: .appOpened).qualifying)
    #expect(!ProductAnalyticsEvent(preferenceRevision: 1, name: .agentRunCompleted).qualifying)
    #expect(ProductAnalyticsEvent(preferenceRevision: 1, name: .messageSubmitted).qualifying)
    #expect(
      ProductAnalyticsEvent(
        timestamp: Date().addingTimeInterval(-100), preferenceRevision: 1, name: .messageSubmitted
      ).validated(preference: p) == nil)
    #expect(
      ProductAnalyticsEvent(id: "PRIVATE", preferenceRevision: 1, name: .appOpened).validated(
        preference: p) == nil)
    #expect(
      ProductAnalyticsEvent.sanitize([
        "app_version": "1.2.3", "os_major": "26", "country": "US", "title": "secret",
        "endpoint": "https://private", "error_class": "runtime",
      ]) == ["app_version": "1.2.3", "os_major": "26", "error_class": "runtime"])
  }
}
