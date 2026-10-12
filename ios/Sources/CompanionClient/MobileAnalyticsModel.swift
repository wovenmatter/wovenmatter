import Foundation
import Observation
import WovenMatterCompanion

@MainActor @Observable public final class MobileAnalyticsModel {
  public private(set) var state = MobileProductAnalyticsState()
  public var disclosurePresented = false
  public var errorMessage: String?
  private var store: MobileProductAnalytics?
  private var opened = false
  private var interface = false
  public init() {}
  public var enabled: Bool { state.pendingEnabled ?? state.preference?.enabled ?? true }
  public func configure(_ store: MobileProductAnalytics) async {
    self.store = store
    await refresh()
  }
  public func openInterface() async {
    interface = true
    await refresh()
  }
  public func refresh() async {
    guard let store else { return }
    state = await store.snapshot()
    disclosurePresented = !state.disclosed
    if interface, state.disclosed, !opened, state.pendingEnabled == nil, state.preference?.collects == true {
      opened = true
      await record(.appOpened)
    }
  }
  public func setEnabled(_ enabled: Bool, disclose: Bool = false) async {
    guard let store else { return }
    do {
      if disclose {
        try await store.disclose(enabled: enabled)
      } else {
        try await store.setEnabled(enabled)
      }
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
