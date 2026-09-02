import Foundation
import WovenMatterCore

public struct UsageProviderPreferences {
  public static let storageKey = "wovenmatter.usage.enabled-providers"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var enabledProviders: Set<ProviderKind> {
    guard defaults.object(forKey: Self.storageKey) != nil else {
      return Set(ProviderKind.supportedAccounts)
    }
    return Set(
      defaults.stringArray(forKey: Self.storageKey)?
        .compactMap(ProviderKind.init(rawValue:)) ?? []
    )
  }

  public func save(_ providers: Set<ProviderKind>) {
    defaults.set(
      providers.map(\.rawValue).sorted(),
      forKey: Self.storageKey
    )
  }
}
