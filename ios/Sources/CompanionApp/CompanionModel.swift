import SwiftUI
import Observation
import CompanionClient
import WovenMatterCompanion

@MainActor @Observable final class CompanionModel {
  enum Tab: String, CaseIterable { case home = "Home", folders = "Folders", content = "Content", chat = "Chat", note = "Note"
    var icon: String { switch self { case .home: "house"; case .folders: "folder"; case .content: "rectangle.stack"; case .chat: "bubble.left"; case .note: "doc.text" } }
  }
  var tab: Tab = .home
  var state = MobileStoreState()
  var providers: [CompanionProvider] = []
  var pending: [CompanionPendingInteraction] = []
  var sessionCapabilities: [String: CompanionProvider] = [:]
  var historyPages: [String: CompanionTranscript] = [:]
  var loadingHistory = false
  var selectedFolderID: String?
  var selectedNoteID: String?
  var selectedConversationID: String?
  var providerID = ""
  private var draftBuffer: [String: MobileChatDraft] = [:]
  private var chatDraftTask: Task<Void, Never>?
  private var draftKey: String { selectedConversationID ?? "new-chat" }
  var referencedNoteID: String? {
    get { (draftBuffer[draftKey] ?? state.chatDrafts[draftKey])?.noteID }
    set { var draft = currentDraft; draft.noteID = newValue; updateChatDraft(key: draftKey, draft: draft) }
  }
  var composer: String {
    get { (draftBuffer[draftKey] ?? state.chatDrafts[draftKey])?.text ?? "" }
    set { var draft = currentDraft; draft.text = newValue; updateChatDraft(key: draftKey, draft: draft) }
  }
  private var currentDraft: MobileChatDraft { draftBuffer[draftKey] ?? state.chatDrafts[draftKey] ?? .init(text: "") }
  var online = false
  var connecting = false
  var sending = false
  var connectionLabel = "Local library"
  var errorMessage: String?
  var pairingPresented = false
  var pairingText = ""
  var saveStates: [String: String] = [:]
  var draftTitles: [String: String] = [:]
  var draftContents: [String: String] = [:]
  var credential: MobileCredential?
  var store: MobileStore?
  private var engine: MobileSyncEngine?
  private var transport: HTTPSCompanionTransport?
  private var saveTask: Task<Void, Never>?
  private var saveGenerations: [String: Int] = [:]
  private var refreshInProgress = false
  private var booted = false
  private var frame = 0
  let fixture: Bool
  let isolatedTestHost: Bool

  init() {
    let environment = ProcessInfo.processInfo.environment
    isolatedTestHost = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
    #if DEBUG
    fixture = ProcessInfo.processInfo.environment["WOVENMATTER_UI_FIXTURE"] == "1"
    #else
    fixture = false
    #endif
    if isolatedTestHost {
      // App-hosted unit tests must never open the real library or Keychain.
      // Explicit injected models exercise networking against their fake transport.
      do { store = try MobileStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("WovenMatterTestHost-" + UUID().uuidString).appendingPathComponent("library.json")) }
      catch { errorMessage = error.localizedDescription }
      return
    }
    do {
      let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let namespace = ProcessInfo.processInfo.environment["WOVENMATTER_UI_FIXTURE_NAMESPACE"] ?? "default"
      let safeNamespace = namespace.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
      let filename = fixture ? "fixture-library-\(safeNamespace).json" : "mobile-library.json"
      store = try MobileStore(file: root.appendingPathComponent("WovenMatterCompanion").appendingPathComponent(filename))
    } catch { errorMessage = "The local library could not open: " + error.localizedDescription }
  }
  init(store: MobileStore, transport: any CompanionTransport) {
    fixture = false; isolatedTestHost = false; self.store = store
    engine = MobileSyncEngine(store: store, transport: transport)
    online = true
  }
  func flushLocalWrites() async { await saveTask?.value; await chatDraftTask?.value }
  var folders: [CompanionFolder] { state.folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
  var notes: [CompanionNote] { state.notes.values.sorted { $0.updatedAt > $1.updatedAt } }
  var conversations: [CompanionConversation] { state.conversations.values.sorted { $0.updatedAt > $1.updatedAt } }
  var selectedNote: CompanionNote? { selectedNoteID.flatMap { state.notes[$0] } }
  var selectedConversation: CompanionConversation? { selectedConversationID.flatMap { state.conversations[$0] } }
  var transcript: CompanionTranscript? { selectedConversationID.flatMap { historyPages[$0] ?? state.transcripts[$0] } }
  var activeRunID: String? { selectedConversationID.flatMap { state.transcripts[$0]?.activeRunID } ?? selectedConversation?.activeRunID }
  var activeProvider: CompanionProvider? { selectedConversationID.flatMap { sessionCapabilities[$0] } ?? providers.first { $0.id == (selectedConversation?.providerID ?? providerID) } }
  var currentPending: [CompanionPendingInteraction] { pending.filter { $0.conversationID == selectedConversationID } }
  var unresolvedCommands: [MobileCommandRecord] { state.commands.filter { $0.receipt == nil || $0.receipt?.status == .accepted || $0.receipt?.status == .outcomeUnknown } }

  func run() async {
    guard !isolatedTestHost else { return }
    if !booted {
      booted = true
      await reload()
      if fixture { await seedFixture(); connectionLabel = "Preview · saved on iPhone" }
      else {
        do { credential = try MobileCredentialVault.load(); try configureTransport() }
        catch { errorMessage = error.localizedDescription }
      }
    }
    while !Task.isCancelled {
      if !fixture { await refresh() }
      do { try await Task.sleep(for: .seconds(online ? 1 : 5)) } catch { return }
    }
  }
  func reload() async { if let store { let next = await store.snapshot(); if next != state { state = next } } }
  private func configureTransport() throws {
    guard let credential, let store else { connectionLabel = "Pair your Mac · notes work offline"; return }
    guard credential.deviceID == state.deviceID else { throw CompanionAPIError(code: "device_identity_changed", message: "Pair this local library with your Mac again. The saved credential belongs to a previous app installation; your local notes are safe.") }
    let client = try HTTPSCompanionTransport(credential: credential)
    transport = client; engine = MobileSyncEngine(store: store, transport: client)
  }
  func pair(url: URL) async {
    guard !isolatedTestHost, !fixture else { return }
    guard let store else { return }
    connecting = true
    defer { connecting = false }
    do {
      let payload = try CompanionPairingPayload.parseURL(url)
      let current = await store.snapshot()
      let paired = try await HTTPSCompanionTransport.pair(payload, deviceID: current.deviceID, deviceName: UIDevice.current.name)
      try await store.verifyWorkspace(paired.workspaceID)
      await reload()
      try MobileCredentialVault.save(paired)
      credential = paired
      try configureTransport()
      pairingPresented = false; pairingText = ""
      await refresh()
    } catch { errorMessage = error.localizedDescription }
  }
  func refresh() async {
    guard let engine, !refreshInProgress else { return }
    refreshInProgress = true; connecting = !online
    defer { refreshInProgress = false; connecting = false }
    let targetConversationID = selectedConversationID
    do {
      try await engine.synchronize()
      if frame % 5 == 0 || providers.isEmpty { providers = try await engine.providers() }
      pending = try await engine.pending()
      if let targetConversationID {
        try await engine.refreshTranscriptIfNeeded(targetConversationID)
        if let transport { sessionCapabilities[targetConversationID] = try await transport.capabilities(targetConversationID) }
      }
      if frame % 5 == 0 { try await engine.recoverCommandReceipts() }
      frame += 1
      await reload()
      online = true; connectionLabel = "Connected to Mac"
      if providerID.isEmpty { providerID = providers.first(where: { $0.available })?.id ?? "" }
    } catch {
      online = false
      connectionLabel = (error as? MobileConnectionError).map { _ in error.localizedDescription } ?? "Mac unavailable · notes work offline"
      if error is MobileStore.Failure { errorMessage = error.localizedDescription }
      await reload()
    }
  }
  func newFolder(name: String) async {
    guard let store, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    do { selectedFolderID = try await store.createFolder(name: name).id; await reload() }
    catch { errorMessage = error.localizedDescription }
  }
  func newNote() async {
    guard let store else { return }
    do {
      let note = try await store.createNote(folderID: selectedFolderID, title: "Untitled note", content: NoteDocument().encoded())
      selectedNoteID = note.id; tab = .note; await reload()
    } catch { errorMessage = error.localizedDescription }
  }
  func openNote(_ id: String) async {
    await store?.protectOpenNote(id)
    selectedNoteID = id; tab = .note
    if state.uncachedNoteIDs.contains(id), online, let store, let transport {
      do { try await store.cacheNote(transport.asset(id)); await reload() }
      catch { errorMessage = error.localizedDescription }
    }
  }
  func selectConversation(_ id: String) async {
    selectedConversationID = id; tab = .chat
    await refresh()
  }
  func loadEarlierMessages() async {
    guard online, let engine, let target = selectedConversationID, let before = transcript?.olderCursor, !loadingHistory else { return }
    loadingHistory = true
    defer { loadingHistory = false }
    do { historyPages[target] = try await engine.earlierTranscript(target, before: before) }
    catch { errorMessage = error.localizedDescription }
  }
  func showLatestMessages() { if let selectedConversationID { historyPages.removeValue(forKey: selectedConversationID) } }
  func newChat() { selectedConversationID = nil; tab = .chat }
  func saveNote(id: String, title: String, content: String, base: CompanionNote) {
    guard let store else { return }
    draftTitles[id] = title; draftContents[id] = content
    let generation = (saveGenerations[id] ?? 0) + 1
    saveGenerations[id] = generation; saveStates[id] = "Saving on iPhone…"
    let previous = saveTask
    let folder = state.notes[id]?.folderID
    saveTask = Task {
      await previous?.value
      do {
        try await store.editNote(id: id, title: title, content: content, folderID: folder, base: base)
        await reload()
        if saveGenerations[id] == generation {
          saveStates[id] = "Saved on iPhone"
          draftTitles.removeValue(forKey: id); draftContents.removeValue(forKey: id)
        }
      } catch { if saveGenerations[id] == generation { saveStates[id] = "Couldn’t save · writing kept open"; errorMessage = error.localizedDescription } }
    }
  }
  func saveLabel(_ id: String) -> String {
    if let value = saveStates[id], value != "Saved on iPhone" { return value }
    if state.conflicts[id] != nil { return "Saved on iPhone · conflict needs attention" }
    return state.isDirty(id) ? "Saved on iPhone · waiting to sync" : "Saved · synced with Mac"
  }
  func linkedData(note: CompanionNote, tableID: String? = nil) async throws -> CompanionLinkedData {
    guard online, let engine else { throw MobileConnectionError.offline }
    let result = try await engine.linkedData(note: note, tableID: tableID)
    guard state.notes[note.id]?.revision == note.revision else { throw CancellationError() }
    return result
  }
  func preserveConflict(_ id: String) async {
    guard let store else { return }
    do { selectedNoteID = try await store.preserveConflictAsCopy(id: id).id; await reload() }
    catch { errorMessage = error.localizedDescription }
  }
  private func updateChatDraft(key: String, draft: MobileChatDraft) {
    draftBuffer[key] = draft
    guard let store else { return }
    let previous = chatDraftTask
    chatDraftTask = Task {
      await previous?.value
      do { try await store.saveChatDraft(key: key, draft: draft) }
      catch { errorMessage = "Couldn’t save this message draft: " + error.localizedDescription }
    }
  }
  func send() async {
    guard online, let engine, !sending, !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    // Capture target, route, text and reference before yielding. Switching tabs or
    // sessions during save/network work can never redirect this command.
    let sourceKey = draftKey
    let target = selectedConversationID
    let text = composer
    let noteID = referencedNoteID
    let route = providerID
    let folder = selectedFolderID
    let runID = activeRunID
    let provider = activeProvider
    let draftContext = currentDraft
    let deviceID = state.deviceID
    let pendingLaunch = target == nil ? state.launches.first(where: { !$0.accepted && !$0.terminalFailure }) : nil
    sending = true
    defer { sending = false }
    await saveTask?.value
    await chatDraftTask?.value
    if runID != nil && provider?.canSteer != true { errorMessage = "This session does not currently support steering. Stop it or wait for completion."; return }
    if target == nil && (provider?.available != true || provider?.canStart != true) { errorMessage = "Choose an available agent route on your Mac."; return }
    do {
      let receipt: CompanionCommandReceipt
      if target == nil {
        let conversationID = pendingLaunch?.create.conversationID ?? UUID().uuidString.lowercased()
        let launch: MobileLaunchRecord
        if let pendingLaunch {
          guard pendingLaunch.initialSend.text == text, pendingLaunch.initialSend.noteID == noteID else {
            errorMessage = "A previous new-chat request still needs acknowledgement. Continue it from Home before starting another."; return
          }
          launch = pendingLaunch
        } else {
          launch = .init(create: .init(deviceID: deviceID, kind: .createSession, conversationID: conversationID, providerID: route, folderID: folder),
            initialSend: .init(deviceID: deviceID, kind: .send, conversationID: conversationID, text: text, noteID: noteID))
        }
        let result = try await engine.startConversation(launch)
        guard result.accepted, let accepted = result.sendReceipt else {
          if result.createReceipt?.status == .completed, result.sendReceipt?.status == .rejected, selectedConversationID == target {
            updateChatDraft(key: conversationID, draft: .init(text: text, noteID: noteID))
            selectedConversationID = conversationID
          }
          await reload(); errorMessage = result.sendReceipt?.message ?? result.createReceipt?.message ?? "The session request is saved. Continue it from Home when the Mac is available."; return
        }
        receipt = accepted
        if selectedConversationID == target { selectedConversationID = receipt.conversationID ?? conversationID }
      } else {
        let unresolved = state.commands.first { $0.command.conversationID == target && ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) && ($0.command.kind == .send || $0.command.kind == .steer) }
        let command: CompanionCommand
        if let unresolved {
          guard unresolved.command.text == text, unresolved.command.noteID == noteID else {
            errorMessage = "This conversation has an unacknowledged command. Resolve it from Home before sending different input."; return
          }
          command = unresolved.command
        } else {
          command = .init(deviceID: deviceID, kind: runID == nil ? .send : .steer, conversationID: target, runID: runID, text: text, noteID: noteID)
        }
        receipt = try await engine.submit(command)
      }
      guard receipt.status != .rejected, receipt.status != .outcomeUnknown else { errorMessage = receipt.message ?? "The Mac did not accept this command."; await reload(); return }
      let original = draftBuffer[sourceKey] ?? state.chatDrafts[sourceKey]
      if original == draftContext && providerID == route { updateChatDraft(key: sourceKey, draft: .init(text: "")) }
      await refresh()
    } catch { errorMessage = error.localizedDescription; await reload() }
  }
  func continueLaunch(_ launch: MobileLaunchRecord) async {
    guard online, let engine, !sending else { return }
    let selection = selectedConversationID
    let sourceTab = tab
    let sourceFolder = selectedFolderID
    let sourceNote = selectedNoteID
    let route = providerID
    let draft = draftBuffer["new-chat"] ?? state.chatDrafts["new-chat"]
    sending = true
    defer { sending = false }
    do {
      let result = try await engine.startConversation(launch)
      if result.accepted {
        let current = draftBuffer["new-chat"] ?? state.chatDrafts["new-chat"]
        let unchanged = current == draft && providerID == route
        if selectedConversationID == selection, tab == sourceTab, selectedFolderID == sourceFolder, selectedNoteID == sourceNote, unchanged {
          selectedConversationID = result.initialSend.conversationID; tab = .chat
        }
        if unchanged, draft?.text == result.initialSend.text, draft?.noteID == result.initialSend.noteID,
           draft?.providerID == nil || draft?.providerID == result.create.providerID {
          updateChatDraft(key: "new-chat", draft: .init(text: ""))
        }
      } else { errorMessage = result.sendReceipt?.message ?? result.createReceipt?.message ?? "Waiting for the Mac to acknowledge this request." }
      await reload(); await refresh()
    } catch { errorMessage = error.localizedDescription; await reload() }
  }
  func stop() async {
    guard let conversationID = selectedConversationID, let runID = activeRunID, online, activeProvider?.canStop == true else { return }
    await submit(.init(deviceID: state.deviceID, kind: .stop, conversationID: conversationID, runID: runID))
  }
  func respond(_ interaction: CompanionPendingInteraction, response: CompanionInteractionResponse) async {
    await submit(.init(deviceID: state.deviceID, kind: .respond, conversationID: interaction.conversationID,
      runID: interaction.runID, interactionID: interaction.id, response: response))
  }
  func retry(_ record: MobileCommandRecord) async { await submit(record.command) }
  private func submit(_ command: CompanionCommand) async {
    guard online, let engine else { errorMessage = MobileConnectionError.offline.localizedDescription; return }
    do {
      let result = try await engine.submit(command)
      if result.status == .rejected || result.status == .outcomeUnknown { errorMessage = result.message ?? "This request was not accepted." }
      await reload(); await refresh()
    } catch { errorMessage = error.localizedDescription; await reload() }
  }

  private func seedFixture() async {
    guard let store else { return }
    do {
      if state.notes.isEmpty {
        let note = CompanionNote(id: "11111111-1111-4111-8111-111111111111", folderID: "inbox", title: "Launch Plan", content: try NoteDocument(blocks: [
          .richText(.init(text: "Capture ideas wherever you are.")),
          .richText(.init(style: .bulletedList, text: "Your notes are saved on this iPhone.")),
          .richText(.init(style: .bulletedList, text: "Reconnect to bring the plan back to your Mac.")),
        ]).encoded())
        try await store.apply(CompanionSnapshot(workspaceID: "fixture", cursor: 1, folders: [.init(id: "inbox", name: "Inbox")], notes: [note], conversations: [
          .init(id: "fixture-chat", title: "Launch plan", folderID: "inbox", providerID: "local:codex", runtimeKind: "codex", preview: "A focused plan for the next release.")]))
        try await store.cache(.init(conversationID: "fixture-chat", messages: [
          .init(id: "user", conversationID: "fixture-chat", role: "user", content: "Summarize the launch plan."),
          .init(id: "assistant", conversationID: "fixture-chat", role: "assistant", content: "A focused plan for the next release.\n\n• Capture the idea in a note.\n• Review it together on the Mac.\n• Keep the next step small and clear.", status: "completed")], activities: [.init(id: "activity", runID: "fixture-run", title: "Run finished", detail: "The plan is ready for review.", status: "completed")]))
      }
      await reload()
      if ProcessInfo.processInfo.environment["WOVENMATTER_UI_SCENARIO"] == "conflict", state.conflicts.isEmpty,
         let base = state.notes["11111111-1111-4111-8111-111111111111"] {
        let localContent = try NoteDocument(blocks: [.richText(.init(text: "The idea I captured on the train: make the next release small, focused, and easy to try."))]).encoded()
        try await store.editNote(id: base.id, title: base.title, content: localContent, folderID: base.folderID, base: base)
        if let mutation = try await store.nextMutation() {
          var remote = base; remote.revision += 1
          remote.content = try NoteDocument(blocks: [.richText(.init(text: "The Mac review adds a pairing checklist and a short test plan before the next release."))]).encoded()
          try await store.acknowledge(.init(operationID: mutation.operationID, status: .conflict, note: remote, message: "This note changed on both devices. Both versions are saved."))
        }
        await reload()
      }
      selectedNoteID = notes.first?.id; selectedConversationID = "fixture-chat"
      if ProcessInfo.processInfo.environment["WOVENMATTER_UI_SCENARIO"] == "pairing" { pairingPresented = true }
      tab = Tab(rawValue: ProcessInfo.processInfo.environment["WOVENMATTER_UI_TAB"] ?? "Folders") ?? .folders
    } catch { errorMessage = error.localizedDescription }
  }
}
