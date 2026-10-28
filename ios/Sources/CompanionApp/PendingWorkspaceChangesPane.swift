import SwiftUI
import CompanionClient
import WovenMatterCompanion

private struct PendingWorkspaceCommand: Identifiable {
  var workspaceID: String
  var record: MobileCommandRecord
  var id: String { workspaceID + ":" + record.id }
}

struct PendingWorkspaceChangesPane: View {
  @Bindable var model: CompanionModel
  @State private var commands: [PendingWorkspaceCommand] = []
  @State private var launches: [MobileLaunchRecord] = []
  @State private var busy = false
  @State private var problem: String?
  var body: some View {
    List {
      if let problem { Text(problem).foregroundStyle(DashboardPalette.danger).textSelection(.enabled) }
      ForEach((model.state.workspaceFolderRequests ?? [:]).keys.sorted(), id: \.self) { owner in
        if let request = model.state.workspaceFolderRequests?[owner] {
          Section(workspaceName(owner)) {
            Text("Create folder: " + (request.title ?? "Folder"))
            Button("Continue folder creation") {
              perform { try await model.newWorkspaceFolder(name: request.title ?? "", workspaceID: owner, id: request.resourceID) }
            }.disabled(!available(owner))
          }
        }
      }
      ForEach(launches) { launch in
        let owner = launch.create.workspaceID ?? "central"
        Section(workspaceName(owner)) {
          Text("New conversation")
          Text(launch.initialSend.text ?? "").font(.caption).lineLimit(5).textSelection(.enabled)
          Button("Continue saved request") { perform {
            if owner == "central", let engine = model.engine { _ = try await engine.startConversation(launch) }
            else if let client = model.workspaceClients[owner] { _ = try await client.startConversation(launch) }
            else { throw MobileConnectionError.offline }
          } }.disabled(!available(owner))
        }
      }
      ForEach(commands) { pending in
        Section(workspaceName(pending.workspaceID)) {
          Text(pending.record.command.kind == .createSession ? "Create conversation" : "Saved workspace request")
          if let text = pending.record.command.text { Text(text).font(.caption).lineLimit(5).textSelection(.enabled) }
          Button("Recover or retry") { perform {
            // These services read the original receipt first and retry only the
            // original durable payload. Navigation cannot redirect the command.
            if pending.workspaceID == "central", let engine = model.engine {
              try await engine.recoverCommandReceipts()
              let saved = await model.store?.snapshot().commands.first { $0.id == pending.record.id }
              if saved?.receipt == nil || saved?.receipt?.status == .outcomeUnknown { _ = try await engine.submit(pending.record.command) }
            } else if let client = model.workspaceClients[pending.workspaceID] { _ = try await client.submit(pending.record.command) }
            else { throw MobileConnectionError.offline }
          } }.disabled(!available(pending.workspaceID))
        }
      }
      if commands.isEmpty && launches.isEmpty && model.state.workspaceFolderRequests?.isEmpty != false {
        Text("No requests need acknowledgement.").foregroundStyle(DashboardPalette.mutedForeground)
      }
      Section { Text("A retry recovers the original acknowledgement before repeating that same request. Work stays on its original workspace.").font(.caption).foregroundStyle(.secondary) }
    }.disabled(busy).mobileNavigationPage("Pending changes").task { await load() }.refreshable { await load() }
  }
  private func workspaceName(_ owner: String) -> String { owner == "central" ? "Central Mac" : model.executionWorkspaces.first { $0.id == owner }?.name ?? "Workspace" }
  private func available(_ owner: String) -> Bool { owner == "central" ? model.online : model.workspaceReachable[owner] == true }
  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    busy = true; problem = nil
    Task {
      defer { busy = false }
      do { try await operation(); await model.reload(); await load() }
      catch { problem = error.localizedDescription; await model.reload(); await load() }
    }
  }
  private func load() async {
    guard let store = model.store else { return }
    await model.reload()
    launches = model.state.launches.filter { !$0.accepted && !$0.terminalFailure }
    let launchCommands = Set(launches.flatMap { [$0.create.commandID, $0.initialSend.commandID] })
    func unresolved(_ record: MobileCommandRecord) -> Bool {
      !launchCommands.contains(record.id) && (record.receipt == nil || record.receipt?.status == .outcomeUnknown || record.command.kind == .createSession && record.receipt?.status == .accepted)
    }
    commands = model.state.commands.filter(unresolved).map { .init(workspaceID: "central", record: $0) }
    for (key, record) in await store.journal.snapshot().commands where unresolved(record) {
      if let owner = record.command.workspaceID ?? key.split(separator: ":").first.map(String.init) {
        commands.append(.init(workspaceID: owner, record: record))
      }
    }
    commands.sort { $0.id < $1.id }
  }
}
