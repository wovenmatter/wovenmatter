import Foundation

public enum WovenMatterKeychainService {
  public static func name(forBundleIdentifier bundleIdentifier: String?) -> String {
    bundleIdentifier == "wovenmatter.desktop.dev"
      ? "Woven Matter.desktop.dev"
      : "Woven Matter.desktop"
  }

  public static var current: String {
    name(forBundleIdentifier: Bundle.main.bundleIdentifier)
  }
}
