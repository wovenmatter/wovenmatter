import Foundation
import WovenLibrary
import WovenProtocol

extension Library {
  /// The Pi Durable settings for this machine or device: its own
  /// `piDurable.<id>` else the shared `piDurable`, with `defaultModel` from
  /// its own `agentDefaults.piDurable.<id>` else the shared one. Nil when
  /// the setting is not an object.
  public func piDurableSettings() async -> [String: JSONValue]? {
    func setting(_ key: String) async -> JSONValue? { (try? await self.setting(key))?.value }
    var settings = await setting("piDurable.\(machineID)")
    if settings == nil { settings = await setting("piDurable") }
    var defaults = await setting("agentDefaults.piDurable.\(machineID)")
    if defaults == nil { defaults = await setting("agentDefaults.piDurable") }
    guard case .object(var fields) = settings ?? .object([:]) else { return nil }
    fields["defaultModel"] = defaults?["model"]
    return fields
  }
}
