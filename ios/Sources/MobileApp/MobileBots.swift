import Foundation
import LibraryClient
import UIKit
import Observation
import WovenMatterShared

/// The machine whose Woven server runs this library's bots, as the phone
/// reaches it: `<endpoint>/v1/bots/ws`, signed for `audience` on every
/// connection attempt. Bots run on one machine at a time (Settings → Bots on a Mac).
struct MobileBotMachine: Equatable, Sendable {
  var deviceID: String
  var name: String
  /// `mac` or `linux`.
  var kind: String
  var socketURL: URL
  /// The member that serves the socket; signed upgrades are addressed to it.
  var audience: String?
  /// Only the Debug fixture's loopback runtime takes a bearer.
  var bearer: String?
}

/// Where this library's bots are, from the phone's point of view.
enum MobileBotsPlacement: Equatable {
  /// Not paired with a Mac (or not a member yet): nothing to ask.
  case unpaired
  case searching
  /// No reachable machine runs bots. Each checked machine says why.
  case off([MobileBotsCheck])
  /// A machine runs bots but they can't be used right now.
  case unavailable(name: String, message: String)
  case ready(MobileBotMachine)
}

struct MobileBotsCheck: Equatable, Identifiable {
  var id: String
  var name: String
  var detail: String
}

/// One Mac or Linux workspace that might run bots, and the member that serves it.
struct MobileBotTarget: Equatable {
  var workspace: ExecutionWorkspace
  var audience: String
}

/// The Bots page: finds the machine that runs bots and holds one connection to it
/// while the app is open. Bots, their threads and replies come live over Pi Bot's
/// protocol (the same client and conversation logic as the Mac). Creating bots and
/// their settings stay on the Mac.
@MainActor @Observable
final class MobileBotsModel {
  private(set) var placement = MobileBotsPlacement.unpaired
  private(set) var session: MobileBotSession?
  private(set) var lastChecked: Date?
  /// Unsent text by bot and conversation; leaving a chat keeps it.
  var drafts: [PiBotConversationKey: String] = [:]
  @ObservationIgnored private var searching: Task<Void, Never>?
  @ObservationIgnored private var foreground = true

  /// Every Mac and Linux workspace in the registry that can be addressed, one
  /// per serving member, as the Mac does (`memberBotTargets`).
  static func targets(workspaces: [ExecutionWorkspace], membership: MobileMembershipState?) -> [MobileBotTarget] {
    guard let membership else { return [] }
    var seen: Set<String> = [membership.deviceID], result: [MobileBotTarget] = []
    for workspace in workspaces where (workspace.kind == .mac || workspace.kind == .linux)
      && workspace.isVisibleInConnections && workspace.endpoint != nil {
      guard let audience = membership.audience(for: workspace), seen.insert(audience).inserted else { continue }
      result.append(.init(workspace: workspace, audience: audience))
    }
    return result
  }

  /// One machine's `GET /v1/bots/status`, signed as this phone. The reply must name
  /// the member the request was addressed to.
  nonisolated static func status(of target: MobileBotTarget, signer: MemberRequestSigner,
                                 performer: any MobileHTTPPerforming) async throws -> BotsRemoteStatus {
    guard let endpoint = target.workspace.endpoint else { throw MobileBotsError("It has no address yet.") }
    var request = URLRequest(url: endpoint.appending(path: "v1/bots/status"), timeoutInterval: 10)
    request.httpMethod = "GET"
    try MobileRequestSigning.sign(&request, with: signer, audience: target.audience)
    let (data, response) = try await performer.perform(request, maximumBytes: 256 * 1024, longLived: false)
    guard (200..<300).contains(response.statusCode) else { throw MobileBotsError.http(response.statusCode, data) }
    let status = try JSONDecoder().decode(BotsRemoteStatus.self, from: data)
    guard status.machine.deviceID.lowercased() == target.audience else { throw MobileBotsError("It answered as another device.") }
    return status
  }

  /// Which machine runs bots: the one with bots turned on, ready ones first, Macs
  /// before Linux hosts. Nil placement detail comes from each machine's answer.
  static func placement(_ results: [(target: MobileBotTarget, result: Result<BotsRemoteStatus, any Error>)]) -> MobileBotsPlacement {
    let answered = results.compactMap { item -> (MobileBotTarget, BotsRemoteStatus)? in
      if case .success(let status) = item.result { return (item.target, status) } else { return nil }
    }
    let enabled = answered.filter { $0.1.enabled }.sorted { lhs, rhs in
      let order = ["ready": 0, "starting": 1, "failed": 2]
      let left = order[lhs.1.state] ?? 3, right = order[rhs.1.state] ?? 3
      if left != right { return left < right }
      if lhs.0.workspace.kind != rhs.0.workspace.kind { return lhs.0.workspace.kind == .mac }
      return lhs.0.workspace.name.localizedStandardCompare(rhs.0.workspace.name) == .orderedAscending
    }
    if let (target, status) = enabled.first {
      let name = status.machine.name.isEmpty ? target.workspace.name : status.machine.name
      switch status.state {
      case "ready":
        guard let endpoint = target.workspace.endpoint else { return .unavailable(name: name, message: "It has no address yet.") }
        return .ready(.init(deviceID: target.audience, name: name, kind: status.machine.kind,
                            socketURL: endpoint.appending(path: "v1/bots/ws"), audience: target.audience))
      case "starting": return .unavailable(name: name, message: status.message ?? "Bots are starting there.")
      default: return .unavailable(name: name, message: status.message ?? "Bots there stopped with an error. Open Woven Matter on your Mac: Settings → Bots.")
      }
    }
    return .off(results.map { item in
      let detail: String
      switch item.result {
      case .success(let status): detail = status.state == "failed" ? (status.message ?? "Bots failed to start") : "Bots are off"
      case .failure(let error): detail = (error as? MobileBotsError)?.message ?? error.localizedDescription
      }
      return .init(id: item.target.audience, name: item.target.workspace.name, detail: detail)
    })
  }

  /// Looks again for the machine that runs bots. A machine that still runs them keeps
  /// its connection; another one replaces it.
  func refresh(targets: [MobileBotTarget], signer: MemberRequestSigner?, performer: any MobileHTTPPerforming) async {
    guard let signer else { apply(.unpaired); return }
    guard !targets.isEmpty else { apply(.off([])); return }
    searching?.cancel()
    if session == nil { placement = .searching }
    let task = Task { [weak self] in
      let results = await withTaskGroup(of: (Int, Result<BotsRemoteStatus, any Error>).self) { group in
        for (index, target) in targets.enumerated() {
          group.addTask {
            do { return (index, .success(try await Self.status(of: target, signer: signer, performer: performer))) }
            catch { return (index, .failure(error)) }
          }
        }
        var collected: [(Int, Result<BotsRemoteStatus, any Error>)] = []
        for await item in group { collected.append(item) }
        return collected.sorted { $0.0 < $1.0 }.map { (targets[$0.0], $0.1) }
      }
      guard !Task.isCancelled else { return }
      self?.apply(Self.placement(results.map { (target: $0.0, result: $0.1) }), signer: signer)
    }
    searching = task
    await task.value
  }

  /// Applies a placement: connects to a ready machine, or drops a connection that no
  /// longer applies. `signer` signs the socket upgrades; the fixture passes none.
  func apply(_ next: MobileBotsPlacement, signer: MemberRequestSigner? = nil) {
    lastChecked = Date()
    placement = next
    guard case .ready(let machine) = next else {
      session?.disconnect(); session = nil
      return
    }
    if let session, session.machine == machine { if foreground { session.connect() }; return }
    session?.disconnect()
    let created = MobileBotSession(machine: machine, signer: signer)
    session = created
    if foreground { created.connect() }
  }

  /// Bots stream only while the app is open (live, like workspace streams).
  func setForeground(_ active: Bool) {
    guard foreground != active else { return }
    foreground = active
    if active { session?.connect() } else { session?.suspend() }
  }

  func draft(_ key: PiBotConversationKey) -> String { drafts[key] ?? "" }
  func setDraft(_ text: String, for key: PiBotConversationKey) { drafts[key] = text.isEmpty ? nil : text }
}

struct MobileBotsError: LocalizedError, Equatable {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }

  static func http(_ status: Int, _ data: Data) -> MobileBotsError {
    let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
      ?? (try? JSONDecoder().decode(LibraryAPIError.self, from: data))?.code
    switch (status, code) {
    case (404, _): return .init("Its Woven server doesn't run bots yet. Update it to use bots there.")
    case (_, "update_required"): return .init("Update Woven Matter there to use its bots.")
    case (401, _), (403, _):
      let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
      return .init("It doesn't know this \(device) yet. It learns it the next time it syncs with your Mac.")
    default: return .init("It answered with an error (HTTP \(status)).")
    }
  }
}

/// One live connection to a machine's bots runtime: the bot list, threads and the open
/// conversations. Mirrors the Mac's `BotMachineSession` without its settings.
@MainActor @Observable
final class MobileBotSession: PiBotConversationHost {
  let machine: MobileBotMachine
  private(set) var connection = PiBotClient.ConnectionState.closed
  private(set) var bots: [PiBotSummary] = []
  private(set) var groups: [PiBotGroup] = []
  private(set) var threadsByBot: [String: [PiBotThread]] = [:]
  /// The bot list has arrived at least once.
  private(set) var hasLoadedBots = false
  private(set) var loadError: String?

  @ObservationIgnored private let client: PiBotClient
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var loadedThreads = Set<String>()
  @ObservationIgnored private var reloads = 0
  @ObservationIgnored private var conversations: [PiBotConversationKey: PiBotConversationController] = [:]

  init(machine: MobileBotMachine, signer: MemberRequestSigner?) {
    self.machine = machine
    let (stream, continuation) = AsyncStream<PiBotClient.Event>.makeStream()
    var authorize: PiBotClient.Authorize?
    if let audience = machine.audience, let signer {
      // A signature's nonce is single use: every connection attempt signs afresh.
      authorize = { @Sendable url in try StreamEndpoint.signedHeaders(for: url, signer: signer, audience: audience) }
    }
    client = PiBotClient(socketURL: machine.socketURL, bearer: authorize == nil ? machine.bearer : nil, authorize: authorize) {
      continuation.yield($0)
    }
    eventTask = Task { [weak self] in
      for await event in stream { self?.handle(event) }
    }
  }

  var connectedClient: PiBotClient? { connection == .open ? client : nil }
  var isConnected: Bool { connection == .open }
  var layout: PiBotSidebarLayout { PiBotSidebarLayout(bots: bots, groups: groups) }
  func threads(for botID: String) -> [PiBotThread] { PiBotThread.sorted(threadsByBot[botID] ?? []) }
  func bot(_ id: String) -> PiBotSummary? { bots.first { $0.id == id } }

  func connect() { Task { await client.connect() } }
  /// Closes the socket while the app is in the background; `connect` reopens it.
  func suspend() { Task { await client.close() } }
  func disconnect() {
    eventTask?.cancel(); eventTask = nil
    conversations.values.forEach { $0.forget() }
    conversations = [:]
    let client = client
    Task { await client.invalidate() }
    setConnection(.closed)
  }

  /// The one state for a conversation, shared by every view showing it.
  func conversation(botID: String, conversationID: Int?) -> PiBotConversationController {
    let key = PiBotConversationKey(machineID: machine.deviceID, botID: botID, conversationID: conversationID)
    if let existing = conversations[key] { return existing }
    if conversations.count >= 16 {
      for (other, controller) in conversations where !controller.isAttached { conversations[other] = nil }
    }
    let controller = PiBotConversationController(host: self, key: key)
    conversations[key] = controller
    return controller
  }

  func loadThreads(botID: String) async {
    loadedThreads.insert(botID)
    do { threadsByBot[botID] = try await client.threads(botID: botID) }
    catch { loadError = error.localizedDescription }
  }

  func setPinned(botID: String, conversationID: Int, pinned: Bool) async {
    do { try await client.setPinned(botID: botID, conversationID: conversationID, pinned: pinned) }
    catch { loadError = error.localizedDescription }
    await loadThreads(botID: botID)
  }

  func reload() async {
    reloads += 1
    let current = reloads
    do {
      let latest = try await client.bots(), latestGroups = try await client.groups()
      guard current == reloads else { return }
      bots = latest; groups = latestGroups; hasLoadedBots = true; loadError = nil
      let present = Set(latest.map(\.id))
      threadsByBot = threadsByBot.filter { present.contains($0.key) }
      loadedThreads.formIntersection(present)
      for botID in loadedThreads { await loadThreads(botID: botID) }
    } catch {
      guard current == reloads else { return }
      loadError = error.localizedDescription
    }
  }

  private func setConnection(_ state: PiBotClient.ConnectionState) {
    guard connection != state else { return }
    connection = state
    if state != .open { conversations.values.forEach { $0.connectionLost() } }
  }

  private func handle(_ event: PiBotClient.Event) {
    switch event {
    case .state(let state): setConnection(state)
    case .hello:
      scheduleRefresh()
      conversations.values.forEach { $0.connectionOpened() }
    case .botsChanged, .groupsChanged: scheduleRefresh()
    case .threadsChanged(let botID):
      if loadedThreads.contains(botID) { Task { await loadThreads(botID: botID) } }
    case .conversation(let botID, let conversationID, let event):
      for controller in conversations.values where controller.key.botID == botID {
        controller.receive(conversationID: conversationID, event)
      }
    case .memoryChanged, .runtimeProgress, .environmentChanged: break
    }
  }

  /// Bursts of change notifications collapse into one reload.
  private func scheduleRefresh() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(80))
      guard !Task.isCancelled else { return }
      await self?.reload()
    }
  }
}

extension MobileModel {
  /// Looks for the machine that runs bots, from the synced registry of Mac and
  /// Linux workspaces, signed with this phone's member key.
  func refreshBots() async {
    #if DEBUG
    if fixture { return }
    #endif
    // A member transport means the paired Mac accepted this phone's key.
    let signer = libraryHosts == nil ? nil : memberIdentity?.signer
    await bots.refresh(targets: MobileBotsModel.targets(workspaces: executionWorkspaces, membership: membership),
                       signer: signer, performer: httpPerformer ?? URLSessionMobileHTTP())
  }
}
