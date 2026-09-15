import Foundation
import SQLite3
import WovenMatterClient

/// Reads the selected local configuration without writing it or changing Serve.
/// Credentials stay in memory and are never included in the persisted endpoint.
struct OpenClawLocalGatewayConfiguration {
  let configURL: URL
  let port: Int
  let token: String?
  let password: String?

  init(environment: [String: String]) throws {
    func reject(_ detail: String) -> OpenClawGatewayClientError {
      .rejected("Local Gateway configuration: " + detail)
    }
    let home = environment["OPENCLAW_HOME"] ?? environment["HOME"] ?? NSHomeDirectory()
    func path(_ value: String) -> URL {
      URL(fileURLWithPath: value.hasPrefix("~/") ? home + String(value.dropFirst()) : value)
    }
    let profile = environment["OPENCLAW_PROFILE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let suffix = profile.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
    if let suffix, suffix.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) == nil {
      throw reject("invalid profile name.")
    }
    let state = environment["OPENCLAW_STATE_DIR"] ?? home + "/.openclaw" + (suffix.map { "-" + $0 } ?? "")
    configURL = path(environment["OPENCLAW_CONFIG_PATH"] ?? state + "/openclaw.json")
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = true
    let root: [String: GatewayJSONValue]
    do { root = try decoder.decode(GatewayJSONValue.self, from: Data(contentsOf: configURL)).objectValue ?? [:] }
    catch { throw reject("could not read the selected openclaw.json. Complete OpenClaw setup before linking.") }
    guard root["$include"] == nil, let gateway = root["gateway"]?.objectValue,
          gateway["$include"] == nil else {
      throw reject("a directly readable local gateway configuration is required; included Gateway settings are not supported yet.")
    }
    guard gateway["mode"]?.stringValue == "local" else {
      throw reject("the selected Gateway is not configured in local mode.")
    }
    guard gateway["bind"]?.stringValue != "custom", gateway["tls"]?.objectValue?["enabled"]?.boolValue != true else {
      throw reject("custom-bind and TLS endpoints require an explicit connection; no listener was changed.")
    }
    var defaultPort = 18_789
    if let suffix {
      var hash: UInt32 = 2_166_136_261
      for byte in suffix.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
      defaultPort = 20_000 + Int(hash % 40_000)
    }
    port = environment["OPENCLAW_GATEWAY_PORT"].flatMap(Int.init) ?? gateway["port"]?.intValue ?? defaultPort
    guard (1...65535).contains(port) else { throw reject("invalid port.") }
    let auth = gateway["auth"]?.objectValue ?? [:]
    func credential(_ name: String, envKey: String) throws -> String? {
      let raw: String?
      if let object = auth[name]?.objectValue {
        guard let id = object["id"]?.stringValue else { throw reject("invalid authentication reference.") }
        if object["source"]?.stringValue == "store" {
          raw = try Self.storedCredential(id: id, databaseURL: path(state).appending(path: "state/openclaw.sqlite"))
        } else if object["source"]?.stringValue == "env", let value = environment[id], !value.isEmpty {
          raw = value
        } else { throw reject("the Gateway \(name) SecretRef is not available through the local store or app environment.") }
      } else { raw = auth[name]?.stringValue ?? environment[envKey] }
      guard var value = raw else { return nil }
      let expression = try NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
      for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
        guard let range = Range(match.range(at: 1), in: value), let replacement = environment[String(value[range])],
              let full = Range(match.range, in: value) else { throw reject("an authentication environment variable is unavailable.") }
        value.replaceSubrange(full, with: replacement)
      }
      return value.isEmpty ? nil : value
    }
    let mode = auth["mode"]?.stringValue
    if mode == "none" { token = nil; password = nil }
    else {
      // Read only the credential relevant to the selected authentication mode.
      password = mode == "token" ? nil : try credential("password", envKey: "OPENCLAW_GATEWAY_PASSWORD")
      token = mode == "password" || password != nil ? nil : try credential("token", envKey: "OPENCLAW_GATEWAY_TOKEN")
      guard mode != "trusted-proxy" else { throw reject("trusted-proxy authentication cannot be bypassed with a direct loopback connection.") }
      guard token != nil || password != nil else {
        throw reject("the configured authentication is unavailable. Configure local OpenClaw authentication before linking; Woven will not replace it.")
      }
    }
  }

  private static func storedCredential(id: String, databaseURL: URL) throws -> String {
    // Same team-scoped lookup as OpenClaw 2026.9.4 readSecretStoreValue.
    // Read-only open: no schema initialization, migration, or credential writes.
    let unavailable = OpenClawGatewayClientError.rejected("The configured local Gateway credential could not be read from the OpenClaw secret store.")
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
      if let database { sqlite3_close(database) }
      throw unavailable
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 1_000)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT substr(value, 1, 65537) FROM secret_store_entries WHERE scope_kind = 'team' AND scope_id = '' AND name = ? AND deleted_at_ms IS NULL LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw unavailable }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW,
          let bytes = sqlite3_column_text(statement, 0),
          (1...65536).contains(sqlite3_column_bytes(statement, 0)) else { throw unavailable }
    return String(cString: bytes)
  }

}
