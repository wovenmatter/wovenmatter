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

  /// Remote workspace tokens. Production keeps its original service name; a Dev
  /// build uses its own, so it never reads (or prompts for) production's tokens.
  public static func remoteWorkspaces(forBundleIdentifier bundleIdentifier: String?) -> String {
    let namespace = name(forBundleIdentifier: bundleIdentifier)
    return namespace == "Woven Matter.desktop" ? "com.wovenmatter.remote-workspaces" : namespace + ".remote-workspaces"
  }

  public static var remoteWorkspaces: String {
    remoteWorkspaces(forBundleIdentifier: Bundle.main.bundleIdentifier)
  }
}
