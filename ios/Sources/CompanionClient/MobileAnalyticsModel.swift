import Foundation
import Observation
import WovenMatterCompanion

@MainActor @Observable public final class MobileAnalyticsModel {
  public private(set) var state = MobileProductAnalyticsState()
  public var errorMessage: String?
  private var store: MobileProductAnalytics?
  private var interface = false
  public init() {}
  public var enabled: Bool { state.pendingEnabled ?? state.preference?.enabled ?? true }
  public func configure(_ store: MobileProductAnalytics, transport: (any ProductAnalyticsTransport)? = nil) async {
    self.store = store
    await store.connect(using: transport)
    await refresh()
    if interface { await openInterface() }
  }
  public func openInterface() async {
    interface = true
    await refresh()
    await record(.appOpened)
  }
  public func refresh() async {
    guard let store else { return }
    state = await store.snapshot()
  }
  public func setEnabled(_ enabled: Bool) async {
    guard let store else { return }
    do {
      try await store.setEnabled(enabled)
      await refresh()
      try? await store.synchronizePreference()
      errorMessage = nil
      await refresh()
    } catch { errorMessage = "The analytics preference could not be saved. Please retry." }
  }
  public func record(_ name: ProductAnalyticsEvent.Name, properties: [String: String] = [:]) async {
    #if os(iOS)
      let platform = "ios"
    #else
      let platform = "macos"
    #endif
    try? await store?.record(name, properties: properties, platform: platform)
  }
}
