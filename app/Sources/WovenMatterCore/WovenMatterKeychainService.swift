import Foundation

public enum WovenMatterKeychainService {
  public static func name(forBundleIdentifier bundleIdentifier: String?) -> String {
    if let bundleIdentifier, bundleIdentifier == "wovenmatter.desktop.dev" || bundleIdentifier.hasPrefix("wovenmatter.desktop.dev.") {
      return "Woven Matter." + String(bundleIdentifier.dropFirst("wovenmatter.".count))
    }
    return "Woven Matter.desktop"
  }

  public static var current: String {
    name(forBundleIdentifier: Bundle.main.bundleIdentifier)
  }
}
