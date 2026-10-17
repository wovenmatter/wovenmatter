import SwiftUI
import Observation
import CompanionClient
import WovenMatterCompanion
import PiDurableRuntime
import CompanionInference

@MainActor @Observable final class CompanionModel {
  enum Tab: String, CaseIterable { case home = "Home", folders = "Folders", chat = "Chats", note = "Notes", settings = "Settings", calendar = "Calendar", scheduledTasks = "Scheduled tasks", library = "Library", databases = "Databases", usage = "Usage", trash = "Trash"
    var icon: DashboardLucideGlyph {
      switch self {
      case .home: .house
      case .folders: .folder
      case .chat: .messageSquare
      case .note: .fileText
      case .settings: .settings
      case .library: .libraryBig
      case .calendar: .calendarDays
      case .scheduledTasks: .calendarClock
      case .databases: .database
      case .usage: .barChart
      case .trash: .trash
      }
    }
  }
  let analytics = MobileAnalyticsModel()
  var tab: Tab = .home
  var state = MobileStoreState()
  var providers: [CompanionProvider] = []
  var knownAgentIDs: Set<String> = []
  var selectedConversationRoute: (conversationID: String, workspaceID: String)?
  var savedAgentCatalog: CompanionAgentCatalog?
  var pending: [CompanionPendingInteraction] = []
  var sessionCapabilities: [String: CompanionProvider] = [:]
  var historyPages: [String: CompanionTranscript] = [:]
  @ObservationIgnored let transcriptStates = MobileConversationStates()
  var loadingHistory = false
  var selectedFolderID: String?
  var folderContentsPresented = false
  var selectedNoteID: String?
  var selectedConversationID: String?
  var providerID = ""
  var draftBuffer: [String: MobileChatDraft] = [:]
  var chatDraftTask: Task<Void, Never>?
  var draftKey: String { selectedConversationID ?? "new-chat" }
  var referencedNoteID: String? {
    get { (draftBuffer[draftKey] ?? state.chatDrafts[draftKey])?.noteID }
    set { var draft = currentDraft; draft.noteID = newValue; updateChatDraft(key: draftKey, draft: draft) }
  }
  var composer: String {
    get { (draftBuffer[draftKey] ?? state.chatDrafts[draftKey])?.text ?? "" }
    set { var draft = currentDraft; draft.text = newValue; updateChatDraft(key: draftKey, draft: draft) }
  }
  var currentDraft: MobileChatDraft { draftBuffer[draftKey] ?? state.chatDrafts[draftKey] ?? .init(text: "") }
  var online = false
  var connecting = false
  var sending = false
  var connectionLabel = "Local library"
  var errorMessage: String?
  var pairingPresented = false
  var pairingText = ""
  var pairingError: String?
  var pairingInProgress = false
  var synchronizationStatus = MobileSynchronizationStatus()
  var connectionGeneration = UUID()
  var connectionForeground = true
  var automaticSynchronization = true
  var centralRetryCount = 0
  var centralRefreshAfter = Date.distantPast
  var connectionRefreshTask: Task<Void, Never>?
  @ObservationIgnored var networkMonitor: MobileNetworkMonitor?
  var workspaceRefreshAfter: [String: Date] = [:]
  var workspaceRetryCount: [String: Int] = [:]
  var offlineOperationIDs: Set<String> = []
  var offlineProblems: [String: String] = [:]
  var saveStates: [String: String] = [:]
  var draftTitles: [String: String] = [:]
  var draftContents: [String: String] = [:]
  var credential: MobileCredential?
  var store: MobileStore?
  var engine: MobileSyncEngine?
  var transport: HTTPSCompanionTransport?
  var saveTask: Task<Void, Never>?
  private var saveGenerations: [String: Int] = [:]
  private var refreshInProgress = false
  private var workspaceActionInProgress = false
  private var booted = false
  var initialized = false
  var executionWorkspaceID = "local"
  var executionSettingsPresented = false
  var chatChooserPresented = false
  var startingChat = false
  var chatSettingsBusy = false
  var chatSetupProblem: String?
  var pendingChatCreation: CompanionCommand?
  var newChatNoteID: String?
  var draftDeviceSettings = DeviceChatSettings()
  var configuringDeviceSessions: Set<String> = []
  var deviceAgentDefaults = DeviceAgentDefaults()
  var inferenceConnections: [InferenceConnection] = []
  var inferenceConnectionID = ""
  var conversationWorkspaceIDs: [String: String] = [:]
  var executionRecords: [String: DeviceConversationRecord] = [:]
  var localRuntimes: [String: PiDurableRuntime] = [:]
  var localStopping: Set<String> = []
  var localRunTokens: [String: String] = [:]
  var localExecutionAttempts: [String: String] = [:]
  var localInterrupting: Set<String> = []
  var deviceSnapshotInProgress: Set<String> = []
  var localRunTasks: [String: Task<Void, Never>] = [:]
  var localApprovals: [String: LocalToolApproval] = [:]
  var localQuestionAnswers: [String: String] = [:]
  var localPending: [CompanionPendingInteraction] = []
  var executionWorkspaces: [CompanionExecutionWorkspace] = []
  var workspacePollTasks: [String: Task<Void, Never>] = [:]
  var workspaceClients: [String: WorkspaceClient] = [:]
  var workspaceProviders: [String: [CompanionProvider]] = [:]
  var workspaceReachable: [String: Bool] = [:]
  var executionWorkspaceRefreshInProgress = false
  var remotePending: [String: [CompanionPendingInteraction]] = [:]
  var workspaceAuthorizationRetryAt: [String: Date] = [:]
  var workspaceProblems: [String: String] = [:]
  var inferenceProblem: String?
  var executionDirectory: URL?
  var executionRefreshTasks: [String: Task<Void, Never>] = [:]
  var executionCredentialStore = InferenceCredentialStore()
  let deviceBackgroundExecution = DeviceBackgroundExecution()
  var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
  var backgroundFallbackToken: UUID?
  var calendarRevision = 0
  var deviceScheduleTask: Task<Void, Never>?
  var processingDeviceSchedule = false

  private var frame = 0
  let fixture: Bool
  let isolatedTestHost: Bool

  private static var smokeIsolationRequested: Bool {
    #if DEBUG
    return DeviceRuntimeSmoke.enabled
    #else
    return false
    #endif
  }
  init() {
    let environment = ProcessInfo.processInfo.environment
    isolatedTestHost = Self.smokeIsolationRequested || environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
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
      let libraryRoot = root.appendingPathComponent("WovenMatterCompanion")
      store = try MobileStore(file: libraryRoot.appendingPathComponent(filename))
      executionDirectory = libraryRoot.appendingPathComponent(fixture ? "fixture-execution-\(safeNamespace)" : "execution", isDirectory: true)
    } catch { errorMessage = "The local library could not open: " + error.localizedDescription }
  }
  init(store: MobileStore, transport: any CompanionTransport) {
    fixture = false; isolatedTestHost = false; automaticSynchronization = false; self.store = store
    executionWorkspaceID = "central"
    engine = MobileSyncEngine(store: store, transport: transport)
    online = true
  }
  func flushLocalWrites() async { await saveTask?.value; await chatDraftTask?.value }
  var folders: [CompanionFolder] { state.folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
  var notes: [CompanionNote] { state.notes.values.sorted { ($0.isPinned == true) != ($1.isPinned == true) ? $0.isPinned == true : $0.updatedAt > $1.updatedAt } }
  var conversations: [CompanionConversation] { state.conversations.values.sorted { ($0.isPinned == true) != ($1.isPinned == true) ? $0.isPinned == true : $0.updatedAt > $1.updatedAt } }
  var selectedNote: CompanionNote? { selectedNoteID.flatMap { state.notes[$0] } }
  var selectedConversation: CompanionConversation? { selectedConversationID.flatMap { state.conversations[$0] } }
  var transcript: CompanionTranscript? { selectedConversationID.flatMap { historyPages[$0] ?? state.transcripts[$0] } }
  var activeRunID: String? {
    if let id = selectedConversationID, let record = executionRecords[id] { return (record.status == "running" || record.status == "stopping") ? record.runID : nil }
    return selectedConversationID.flatMap { state.transcripts[$0]?.activeRunID } ?? selectedConversation?.activeRunID
  }
  var centralProvider: CompanionProvider? { selectedConversationID.flatMap { sessionCapabilities[$0] } ?? providers.first { $0.id == (selectedConversation?.providerID ?? providerID) } }
  var allPending: [CompanionPendingInteraction] { pending + localPending + remotePending.values.flatMap { $0 } }
  var currentPending: [CompanionPendingInteraction] { allPending.filter { $0.conversationID == selectedConversationID } }
  var unresolvedCommands: [MobileCommandRecord] { state.commands.filter { $0.receipt == nil || $0.receipt?.status == .accepted || $0.receipt?.status == .outcomeUnknown } }

  func run() async {
    guard !isolatedTestHost else { return }
    if !booted {
      booted = true
      defer { initialized = true }
      await reload()
      if fixture { await seedFixture() }
      else {
        do { try await store?.recoverPairingTransition(); await reload(); credential = try MobileCredentialVault.load() }
        catch { errorMessage = error.localizedDescription; return }
        var unpairRequested = false
        #if DEBUG
        if CommandLine.arguments.contains("--unpair-devices") {
          unpairRequested = true
          await disconnectMac()
          let result: [String: Any] = ["unpaired": pairingError == nil && credential == nil && workspaceClients.isEmpty,
            "workspaceDetached": state.workspaceID == nil, "noteCount": state.notes.count,
            "conversationCount": state.conversations.count]

          if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("wovenmatter-unpair-result.json"), options: .atomic)
          }
        }
        #endif
        if !unpairRequested {
          do {
            if let pending = credential, pending.confirmationPending == true {
              credential = nil
              try await acceptPairing(pending, allowingLibraryChange: true) { try MobileCredentialVault.save($0) }
            } else { try configureTransport() }
          } catch { pairingError = error.localizedDescription; credential = nil }
        }
        do { try await store?.interruptExecutorJobs(); try await loadExecutionConfiguration() }
        catch { errorMessage = error.localizedDescription }
      }
    }
    if let store { await analytics.configure(store.analytics, transport: transport) }
    if !fixture && UIApplication.shared.applicationState == .active { startDeviceScheduler() }
    await maintainConnections()
  }
  func reload() async {
    await analytics.refresh()
    if let store {
      let next = await store.snapshot()
      let changedOutbox = next.outbox != state.outbox
      if next != state { state = next }
      if changedOutbox && !next.outbox.isEmpty { requestSynchronization() }
    }
    calendarRevision &+= 1
    await refreshSynchronizationStatus()
  }
  private func configureTransport() throws {
    guard let credential, let store else { connectionLabel = "Saved on this device"; return }
    guard credential.deviceID == state.deviceID else { throw CompanionAPIError(code: "device_identity_changed", message: "Pair this local library with your Mac again. The saved credential belongs to a previous app installation; your local notes are safe.") }
    let client = try HTTPSCompanionTransport(credential: credential, metadata: deviceMetadata)
    transport = client; engine = MobileSyncEngine(store: store, transport: client)
  }
  func pair(url: URL) async {
    guard !isolatedTestHost, !fixture, let store, !pairingInProgress else { return }
    pairingInProgress = true; pairingError = nil
    defer { pairingInProgress = false }
    do {
      let payload = try CompanionPairingPayload.parseURL(url)
      let current = await store.snapshot()
      // A lost confirmation reply must be recoverable by scanning again, not
      // only by restarting the app. Never send a stored grant to a new endpoint.
      if let pending = try MobileCredentialVault.load(), pending.confirmationPending == true,
        pending.endpoint == payload.endpoint {
        if (current.workspaceID ?? current.detachedWorkspaceID) != pending.workspaceID,
          !localRunTasks.isEmpty || processingDeviceSchedule {
          throw DeviceExecutionError.unavailable("Finish the running device agents before changing the central database.")
        }
        await flushLocalWrites()
        stopDeviceScheduler()
        defer { if connectionForeground { startDeviceScheduler() } }
        do {
          try await acceptPairing(pending, allowingLibraryChange: true) { try MobileCredentialVault.save($0) }
          pairingText = ""
          await refresh(); await refreshExecutionWorkspaces(force: true)
          return
        } catch MobileConnectionError.revoked {
          // Expired or explicitly revoked enrollment needs the fresh QR offer.
          try MobileCredentialVault.clear()
        }
      }
      let target = try await HTTPSCompanionTransport.previewPairing(payload, deviceID: current.deviceID,
        deviceName: UIDevice.current.name, metadata: deviceMetadata)
      if (current.workspaceID ?? current.detachedWorkspaceID) != target,
        !localRunTasks.isEmpty || processingDeviceSchedule {
        throw DeviceExecutionError.unavailable("Finish the running device agents before changing the central database.")
      }
      await flushLocalWrites()
      stopDeviceScheduler()
      defer { if connectionForeground { startDeviceScheduler() } }
      let paired = try await HTTPSCompanionTransport.pair(payload, deviceID: current.deviceID,
        deviceName: UIDevice.current.name, metadata: deviceMetadata, expectedWorkspaceID: target, requiresConfirmation: true)
      try await acceptPairing(paired, allowingLibraryChange: true) { try MobileCredentialVault.save($0) }
      pairingText = ""
      await refresh()
      await refreshExecutionWorkspaces(force: true)
    } catch { pairingError = error.localizedDescription }
  }
  func refresh() async {
    guard let engine, !refreshInProgress else { return }
    refreshInProgress = true; connecting = true
    let generation = connectionGeneration
    let activeTransport = transport
    defer { refreshInProgress = false; connecting = false }
    let targetConversationID = selectedExecutionWorkspaceID == "central" ? selectedConversationID : nil
    do {
      try await engine.synchronize()
      guard generation == connectionGeneration, !Task.isCancelled else { return }
      let refreshedProviders = frame % 5 == 0 || providers.isEmpty ? try await engine.providers() : providers
      let refreshedPending = try await engine.pending()
      var capability: CompanionProvider?
      if let targetConversationID {
        try await engine.refreshTranscriptIfNeeded(targetConversationID)
        if let activeTransport { capability = try await activeTransport.capabilities(targetConversationID) }
      }
      if frame % 5 == 0 { try await engine.recoverCommandReceipts() }
      let status = await engine.synchronizationStatus()
      guard generation == connectionGeneration, !Task.isCancelled else { return }
      providers = refreshedProviders; pending = refreshedPending
      if let capability, let targetConversationID { sessionCapabilities[targetConversationID] = capability }
      synchronizationStatus = status
      frame += 1
      online = true; connectionLabel = "Connected"
      centralRetryCount = 0
      centralRefreshAfter = Date().addingTimeInterval(tab == .chat && selectedExecutionWorkspaceID == "central" && activeRunID != nil ? 2 : 15)
      if providerID.isEmpty { providerID = providers.first(where: { $0.available })?.id ?? "" }
      await reload(); rememberAgentCatalog()
    } catch {
      guard generation == connectionGeneration, !Task.isCancelled else { return }
      let status = await engine.synchronizationStatus()
      guard generation == connectionGeneration else { return }
      synchronizationStatus = status
      online = status.centralReachable == true
      connectionLabel = online ? "Connected" : "Disconnected"
      centralRetryCount += 1
      centralRefreshAfter = Date().addingTimeInterval(Self.connectionRetryDelay(centralRetryCount))
      await reload()
    }
  }
  func openFolder(_ id: String?) {
    selectedFolderID = id; folderContentsPresented = true; tab = .folders
  }
  func closeFolder() { selectedFolderID = nil; folderContentsPresented = false }
  func newFolder(name: String) async {
    guard let store, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    do { let folder = try await store.createFolder(name: name); await analytics.record(.active); await reload(); openFolder(folder.id) }
    catch { errorMessage = error.localizedDescription }
  }
  func newNote() async {
    guard let store else { return }
    do {
      let note = try await store.createNote(folderID: selectedFolderID, title: "Untitled note", content: NoteDocument().encoded())
      await analytics.record(.active)
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
  func selectConversation(_ id: String, workspaceID: String? = nil) async {
    selectedConversationRoute = (id, workspaceID ?? preferredExecutionRoute(for: id))
    selectedConversationID = id; tab = .chat
    if selectedExecutionWorkspaceID == "local" { await openDeviceConversation(id) }
    else if selectedExecutionWorkspaceID == "central" { await refresh() }
    else { await refreshExecutionWorkspaces(force: true) }
  }
  func refreshConversation() async {
    let owner = selectedExecutionWorkspaceID
    if owner == "local", let id = selectedConversationID { await openDeviceConversation(id) }
    else if owner == "central" { await refresh() }
    else { await refreshDirectWorkspace(owner) }
  }
  func loadEarlierMessages() async {
    if selectedExecutionWorkspaceID != "central", let client = workspaceClients[selectedExecutionWorkspaceID], let target = selectedConversationID,
       let before = transcript?.olderCursor, !loadingHistory {
      loadingHistory = true; defer { loadingHistory = false }
      do { historyPages[target] = try await client.earlierTranscript(target, before: before) }
      catch { errorMessage = error.localizedDescription }
      return
    }
    guard online, let engine, let target = selectedConversationID, let before = transcript?.olderCursor, !loadingHistory else { return }
    loadingHistory = true
    defer { loadingHistory = false }
    do { historyPages[target] = try await engine.earlierTranscript(target, before: before) }
    catch { errorMessage = error.localizedDescription }
  }
  func showLatestMessages() { if let selectedConversationID { historyPages.removeValue(forKey: selectedConversationID) } }
  func newChat(referencing noteID: String? = nil) {
    newChatNoteID = noteID; chatSetupProblem = nil; chatChooserPresented = true
  }
  func saveNote(id: String, title: String, content: String, base: CompanionNote) {
    guard let store else { return }
    draftTitles[id] = title; draftContents[id] = content
    let generation = (saveGenerations[id] ?? 0) + 1
    saveGenerations[id] = generation; saveStates[id] = "Saving on this device…"
    let previous = saveTask
    let folder = state.notes[id]?.folderID
    saveTask = Task {
      await previous?.value
      do {
        try await store.editNote(id: id, title: title, content: content, folderID: folder, base: base)
        await analytics.record(.active)
        await reload()
        if saveGenerations[id] == generation {
          saveStates[id] = "Saved on this device"
          draftTitles.removeValue(forKey: id); draftContents.removeValue(forKey: id)
        }
      } catch { if saveGenerations[id] == generation { saveStates[id] = "Couldn’t save · writing kept open"; errorMessage = error.localizedDescription } }
    }
  }
  func saveLabel(_ id: String) -> String {
    if let value = saveStates[id], value != "Saved on this device" { return value }
    if state.conflicts[id] != nil { return "Saved on this device · conflict needs attention" }
    guard state.workspaceID != nil else { return "Saved on this device" }
    if state.isDirty(id) { return "Saved on this device · waiting to sync" }
    return "Saved · synced with Mac"
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
  func updateChatDraft(key: String, draft: MobileChatDraft) {
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
    guard !chatSettingsBusy, !startingChat else { return }
    if selectedExecutionWorkspaceID == "local" { await sendOnDevice(); return }
    if selectedExecutionWorkspaceID != "central" { await sendToExecutionWorkspace(); return }
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
    let pendingLaunch = target == nil ? state.launches.first(where: { $0.create.workspaceID == nil && !$0.accepted && !$0.terminalFailure }) : nil
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
            errorMessage = "A previous new-chat request still needs acknowledgement. Continue it in Settings → Pair to Mac → Pending changes before starting another."; return
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
          await reload(); errorMessage = result.sendReceipt?.message ?? result.createReceipt?.message ?? "The session request is saved. Continue it in Settings → Pair to Mac → Pending changes when the Mac is available."; return
        }
        receipt = accepted
        if selectedConversationID == target { selectedConversationID = receipt.conversationID ?? conversationID }
      } else {
        let unresolved = state.commands.first { $0.command.conversationID == target && ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) && ($0.command.kind == .send || $0.command.kind == .steer) }
        let command: CompanionCommand
        if let unresolved {
          guard unresolved.command.text == text, unresolved.command.noteID == noteID else {
            errorMessage = "This conversation has an unacknowledged command. Resolve it in Settings → Pair to Mac → Pending changes before sending different input."; return
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
    if let workspaceID = launch.create.workspaceID { await continueWorkspaceLaunch(launch, workspaceID: workspaceID); return }
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
    if selectedExecutionWorkspaceID == "local" { await stopOnDevice(); return }
    if selectedExecutionWorkspaceID != "central" { await stopExecutionWorkspace(); return }
    guard let conversationID = selectedConversationID, let runID = activeRunID, online, activeProvider?.canStop == true else { return }
    await submit(.init(deviceID: state.deviceID, kind: .stop, conversationID: conversationID, runID: runID))
  }
  func respond(_ interaction: CompanionPendingInteraction, response: CompanionInteractionResponse) async {
    if let approval = localApprovals.removeValue(forKey: interaction.id) {
      localPending.removeAll { $0.id == interaction.id }
      if !response.answers.isEmpty {
        localQuestionAnswers[interaction.id] = response.answers.values.flatMap { $0 }.joined(separator: "\n")
      }
      approval.continuation.resume(returning: !response.cancelled && (response.optionID == "allow" || !response.answers.isEmpty))
      return
    }
    if executionRoute(for: interaction.conversationID) != "central" { await respondInExecutionWorkspace(interaction, response: response); return }
    await submit(.init(deviceID: state.deviceID, kind: .respond, conversationID: interaction.conversationID,
      runID: interaction.runID, interactionID: interaction.id, response: response))
  }
  func workspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult {
    if let result = try await readLocalCalendar(request) { return result }
    let conversationID: String?
    switch request { case .session(let id), .exportConversation(let id, _): conversationID = id; default: conversationID = nil }
    if let id = conversationID {
      let owner = executionRoute(for: id)
      if owner == "local" { return try await readDeviceWorkspace(request) }
      if owner != "central" {
        guard let client = workspaceClients[owner] else { throw DeviceExecutionError.unavailable("This execution workspace is unavailable.") }
        return try await client.readWorkspace(request)
      }
    }
    guard online, let engine else { throw MobileConnectionError.offline }
    return try await engine.readWorkspace(request)
  }
  @discardableResult
  func perform(_ action: CompanionWorkspaceAction) async -> Bool {
    if let result = await performLocalCalendar(action) {
      if result, action.qualifiesForAnalytics { await analytics.record(.active) }
      return result
    }
    let conversationID: String?
    switch action {
    case .goal(let id, _), .conversation(let id, _, _, _), .configureSession(let id, _, _, _), .sessionTools(let id, _, _): conversationID = id
    default: conversationID = nil
    }
    if let id = conversationID {
      let owner = executionRoute(for: id)
      if owner == "local" {
        let accepted=await performDeviceAction(action)
        if accepted, action.qualifiesForAnalytics { await analytics.record(.active) }
        return accepted
      }
      if owner != "central" {
        guard let client = workspaceClients[owner] else { errorMessage = "This execution workspace is unavailable."; return false }
        do {
          let command = CompanionCommand(deviceID: state.deviceID, kind: .workspace, conversationID: id, workspaceAction: action)
          let result = try await client.submit(command)
          guard result.status == .completed else { errorMessage = result.message ?? "The workspace has not confirmed this change."; return false }
          if action.qualifiesForAnalytics { await analytics.record(.active) }
          await refreshExecutionWorkspaces(); return true
        } catch { errorMessage = error.localizedDescription; return false }
      }
    }
    guard online, let engine else { errorMessage = MobileConnectionError.offline.localizedDescription; return false }
    guard !workspaceActionInProgress else { return false }
    workspaceActionInProgress = true; defer { workspaceActionInProgress = false }
    await reload()
    let pending = state.commands.first { $0.command.kind == .workspace && ($0.receipt == nil || $0.receipt?.status == .accepted || $0.receipt?.status == .outcomeUnknown) }
    if let pending, pending.command.workspaceAction != action {
      errorMessage = "An earlier workspace change still needs acknowledgement. Review it in Settings → Pair to Mac → Pending changes before making another change."
      return false
    }
    errorMessage = nil
    do {
      let command = pending?.command ?? .init(deviceID: state.deviceID, kind: .workspace, workspaceAction: action)
      let result = try await engine.submit(command)
      await reload()
      guard result.status == .completed else {
        errorMessage = result.message ?? "The Mac has not confirmed this change. Check its acknowledgement before retrying."
        return false
      }
      if pending == nil, action.qualifiesForAnalytics { await analytics.record(.active) }
      await refresh()
      return true
    } catch { errorMessage = error.localizedDescription; await reload(); return false }
  }
  func canonicalNoteForAction(_ id: String) async throws -> CompanionNote {
    guard online, let engine, let store else { throw MobileConnectionError.offline }
    await flushLocalWrites()
    try await engine.synchronize()
    await reload()
    return try await store.canonicalNote(id: id)
  }
  func exportFile(_ request: CompanionWorkspaceRead) async throws -> URL {
    guard case .file(let file) = try await workspace(request) else { throw MobileConnectionError.invalidResponse }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompanionExport-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = URL(fileURLWithPath: file.name).lastPathComponent
    let url = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "Export" : name)
    try file.data.write(to: url, options: [.atomic, .completeFileProtection])
    return url
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
          .richText(.init(style: .bulletedList, text: "Your notes are saved on this device.")),
          .richText(.init(style: .bulletedList, text: "Reconnect to bring the plan back to your Mac.")),
        ]).encoded())
        try await store.apply(CompanionSnapshot(workspaceID: "fixture", cursor: 1, folders: [.init(id: "inbox", name: "Inbox")], notes: [note], conversations: [
          .init(id: "fixture-chat", title: "Launch plan", folderID: "inbox", providerID: "local:codex", runtimeKind: "codex", preview: "A focused plan for the next release.")]))
        try await store.cache(.init(conversationID: "fixture-chat", messages: [
          .init(id: "user", conversationID: "fixture-chat", runID: "11111111-1111-4111-8111-111111111111", role: "user", content: "Summarize the launch plan.", sequence: 0),
          .init(id: "assistant", conversationID: "fixture-chat", runID: "11111111-1111-4111-8111-111111111111", role: "assistant", content: "A focused plan for the next release.\n\n• Capture the idea in a note.\n• Review it together on the Mac.\n• Keep the next step small and clear.", status: "completed", sequence: 2)], activities: [.init(id: "activity", runID: "11111111-1111-4111-8111-111111111111", title: "Run finished", detail: "The plan is ready for review.", status: "completed", sequence: 1)], runs: [.init(id: "11111111-1111-4111-8111-111111111111", status: "completed")]))
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
      let scenario = ProcessInfo.processInfo.environment["WOVENMATTER_UI_SCENARIO"] ?? ""
      if scenario.hasPrefix("running-tools") {
        let runID = "11111111-1111-4111-8111-111111111111"
        let startedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-8))
        let currentStatus = scenario == "running-tools-settled" ? "completed" : "running"
        let activities = try [("fixture-read", "completed"), ("fixture-current", currentStatus)].enumerated().map { index, value in
          let activity = AgentRunActivity(id: value.0, kind: .tool, title: "Read file", status: value.1, toolName: "read_file",
            rawInputJSON: "{\"path\":\"plan.md\"}")
          let projection = String(decoding: try JSONEncoder().encode(activity), as: UTF8.self)
          return CompanionActivity(id: value.0, runID: runID, title: "Read file", status: value.1, projectionJSON: projection, sequence: Int64(index + 1))
        }
        try await store.cache(.init(conversationID: "fixture-chat", messages: [
          .init(id: "user", conversationID: "fixture-chat", runID: runID, role: "user", content: "Inspect the launch plan.", createdAt: startedAt, sequence: 0)
        ], activities: activities, activeRunID: runID, runs: [.init(id: runID, status: "running", startedAt: startedAt)]))
        if scenario == "running-tools-expanded" {
          let state = transcriptStates.state(for: "fixture-chat")
          state.setExpanded(ConversationTranscriptState.disclosureKey(runID: runID, itemID: "group:fixture-read"), true)
          state.setExpanded(ConversationTranscriptState.disclosureKey(runID: runID, itemID: "activity:fixture-current"), true)
        }
        online = true // Fixture presentation only; no transport or inference is configured.
        await reload()
      }
      if scenario == "permissions" {
        let descriptor = InferenceModel(id: "gpt-fixture", name: "GPT-6.1 Sol", provider: "openai", api: "openai-responses", baseUrl: "https://example.invalid", reasoning: true)
        executionRecords["fixture-chat"] = .init(id: "fixture-chat", title: "Launch plan", thinkingLevel: "high", connectionID: "fixture", modelJSON: try descriptor.descriptorJSON(), status: "ready", updatedAt: "")
      }
      selectedNoteID = notes.first?.id; selectedConversationID = "fixture-chat"
      if ProcessInfo.processInfo.environment["WOVENMATTER_UI_SCENARIO"] == "pairing" { pairingPresented = true }
      tab = Tab(rawValue: ProcessInfo.processInfo.environment["WOVENMATTER_UI_TAB"] ?? "Folders") ?? .folders
    } catch { errorMessage = error.localizedDescription }
  }
}
