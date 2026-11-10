#if DEBUG
import Foundation
import CompanionClient
import WovenMatterCompanion

/// UI fixture of a phone paired as a member with two Dev Macs, from a real
/// phone's saved data: both Macs advertise central history, the library host
/// ("This Mac") reports a stale central agent list, two copied snapshot rows
/// remain as history, and a Linux workspace is registered but not reachable.
/// `member-macs-send` also opens a Pi Durable chat on the library host whose
/// workspace takes a moment to accept each message; `member-macs-chooser`
/// opens the New Chat menu at launch.
extension CompanionModel {
  static let memberMacsFixtureChat = "0b5c7d1e-2f3a-4b5c-8d6e-7f8091a2b3c4"
  static let memberMacsAir = "0446435c-8e64-440e-b9eb-3c5dadb27e04"
  static let memberMacsMini = "b03923c3-89d1-4f29-910a-b7e3ce7b586c"
  static let memberMacsLinux = "0fa3b77c-1819-411f-804f-b183d86e2dcd"

  func seedMemberMacsFixture(_ store: MobileStore, send: Bool) async throws {
    let airHost = "e775f2b2-1e79-4bc2-b723-39b3fab2d9c5", miniHost = "7c072eba-eb7c-490b-9434-fb710c7f828f"
    let oldAir = "9e51815e-6d2d-4d20-9885-ddab9621b460"
    let airEndpoint = URL(string: "https://jamess-macbook-air.example.ts.net:10000/wovenmatter")!
    let capabilities = ["execution.v1", "history.central.v1", "inference.v1"]
    let air = CompanionExecutionWorkspace(id: Self.memberMacsAir, libraryID: "fixture", ownerDeviceID: airHost, kind: .mac,
      name: "James’s MacBook Air (Dev) · worktrees-b8e80bfb02", endpoint: airEndpoint, capabilities: capabilities,
      executionDeviceID: airHost, developmentInstance: "worktrees-b8e80bfb02")
    let mini = CompanionExecutionWorkspace(id: Self.memberMacsMini, libraryID: "fixture-mini", ownerDeviceID: miniHost, kind: .mac,
      name: "James’s Mac Mini (Dev) · woven-everywhere", endpoint: URL(string: "https://jamess-mac-mini.example.ts.net:8443/wovenmatter"),
      capabilities: capabilities, executionDeviceID: miniHost, developmentInstance: "woven-everywhere")
    let copied = "3407decc-357c-4d96-a209-92be30520fb6", copiedDeleted = "2e725589-290b-4fff-8715-50b314a68f6a"
    executionWorkspaces = [
      mini, air,
      .init(id: copied, libraryID: "fixture", ownerDeviceID: oldAir, kind: .mac, name: "James’s MacBook Air",
            capabilities: capabilities, executionDeviceID: oldAir, retainedHistory: true),
      .init(id: copiedDeleted, libraryID: "fixture", ownerDeviceID: oldAir, kind: .mac, name: "James’s MacBook Air",
            capabilities: capabilities, executionDeviceID: oldAir, deleted: true, retainedHistory: true),
      .init(id: Self.memberMacsLinux, libraryID: "fixture", ownerDeviceID: airHost, kind: .linux, name: "Workstation (Dev)",
            capabilities: ["execution.v1", "inference.v1"]),
    ].filter { !$0.deleted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    func agent(_ kind: String, _ name: String, ready: Bool, resume: Bool = true) -> CompanionProvider {
      .init(id: "local:" + kind, runtimeKind: kind, displayName: name, available: ready, canStart: ready, canResume: resume,
            canStop: ready, supportsQuestions: kind == "claude_code",
            unavailableReason: ready ? nil : "Enable and configure this agent on the Mac.")
    }
    let ready = [agent("default_agent", "Pi Durable", ready: true, resume: false), agent("codex", "Codex", ready: true),
                 agent("claude_code", "Claude Code", ready: true), agent("grok_build", "Grok Build", ready: true), agent("opencode", "OpenCode", ready: true)]
    // The library host's central list, saved when Codex, Claude Code and OpenCode were not set up there yet.
    let stale = [agent("default_agent", "Pi Durable", ready: true, resume: false), agent("codex", "Codex", ready: false),
                 agent("claude_code", "Claude Code", ready: false), agent("grok_build", "Grok Build", ready: true), agent("opencode", "OpenCode", ready: false)]
    providers = stale
    workspaceProviders = [Self.memberMacsAir: ready, Self.memberMacsMini: ready, copied: stale, copiedDeleted: ready]
    knownAgentIDs = Set(([Self.memberMacsAir, Self.memberMacsMini, copied, copiedDeleted].flatMap { id in ready.map { id + ":" + $0.id } })
      + ready.map { "central:" + $0.id })
    workspaceReachable = [Self.memberMacsAir: true, Self.memberMacsMini: true]
    var saved = MobileMembershipState(deviceID: state.deviceID, pairedEndpoint: airEndpoint, pairedHostDeviceID: airHost,
      pairedName: air.name)
    saved.currentHost = .init(deviceID: airHost, kind: "mac", name: air.name, endpoint: airEndpoint)
    saved.members = [
      .init(deviceID: miniHost, kind: "mac", name: mini.name, endpoints: [mini.endpoint!]),
      .init(deviceID: airHost, kind: "mac", name: air.name, endpoints: [airEndpoint]),
    ]
    membership = saved
    online = true // Fixture presentation only; no central transport is configured.
    guard send else { await reload(); return }

    let id = Self.memberMacsFixtureChat
    try await store.journal.upsertWorkspace(air)
    let conversation = CompanionConversation(id: id, title: "A Quick Hello", providerID: "local:default_agent",
      runtimeKind: "default_agent", preview: "Hey! What can I help with?", updatedAt: "2026-11-10T17:37:09.659Z", workspaceID: air.id)
    let earlier = CompanionTranscript(conversationID: id, messages: [
      .init(id: "fixture-hello", conversationID: id, runID: "fixture-run-1", role: "user", content: "Hey", sequence: 0),
      .init(id: "fixture-hello-reply", conversationID: id, runID: "fixture-run-1", role: "assistant", content: "Hey! What can I help with?", status: "completed", sequence: 1),
    ], runs: [.init(id: "fixture-run-1", status: "completed")])
    try await store.apply(.init(workspaceID: "fixture", cursor: 3, folders: folders, notes: notes,
      conversations: conversations.filter { $0.id != id } + [conversation]))
    try await store.cache(earlier)
    conversationWorkspaceIDs[id] = air.id
    workspaceClients[air.id] = WorkspaceClient(store: store, workspaceID: air.id,
      transport: MemberMacsFixtureWorkspace(workspace: air, transcript: earlier, providers: ready))
    await reload()
  }
}

/// The library host's workspace endpoint: it takes a moment to accept a
/// message, then shows it with its turn running.
private actor MemberMacsFixtureWorkspace: ExecutionWorkspaceTransport {
  let workspace: CompanionExecutionWorkspace
  var transcriptValue: CompanionTranscript
  let agents: [CompanionProvider]
  var receipts: [String: CompanionCommandReceipt] = [:]
  init(workspace: CompanionExecutionWorkspace, transcript: CompanionTranscript, providers: [CompanionProvider]) {
    // Without central history the fixture keeps its seeded conversation rows.
    var identity = workspace; identity.capabilities.removeAll { $0 == "history.central.v1" }
    self.workspace = identity; transcriptValue = transcript; agents = providers
  }
  func identity() async throws -> CompanionExecutionWorkspace { workspace }
  func providers() async throws -> [CompanionProvider] { agents }
  func pending() async throws -> [CompanionPendingInteraction] { [] }
  func capabilities(_ id: String) async throws -> CompanionProvider { agents[0] }
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt {
    try await Task.sleep(for: .seconds(2))
    let runID = "fixture-run-" + command.commandID
    let sequence = Int64(transcriptValue.messages.count)
    transcriptValue.messages.append(.init(id: "fixture-user-" + command.commandID, conversationID: command.conversationID ?? "",
      runID: runID, role: "user", content: command.text ?? "", sequence: sequence))
    transcriptValue.activeRunID = runID
    transcriptValue.runs = (transcriptValue.runs ?? []) + [.init(id: runID, status: "running")]
    let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .accepted,
      conversationID: command.conversationID, runID: runID, workspaceID: workspace.id)
    receipts[command.commandID] = receipt
    return receipt
  }
  func receipt(_ id: String) async throws -> CompanionCommandReceipt? { receipts[id] }
  func events(after: Int64) async throws -> CompanionJournalPage { .init(libraryID: workspace.libraryID, cursor: after) }
  func conversations() async throws -> [CompanionConversation] { [] }
  func transcript(_ id: String) async throws -> CompanionTranscript { transcriptValue }
}
#endif
