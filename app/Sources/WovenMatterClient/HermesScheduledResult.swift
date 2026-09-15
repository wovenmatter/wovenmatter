import Foundation

public struct HermesScheduledResult: Codable, Identifiable, Sendable {
  public let jobID: String
  public let runID: String
  public let output: String
  public let savedAt: Double
  public var id: String { jobID + ":" + runID }
  public init(jobID: String, runID: String, output: String, savedAt: Double) {
    self.jobID = jobID
    self.runID = runID
    self.output = output
    self.savedAt = savedAt
  }
}

public enum HermesDelivery {
  public static func profileQuery(connection: HermesGatewayConnection) async throws -> String {
    let document = try await HermesSessionHistory.fetch(
      connection: connection, path: "/api/profiles")
    guard case .array(let profiles) = document["profiles"],
      let profile = profiles.first(where: {
        URL(fileURLWithPath: $0["path"].text).standardizedFileURL.path
          == URL(fileURLWithPath: connection.home).standardizedFileURL.path
      }),
      let name = profile["name"].string, !name.isEmpty,
      let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    else {
      throw HermesGatewayError.message("Hermes did not identify this profile for scheduled jobs.")
    }
    return "?profile=" + encoded
  }

  public static func installLocalPlugin(home: String) throws {
    let relative = "harnesses/hermes-delivery"
    let candidates = [
      Bundle.main.resourceURL?.appending(path: relative),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: relative),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(
        path: "../" + relative),
    ]
    guard
      let source = candidates.compactMap({ $0 }).first(where: {
        FileManager.default.fileExists(atPath: $0.appending(path: "plugin.yaml").path)
      })
    else {
      throw HermesGatewayError.message("The bundled Hermes delivery plugin is missing.")
    }
    let target = URL(fileURLWithPath: home).appending(path: "plugins/wovenmatter-delivery")
    try FileManager.default.createDirectory(
      at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for name in ["plugin.yaml", "__init__.py"] {
      let bytes = try Data(contentsOf: source.appending(path: name))
      try bytes.write(to: target.appending(path: name), options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: target.appending(path: name).path)
    }
  }

  public static func enable(connection: HermesGatewayConnection) async throws -> Bool {
    if connection.remoteWorkspaceID == nil { try installLocalPlugin(home: connection.home) }
    let config = try await HermesSessionHistory.fetch(
      connection: connection, path: "/api/config?include_defaults=false")
    // Native GET returns the config document; PUT deep-merges just these keys.
    let document = config["config"].isNull ? config : config["config"]
    var enabled = document["plugins"]["enabled"].array.compactMap(\.string)
    if !enabled.contains("wovenmatter-delivery") { enabled.append("wovenmatter-delivery") }
    guard !document["plugins"]["disabled"].array.contains(.string("wovenmatter-delivery")) else {
      throw HermesGatewayError.message(
        "Hermes explicitly disables the Woven Matter delivery plugin. Enable it in the profile before collecting results."
      )
    }
    _ = try await HermesSessionHistory.fetch(
      connection: connection, path: "/api/config", method: "PUT",
      body: [
        "config": [
          "plugins": ["enabled": .array(enabled.map(HermesValue.string))],
          "platforms": ["wovenmatter": ["enabled": .bool(true)]],
        ]
      ])
    // A previous enable may have saved the config but failed its idle restart.
    // Inspect this process so retrying still loads the newly enabled plugin.
    let rpc = HermesGatewayRPC(connection: connection)
    do {
      try await rpc.connect()
      let loaded = try await rpc.call("plugins.list")
      await rpc.disconnect()
      guard case .array(let plugins) = loaded["plugins"] else {
        throw HermesGatewayError.message("Hermes did not report its loaded delivery plugins.")
      }
      return !plugins.contains { $0["name"].text == "wovenmatter-delivery" && $0["enabled"].bool }
    } catch {
      await rpc.disconnect()
      throw error
    }
  }
}
