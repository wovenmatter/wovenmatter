#if DEBUG
import Foundation
import LibraryClient

/// Debug builds only: routes tailnet hosts to loopback ports so a simulator
/// can pair with and sync against in-process test hosts
/// (`WOVENMATTER_DEV_TAILNET="studio.tail1.ts.net=18431,box.tail1.ts.net=18432"`).
/// The signed path is unchanged, so signatures verify exactly as on the tailnet.
final class DevelopmentTailnet: MobileHTTPPerforming, @unchecked Sendable {
  private let ports: [String: Int]
  private let http = URLSessionMobileHTTP()
  init?(_ value: String?) {
    guard let value, !value.isEmpty else { return nil }
    var ports: [String: Int] = [:]
    for pair in value.split(separator: ",") {
      let parts = pair.split(separator: "=")
      guard parts.count == 2, let port = Int(parts[1]) else { continue }
      ports[String(parts[0]).lowercased()] = port
    }
    guard !ports.isEmpty else { return nil }
    self.ports = ports
  }
  /// Simulator checks against test hosts: pair with a link without the
  /// system's open-URL prompt (`WOVENMATTER_DEV_PAIR_LINK`) and open a tab
  /// (`WOVENMATTER_DEV_TAB`, or `Device Connections`).
  @MainActor static func applyLaunchOptions(to model: MobileModel) async {
    let environment = ProcessInfo.processInfo.environment
    if model.credential == nil, let link = environment["WOVENMATTER_DEV_PAIR_LINK"].flatMap(URL.init(string:)) {
      await model.pair(url: link)
    }
    guard let tab = environment["WOVENMATTER_DEV_TAB"] else { return }
    if tab == "Device Connections" { model.tab = .settings; model.pairingPresented = true }
    else if let value = MobileModel.Tab(rawValue: tab) { model.tab = value }
  }
  func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let host = components.host?.lowercased() else { throw URLError(.badURL) }
    let authority = host + (components.port.map { ":\($0)" } ?? "")
    guard let port = ports[authority] ?? ports[host] else { return try await http.perform(request, maximumBytes: maximumBytes, longLived: longLived) }
    components.scheme = "http"; components.host = "127.0.0.1"; components.port = port
    var local = request
    local.url = components.url
    return try await http.perform(local, maximumBytes: maximumBytes, longLived: longLived)
  }
}
#endif
