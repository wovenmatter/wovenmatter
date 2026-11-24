import Foundation
import Synchronization
import Testing
import WovenProtocol
@testable import WovenServerKit

/// Keeps what would have gone to the statistics.
private final class RecordingDelivery: AnalyticsDelivery {
  private let events = Mutex<[JSONValue]>([])
  func deliver(_ batch: [JSONValue]) async { events.withLock { $0 += batch } }
  var names: [String] { events.withLock { $0.compactMap { $0["event"]?.string } } }

  func last(_ name: String) -> JSONValue? {
    events.withLock { $0.last { $0["event"]?.string == name }?["properties"] }
  }

  /// Waits until `count` events have arrived, then a moment for any extra.
  func wait(for count: Int) async throws -> [String] {
    for _ in 0..<80 where names.count < count { try await Task.sleep(for: .milliseconds(25)) }
    try await Task.sleep(for: .milliseconds(150))
    return names
  }
}

private func start(_ folder: URL, version: String, delivery: RecordingDelivery) async throws -> (WovenServer, Client) {
  let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
  var options = WovenServer.Options(dataFolder: folder, socketPath: socket, listen: nil, appVersion: version,
                                    machineName: "test", tailnet: StandInTailnet(), runtimes: [StandInRuntime()])
  options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
  options.analyticsDelivery = delivery
  let server = try await WovenServer.start(options)
  let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
  _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: version))
  return (server, client)
}

@Test(.timeLimit(.minutes(1)))
func usageStatisticsCountOpensAndDeliberateUseUnderTheLibrarysEarliestIdentifierUntilTurnedOff() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
  let delivery = RecordingDelivery()
  let (server, client) = try await start(folder, version: "1.0.0", delivery: delivery)
  defer { server.stopLater() }

  // Nothing is sent before the app has opened and given the library its identifier.
  _ = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Chat"))
  _ = try await client.call(RecordAppEvent(.opened))
  #expect(try await delivery.wait(for: 1) == ["app_opened"])
  let id = try #require(delivery.last("app_opened")?["distinct_id"]?.string)

  // A deliberate action counts once per six hours; reading never does.
  _ = try await client.call(ListSessions())
  _ = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Chat"))
  _ = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Chat"))
  _ = try await client.call(RecordAppEvent(.opened))
  #expect(try await delivery.wait(for: 2) == ["app_opened", "app_active"])
  let active = try #require(delivery.last("app_active"))
  #expect(active["distinct_id"]?.string == id && active["qualifying_activity"]?.bool == true
          && active["source"]?.string == "app" && active["$process_person_profile"]?.bool == false)

  // A machine that made its candidate earlier wins, so every machine agrees.
  _ = try await client.call(SetSetting(key: AnalyticsSettings.candidatePrefix + "older",
                                       value: .object(["id": .string("earliest"), "created": .integer(1)])))
  _ = try await client.call(RecordAppEvent(.updateDownloadStarted, targetVersion: "1.0.1"))
  #expect(try await delivery.wait(for: 3).last == "update_download_started")
  #expect(delivery.last("update_download_started")?["distinct_id"]?.string == "earliest")
  #expect(delivery.last("update_download_started")?["target_version"]?.string == "1.0.1")

  // Turned off, nothing more goes.
  _ = try await client.call(SetSetting(key: AnalyticsSettings.enabled, value: .bool(false)))
  _ = try await client.call(RecordAppEvent(.updateDownloadStarted, targetVersion: "1.0.1"))
  #expect(try await delivery.wait(for: 4).count == 3)
}

// Only a Mac's server reports its updates.
@Test(.timeLimit(.minutes(1)), .enabled(if: MachinePlatform.current == .mac))
func updatesAreReportedFailedWhenTheAppReopensOnTheOldReleaseAndFinishedOnceWhenItOpensOnTheNewOne() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
  let delivery = RecordingDelivery()
  var (server, client) = try await start(folder, version: "1.0.0", delivery: delivery)
  _ = try await client.call(RecordAppEvent(.opened))
  #expect(try await delivery.wait(for: 1) == ["app_opened"])

  // The reply comes once the event has gone, so the app can wait for it before quitting.
  _ = try await client.call(RecordAppEvent(.updateInstallStarted, targetVersion: "1.0.1"))
  #expect(delivery.names == ["app_opened", "update_install_started"])
  _ = try await client.call(RecordAppEvent(.opened))
  #expect(try await delivery.wait(for: 3).last == "update_install_failed")
  #expect(delivery.last("update_install_failed")?["target_version"]?.string == "1.0.1")

  // A started install that brought this release is no failure; the finished
  // update goes when the app opens on it.
  _ = try await client.call(RecordAppEvent(.updateInstallStarted, targetVersion: "1.0.1"))
  await server.stop()
  (server, client) = try await start(folder, version: "1.0.1", delivery: delivery)
  _ = try await client.call(RecordAppEvent(.opened))
  let completed = try #require(delivery.last("update_install_completed"))
  #expect(completed["from_version"]?.string == "1.0.0" && completed["target_version"]?.string == "1.0.1")
  await server.stop()

  (server, client) = try await start(folder, version: "1.0.1", delivery: delivery)
  defer { server.stopLater() }
  _ = try await client.call(RecordAppEvent(.opened))
  #expect(try await delivery.wait(for: 6) == ["app_opened", "update_install_started", "update_install_failed",
                                              "update_install_started", "update_install_completed"])
}
