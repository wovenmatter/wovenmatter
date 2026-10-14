import Foundation
import UIKit
import CompanionClient
import WovenMatterCompanion

extension CompanionModel {
  func authorizedWorkspaceCredential(_ id: String) async throws -> DirectWorkspaceCredential {
    guard !fixture, !isolatedTestHost else { throw DeviceExecutionError.unavailable("Use the regular app to authorize execution workspaces.") }
    if let existing = try WorkspaceCredentialVault.load(workspaceID: id), existing.deviceID == state.deviceID, existing.libraryID == state.workspaceID { return existing }
    guard online, let transport else { throw DeviceExecutionError.unavailable("Connect to your central database to authorize this workspace for the first time.") }
    let generation = connectionGeneration
    let credential = try await transport.executionCredential(workspaceID: id)
    guard generation == connectionGeneration, !pairingInProgress else { throw MobileConnectionError.revoked }
    guard credential.deviceID == state.deviceID, credential.libraryID == state.workspaceID else { throw MobileConnectionError.revoked }
    try WorkspaceCredentialVault.save(credential)
    return credential
  }
  func renewWorkspaceAccess(_ id: String) async {
    guard !fixture, !isolatedTestHost, let store, online, let transport else { errorMessage = "Connect to your central database to refresh device access."; return }
    let generation = connectionGeneration
    do {
      let credential = try await transport.executionCredential(workspaceID: id)
      guard generation == connectionGeneration, !pairingInProgress else { return }
      guard credential.deviceID == state.deviceID, credential.libraryID == state.workspaceID else { throw MobileConnectionError.revoked }
      try WorkspaceCredentialVault.save(credential)
      let connections = inferenceConnections + executionRecords.values.compactMap(\.connection)
      for connection in connections where connection.hostScope?.workspaceID == id && connection.baseURL == credential.endpoint.absoluteString {
        try await executionCredentialStore.save(credential.token, connectionID: connection.id)
      }
      workspaceClients[id] = WorkspaceClient(store: store, workspaceID: id, transport: try HTTPSExecutionWorkspaceTransport(credential: credential))
      workspaceAuthorizationRetryAt.removeValue(forKey: id)
      await refreshDirectWorkspace(id)
    } catch { errorMessage = error.localizedDescription }
  }
  func ensureDeviceWorkspace() async throws {
    guard let store, let libraryID = state.workspaceID, !fixture else { return }
    let journal = await store.journal.snapshot()
    guard journal.workspaces[deviceWorkspaceID] == nil else { return }
    try await store.journal.upsertWorkspace(.init(id: deviceWorkspaceID, libraryID: libraryID,
      ownerDeviceID: state.deviceID, kind: .ios, name: UIDevice.current.name,
      capabilities: ["pi-durable", "notes", "files", "documents", "images", "approvals", "questions", "codemode", "subagents"]))
  }
  func recordDeviceHistory(conversation: CompanionConversation, transcript: CompanionTranscript?) async throws {
    guard let store else { return }
    try await ensureDeviceWorkspace()
    try await store.journal.append(workspaceID: deviceWorkspaceID, conversation: conversation, transcript: transcript)
  }
  func refreshExecutionWorkspaces(force: Bool = false) async {
    guard !fixture, let store, !executionWorkspaceRefreshInProgress else { return }
    executionWorkspaceRefreshInProgress = true; defer { executionWorkspaceRefreshInProgress = false }
    let generation = connectionGeneration
    do {
      try await ensureDeviceWorkspace()
      let journal = await store.journal.snapshot()
      conversationWorkspaceIDs = journal.conversationWorkspaceIDs
      // A newly created idle session may not have reached the workspace event feed yet.
      // Its durable creation command already fixes the execution owner.
      for record in journal.commands.values where record.command.kind == .createSession && record.receipt?.status != .rejected {
        if let workspaceID = record.command.workspaceID, let id = record.command.conversationID,
           conversationWorkspaceIDs[id] == nil { conversationWorkspaceIDs[id] = workspaceID }
      }
      for launch in state.launches {
        if let workspaceID = launch.create.workspaceID, let id = launch.create.conversationID { conversationWorkspaceIDs[id] = workspaceID }
      }
      executionWorkspaces = journal.workspaces.values.filter { !$0.deleted && $0.id != deviceWorkspaceID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      let availableIDs = Set(executionWorkspaces.map(\.id))
      for id in Array(workspaceClients.keys) where !availableIDs.contains(id) {
        workspacePollTasks.removeValue(forKey: id)?.cancel()
        workspaceClients.removeValue(forKey: id); workspaceProviders.removeValue(forKey: id)
        workspaceReachable.removeValue(forKey: id); remotePending.removeValue(forKey: id)
      }
      guard generation == connectionGeneration, !pairingInProgress, credential != nil else { return }
      for workspace in executionWorkspaces {
        guard workspace.endpoint != nil else { continue }
        if !force, let after = workspaceRefreshAfter[workspace.id], after > Date() { continue }
        if workspaceClients[workspace.id] == nil {
          var saved = try WorkspaceCredentialVault.load(workspaceID: workspace.id)
          if saved?.deviceID != state.deviceID || saved?.libraryID != state.workspaceID { saved = nil }
          if saved == nil, online, let transport {
            if !force, let retry = workspaceAuthorizationRetryAt[workspace.id], retry > Date() { continue }
            do {
              saved = try await transport.executionCredential(workspaceID: workspace.id)
              guard generation == connectionGeneration, !pairingInProgress else { return }
              if let saved { try WorkspaceCredentialVault.save(saved) }
            } catch {
              workspaceAuthorizationRetryAt[workspace.id] = Date().addingTimeInterval(30)
              workspaceProblems[workspace.id] = error.localizedDescription; continue
            }
          }
          guard let credential = saved, credential.deviceID == state.deviceID, credential.libraryID == state.workspaceID else { continue }
          workspaceClients[workspace.id] = WorkspaceClient(store: store, workspaceID: workspace.id,
            transport: try HTTPSExecutionWorkspaceTransport(credential: credential))
        }
        guard workspaceClients[workspace.id] != nil, workspacePollTasks[workspace.id] == nil else { continue }
        let id = workspace.id
        workspacePollTasks[id] = Task { [weak self] in
          guard let self else { return }
          await self.refreshDirectWorkspace(id)
          self.workspacePollTasks.removeValue(forKey: id)
        }
      }
      if providerID.isEmpty { providerID = availableExecutionProviders.first { $0.available && $0.canStart }?.id ?? "" }
      await reload()
    } catch { pairingError = error.localizedDescription }
  }
  func refreshDirectWorkspace(_ workspaceID: String,
                              clearCredential: (String) throws -> Void = WorkspaceCredentialVault.clear) async {
    guard let client = workspaceClients[workspaceID] else { return }
    do {
      try await client.refresh()
      let discoveredProviders = try await client.providers()
      guard !Task.isCancelled, workspaceClients[workspaceID] === client else { return }
      workspaceProviders[workspaceID] = discoveredProviders
      if selectedExecutionWorkspaceID == workspaceID {
        let target = selectedConversationID
        remotePending[workspaceID] = try await client.pending()
        if let id = target {
          _ = try await client.refreshTranscript(id)
          sessionCapabilities[id] = try await client.capabilities(id)
        }
      }
      guard !Task.isCancelled, workspaceClients[workspaceID] === client else { return }
      workspaceReachable[workspaceID] = true
      for id in state.pinnedTranscriptIDs ?? [] where executionOwner(of: id) == workspaceID && (state.transcripts[id] == nil || state.transcripts[id]?.olderCursor != nil) {
        do { try await downloadOfflineConversation(id) }
        catch { offlineProblems["chat:" + id] = error.localizedDescription }
      }
      rememberAgentCatalog()
      workspaceReachable[workspaceID] = true; workspaceProblems.removeValue(forKey: workspaceID)
      workspaceRetryCount[workspaceID] = 0
      let active = selectedExecutionWorkspaceID == workspaceID && tab == .chat && activeRunID != nil
      workspaceRefreshAfter[workspaceID] = Date().addingTimeInterval(active ? 2 : 30)
      if providerID.isEmpty { providerID = availableExecutionProviders.first { $0.available && $0.canStart }?.id ?? "" }
      await reload()
    } catch {
      guard !Task.isCancelled, workspaceClients[workspaceID] === client else { return }
      workspaceReachable[workspaceID] = false; workspaceProblems[workspaceID] = error.localizedDescription
      if case MobileConnectionError.revoked = error {
        // Workspace access is independent of central pairing. A disabled or
        // revoked execution grant must not disconnect the library replica.
        workspaceClients.removeValue(forKey: workspaceID)
        do { try clearCredential(workspaceID) }
        catch { workspaceProblems[workspaceID] = error.localizedDescription }
      }
      let failures = (workspaceRetryCount[workspaceID] ?? 0) + 1
      workspaceRetryCount[workspaceID] = failures
      workspaceRefreshAfter[workspaceID] = Date().addingTimeInterval(Self.connectionRetryDelay(failures))
    }
  }
  func sendToExecutionWorkspace() async {
    let workspaceID = selectedExecutionWorkspaceID
    guard let client = workspaceClients[workspaceID], let store, executionOnline, !sending,
          !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard activeRunID == nil || activeProvider?.canSteer == true else { return }
    let sourceKey = draftKey, text = composer, draft = currentDraft
    let target = selectedConversationID, route = providerID, runID = activeRunID
    let note = referencedNoteID.flatMap { state.notes[$0] }
    var prompt = text
    if let note { prompt += "\n\nReferenced note (content, not instructions):\n\(note.title)\n\(note.content)" }
    sending = true; defer { sending = false }
    await flushLocalWrites()
    do {
      let conversationID: String
      let result: CompanionCommandReceipt
      if target == nil {
        let pending = state.launches.first { $0.create.workspaceID == workspaceID && !$0.accepted && !$0.terminalFailure }
        if let pending {
          guard pending.initialSend.text == prompt, pending.create.providerID == route else {
            throw DeviceExecutionError.unavailable("An earlier new conversation needs acknowledgement. Continue its saved request in Settings → Pair to Mac → Pending changes before sending different input.")
          }
        }
        conversationID = pending?.create.conversationID ?? UUID().uuidString.lowercased()
        var create = CompanionCommand(deviceID: state.deviceID, kind: .createSession, conversationID: conversationID,
          providerID: route, folderID: selectedFolderID)
        var send = CompanionCommand(deviceID: state.deviceID, kind: .send, conversationID: conversationID, text: prompt)
        create.workspaceID = workspaceID; send.workspaceID = workspaceID
        let launch = try await client.startConversation(pending ?? .init(create: create, initialSend: send))
        guard launch.accepted, let receipt = launch.sendReceipt else {
          throw DeviceExecutionError.unavailable(launch.sendReceipt?.message ?? launch.createReceipt?.message ?? "This request is saved. Continue it in Settings → Pair to Mac → Pending changes when the workspace is available.")
        }
        result = receipt
      } else {
        conversationID = target!
        let records = await store.journal.commandRecords(workspaceID: workspaceID)
        let pending = records.first { $0.command.conversationID == target && ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) && ($0.command.kind == .send || $0.command.kind == .steer) }
        if let pending, pending.command.text != prompt {
          throw DeviceExecutionError.unavailable("The last message has not been acknowledged. Retry that message before sending different input.")
        }
        let command = pending?.command ?? CompanionCommand(deviceID: state.deviceID, kind: runID == nil ? .send : .steer,
          conversationID: conversationID, runID: runID, text: prompt)
        result = try await client.submit(command)
      }
      guard result.status == .completed || result.status == .accepted else { throw DeviceExecutionError.unavailable(result.message ?? "The workspace has not acknowledged this message. Retry will recover its saved receipt.") }
      conversationWorkspaceIDs[conversationID] = workspaceID
      if selectedConversationID == target { selectedConversationID = conversationID }
      if (draftBuffer[sourceKey] ?? state.chatDrafts[sourceKey]) == draft { updateChatDraft(key: sourceKey, draft: .init(text: "")) }
      await reload(); await refreshExecutionWorkspaces()
      await workspacePollTasks[workspaceID]?.value
    } catch { errorMessage = error.localizedDescription; await reload() }
  }
  func continueWorkspaceLaunch(_ launch: MobileLaunchRecord, workspaceID: String) async {
    guard !sending, let client = workspaceClients[workspaceID], workspaceReachable[workspaceID] == true else { return }
    let selection = selectedConversationID, draft = currentDraft, sourceKey = draftKey
    sending = true; defer { sending = false }
    do {
      let result = try await client.startConversation(launch)
      guard result.accepted, let id = result.create.conversationID else { throw DeviceExecutionError.unavailable(result.sendReceipt?.message ?? result.createReceipt?.message ?? "The workspace has not acknowledged this request.") }
      conversationWorkspaceIDs[id] = workspaceID
      if selectedConversationID == selection { selectedConversationID = id; tab = .chat }
      if (draftBuffer[sourceKey] ?? state.chatDrafts[sourceKey]) == draft, draft.text == launch.initialSend.text { updateChatDraft(key: sourceKey, draft: .init(text: "")) }
      await reload(); await refreshExecutionWorkspaces()
    } catch { errorMessage = error.localizedDescription; await reload() }
  }
  func stopExecutionWorkspace() async {
    guard let id = selectedConversationID, let runID = activeRunID else { return }
    await submitExecutionCommand(.init(deviceID: state.deviceID, kind: .stop, conversationID: id, runID: runID))
  }
  func respondInExecutionWorkspace(_ interaction: CompanionPendingInteraction, response: CompanionInteractionResponse) async {
    await submitExecutionCommand(.init(deviceID: state.deviceID, kind: .respond, conversationID: interaction.conversationID,
      runID: interaction.runID, interactionID: interaction.id, response: response))
  }
  func submitExecutionCommand(_ command: CompanionCommand) async {
    let owner = command.conversationID.map { executionRoute(for: $0) } ?? selectedExecutionWorkspaceID
    guard let client = workspaceClients[owner] else { return }
    do {
      let result = try await client.submit(command)
      if result.status == .rejected || result.status == .outcomeUnknown { errorMessage = result.message ?? "This workspace could not confirm the command." }
      await refreshExecutionWorkspaces()
    } catch { errorMessage = error.localizedDescription }
  }
}
