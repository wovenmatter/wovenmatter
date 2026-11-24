import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import WovenLibrary
import WovenProtocol

/// Where anonymous usage events go. Only a release server has one: tests and
/// development instances never send to the real statistics.
protocol AnalyticsDelivery: Sendable {
  /// One attempt. Failures are dropped; nothing is kept for later.
  func deliver(_ events: [JSONValue]) async
}

/// The project's PostHog ingestion endpoint. Its token can only send events.
struct PostHogDelivery: AnalyticsDelivery {
  static let endpoint = URL(string: "https://us.i.posthog.com/batch/")!
  static let projectToken = "phc_ukNR3Tu7AjaLmAVjbapvKsyaB8LdhFwM3vUjM5Jfxpeh"

  func deliver(_ events: [JSONValue]) async {
    var request = URLRequest(url: Self.endpoint, timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body = JSONValue.object(["api_key": .string(Self.projectToken), "batch": .array(events)])
    guard let data = try? Wire.encoder.encode(body) else { return }
    request.httpBody = data
    _ = try? await URLSession.shared.data(for: request)
  }
}

/// Anonymous usage statistics for one server: when the app opens, when the
/// person does something deliberate in it, the updater's steps and finished
/// updates. Each event carries the library's anonymous identifier and the
/// release, platform and OS major version, and nothing else: no content,
/// names, paths, accounts, errors or which action it was.
final class Analytics: Sendable {
  /// `app_opened` and `app_active` are each attempted at most once per
  /// machine in this long.
  static let signalInterval: TimeInterval = 6 * 60 * 60
  /// Sends in flight at once; an event beyond them is dropped.
  static let maximumInFlight = 4
  /// How long an opening waits for the first sync with the other machines.
  static let settleLimit = Duration.seconds(60)

  private let library: Library
  private let delivery: (any AnalyticsDelivery)?
  private let appVersion: String
  private let now: @Sendable () -> Date
  /// Whether the first sync with the other machines has finished.
  private let settled: @Sendable () async -> Bool
  private let inFlight = Mutex(0)
  /// When this server last spent each signal's allowance, so a throttled
  /// request does not reach the library.
  private let claimed = Mutex<[String: Date]>([:])

  init(library: Library, delivery: (any AnalyticsDelivery)?, appVersion: String,
       settled: @escaping @Sendable () async -> Bool, now: @escaping @Sendable () -> Date = { Date() }) {
    self.library = library
    self.delivery = delivery
    self.appVersion = appVersion
    self.settled = settled
    self.now = now
  }

  /// At start: a release different from the one this Mac's server ran
  /// before is a finished update, whichever way it was installed. The
  /// release is noted even while nothing is sent, so turning the statistics
  /// on later reports no old update.
  func start() async {
    guard let previous = try? await library.exchangeAnalyticsVersion(appVersion), previous != appVersion,
          MachinePlatform.current == .mac else { return }
    send("update_install_completed", ["from_version": .string(previous), "target_version": .string(appVersion)])
  }

  /// What the UI reported.
  func record(_ event: RecordAppEvent) async {
    if event.event == .opened {
      // A Mac that has just joined first hears what the library holds: its
      // identifier, and whether the person turned the statistics off.
      guard delivery != nil, await waitUntilSettled() else { return }
      // The app opening on a Mac is where a library first gets its identifier.
      await ensureCandidate()
      await signal(AppEvent.opened.rawValue, [:])
    } else {
      send(event.event.rawValue, event.targetVersion.map { ["target_version": .string($0)] } ?? [:])
    }
  }

  /// After a request succeeds: one from a person's UI that changes or
  /// starts something counts them as active.
  func handled(_ method: String, _ params: JSONValue, _ caller: Caller) {
    guard delivery != nil, caller.hello.role == .ui, Self.qualifies(method, params) else { return }
    Task { await signal("app_active", ["qualifying_activity": .bool(true)]) }
  }

  /// Deliberate actions: starting or steering a chat, answering it, editing
  /// the Library, adding a folder or a schedule, saving dictation, talking to
  /// the bots. Reading, opening, browsing and settings do not count.
  static func qualifies(_ method: String, _ params: JSONValue) -> Bool {
    if method == BotsCall.method {
      return ["message.send", "forum.post", "forum.thread.create", "bots.create"].contains(params["request"]?["type"]?.string ?? "")
    }
    return qualifyingMethods.contains(method)
  }

  static let qualifyingMethods: Set<String> = [
    CreateSession.method, SendTurn.method, AnswerPrompt.method, SetGoal.method,
    // `artifacts.write` is typing in a note, page or sheet; a note whose
    // linked data changed is also written when opened, which rarely counts.
    CreateArtifact.method, UpdateArtifact.method, WriteArtifact.method, RestoreArtifactVersion.method, DispatchPageTask.method,
    CreateFolder.method, SaveSchedule.method, SaveDictation.method,
  ]

  // MARK: Sending

  private func signal(_ event: String, _ properties: [String: JSONValue]) async {
    let time = now()
    if let last = claimed.withLock({ $0[event] }), last <= time, time.timeIntervalSince(last) < Self.signalInterval { return }
    // Only an event that can go spends the allowance.
    guard delivery != nil, await enabled(), await identifier() != nil,
          (try? await library.claimAnalyticsSignal(event, now: time, interval: Self.signalInterval)) == true else { return }
    claimed.withLock { $0[event] = time }
    send(event, properties)
  }

  /// Sends one event in the background, when the statistics are on and the
  /// library has its identifier.
  private func send(_ event: String, _ properties: [String: JSONValue]) {
    guard let delivery else { return }
    let reserved = inFlight.withLock { count in
      guard count < Self.maximumInFlight else { return false }
      count += 1
      return true
    }
    guard reserved else { return }
    let timestamp = now()
    Task {
      defer { inFlight.withLock { $0 -= 1 } }
      guard await enabled(), let id = await identifier() else { return }
      await delivery.deliver([Self.event(event, id: id, at: timestamp, appVersion: appVersion, properties)])
    }
  }

  static func event(_ name: String, id: String, at timestamp: Date, appVersion: String,
                    _ properties: [String: JSONValue]) -> JSONValue {
    var values = properties
    values["distinct_id"] = .string(id)
    values["$process_person_profile"] = .bool(false)
    values["source"] = .string("app")
    values["platform"] = .string(MachinePlatform.current == .mac ? "macos" : "linux")
    values["app_version"] = .string(appVersion)
    // On Linux this would be the kernel's, so it is left out there.
    if MachinePlatform.current == .mac {
      values["os_major"] = .string(String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion))
    }
    if values["qualifying_activity"] == nil { values["qualifying_activity"] = .bool(false) }
    return .object([
      "event": .string(name), "uuid": .string(UUID().uuidString.lowercased()),
      "timestamp": .string(ISO8601DateFormatter().string(from: timestamp)), "properties": .object(values),
    ])
  }

  // MARK: Identity and choice

  private func waitUntilSettled() async -> Bool {
    let deadline = ContinuousClock.now + Self.settleLimit
    while !(await settled()) {
      guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
      try? await Task.sleep(for: .milliseconds(500))
    }
    return true
  }

  private func enabled() async -> Bool {
    (try? await library.setting(AnalyticsSettings.enabled))?.value.bool != false
  }

  /// The earliest machine's candidate, so a machine that joins later, having
  /// made its own before it heard of the others, ends up with theirs.
  func identifier() async -> String? {
    guard let settings = try? await library.settings() else { return nil }
    let candidates = settings.filter { $0.key.hasPrefix(AnalyticsSettings.candidatePrefix) }.compactMap { setting in
      setting.value["id"]?.string.map { (id: $0, created: setting.value["created"]?.int ?? .max) }
    }
    return candidates.min { ($0.created, $0.id) < ($1.created, $1.id) }?.id
  }

  /// Makes this machine's candidate when the library has none.
  private func ensureCandidate() async {
    guard delivery != nil, await enabled(), await identifier() == nil else { return }
    let created = Int(now().timeIntervalSince1970 * 1000)
    _ = try? await library.setSetting(AnalyticsSettings.candidatePrefix + library.machineID, to: .object([
      "id": .string(UUID().uuidString.lowercased()), "created": .integer(Int64(created)),
    ]))
  }
}

func registerAnalytics(_ router: inout Router, analytics: Analytics) {
  router.on(RecordAppEvent.self) { request, _ in
    await analytics.record(request)
    return Done()
  }
}
