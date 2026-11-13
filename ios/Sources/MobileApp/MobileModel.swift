import SwiftUI
import Observation
import LibraryClient
import WovenMatterShared
import PiDurableRuntime
import MobileInference

@MainActor @Observable final class MobileModel {
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
  var providers: [HarnessCapabilities] = []
  var knownAgentIDs: Set<String> = []
  var selectedConversationRoute: (conversationID: String, workspaceID: String)?
  var savedAgentCatalog: AgentCatalog?
  var pending: [PendingInteraction] = []
  var sessionCapabilities: [String: HarnessCapabilities] = [:]
  /// The open chat's settings as its workspace's stream last sent them (`session` items).
  var streamedSessionSettings: [String: SessionSettings] = [:]
  var historyPages: [String: LibraryTranscript] = [:]
  @ObservationIgnored let transcriptStates = MobileConversationStates()
  var loadingHistory = false
  var selectedFolderID: String?
  var selectedFolderWorkspaceID: String?
  var folderContentsUnfiled = false
  var folderContentsPresented = false
  var selectedNoteID: String?
  /// The open chat. Every stream follows it (`followSelectedConversation`);
  /// a chat no connected stream carries starts the foreground tick.
  var selectedConversationID: String? {
    didSet {
      guard selectedConversationID != oldValue else { return }
      if !workspaceStreams.isEmpty { Task { await self.followSelectedConversation() } }
      libraryStreamChanged()
    }
  }
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
  /// The open stream that announces the library host's changes (`library`
  /// items), by workspace and the server's member device ID. While it is
  /// set, the library has no foreground timer.
  @ObservationIgnored var libraryStream: (workspaceID: String, deviceID: String)?
  @ObservationIgnored var librarySyncPause: LibrarySyncPause = .none
  @ObservationIgnored var librarySyncWake: CheckedContinuation<Void, Never>?
  @ObservationIgnored var librarySyncTimeout: Task<Void, Never>?
  /// A refresh asked for while one runs: it runs once more afterwards.
  @ObservationIgnored private var refreshAgain = false
  var offlineProblems: [String: String] = [:]
  var saveStates: [String: String] = [:]
  var draftTitles: [String: String] = [:]
  var draftContents: [String: String] = [:]
  var credential: MobileCredential?
  var store: MobileStore?
  var engine: MobileSyncEngine?
  var transport: HTTPSLibraryTransport?
  /// This phone's member identity and the Mac and Linux hosts it can sync
  /// with. Nil until the phone pairs with its member key (or for an older Mac).
  var memberIdentity: MobileMemberIdentity?
  var libraryHosts: MobileLibraryHosts?
  var membership: MobileMembershipState?
  var membershipFile: URL?
  @ObservationIgnored var memberKeyStorage: MobileMemberKeyStorage = .keychain
  /// Test routing for in-process hosts; production uses URLSession.
  @ObservationIgnored var httpPerformer: (any MobileHTTPPerforming)?
  /// The endpoint each signed workspace client was made for.
  var memberClientEndpoints: [String: URL] = [:]
  /// Workspaces too old for member requests keep their bearer grant.
  var memberUnsupportedWorkspaceIDs: Set<String> = []
  /// Pairing confirmation and unpairing for a paired transport. Tests record
  /// these requests instead of contacting central.
  @ObservationIgnored var pairingRequests: (HTTPSLibraryTransport) -> any MobilePairingRequests = { $0 }
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
  var pendingChatCreation: LibraryCommand?
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
  var localPending: [PendingInteraction] = []
  var executionWorkspaces: [ExecutionWorkspace] = []
  /// One-off reads of workspaces that do not stream: when their client is
  /// made, and on the app's explicit refreshes. Never on a timer.
  var workspaceReadTasks: [String: Task<Void, Never>] = [:]
  var workspaceClients: [String: WorkspaceClient] = [:]
  /// Live streams to `stream.v1` workspaces, foreground only.
  @ObservationIgnored var workspaceStreams: [String: MobileWorkspaceStream] = [:]
  /// Streams that are connected and serve their `workspace` subscription.
  @ObservationIgnored var liveStreamIDs: Set<String> = []
  @ObservationIgnored var streamEndpoints: [String: URL] = [:]
  @ObservationIgnored var streamMembersRevision: String?
  @ObservationIgnored var streamReloadScheduled = false
  /// Background stops and foreground starts, in order.
  @ObservationIgnored var streamLifecycle: Task<Void, Never>?
  /// Test sockets for workspace streams; production signs a WebSocket upgrade.
  @ObservationIgnored var streamConnector: ((ExecutionWorkspace) -> StreamConnection.Connect?)?
  /// Reconnection timing for workspace streams; tests replace the backoff.
  @ObservationIgnored var streamConfiguration = StreamConnection.Configuration()
  var workspaceProviders: [String: [HarnessCapabilities]] = [:]
  var workspaceReachable: [String: Bool] = [:]
  var executionWorkspaceRefreshInProgress = false
  var remotePending: [String: [PendingInteraction]] = [:]
  var workspaceAuthorizationRetryAt: [String: Date] = [:]
  /// One in-flight credential issuance per workspace. Each issuance replaces
  /// the device's earlier token there, so concurrent requests share it.
  @ObservationIgnored var workspaceIssuances: [String: (generation: UUID, task: Task<DirectWorkspaceCredential, any Error>)] = [:]
  /// The latest inference binding per workspace; each binding waits for the
  /// one before it, so binders of one workspace never interleave.
  @ObservationIgnored var workspaceBindings: [String: Task<Void, any Error>] = [:]
  var workspaceProblems: [String: String] = [:]
  var inferenceProblem: String?
  var executionDirectory: URL?
  var executionRefreshTasks: [String: Task<Void, Never>] = [:]
  var executionCredentialStore: any InferenceCredentialUpdating = InferenceCredentialStore()
  /// Device-only storage for direct workspace credentials; tests inject memory.
  var workspaceCredentials = WorkspaceCredentialStorage.keychain
  var quickChatSearchResults: [String: Set<String>] = [:]
  /// Web search requests; tests inject a fixture transport.
  @ObservationIgnored var searchTransport: any InferenceHTTPTransport = InferenceURLSessionTransport()
  /// Timer reminder notifications; test models and UI fixtures record them in memory so
  /// nothing asks the system for notification permission.
  @ObservationIgnored var quickChatNotifications = QuickChatNotifications.shared
  var unconfirmedSendConversationID: String?
  /// Messages sent to a Mac or Linux workspace that its transcript does not
  /// show yet, by conversation ID (`new-chat` until a new chat is accepted).
  var pendingSends: [String: PendingSend] = [:]
  /// The library host that reported `providers`, and whether the next
  /// refresh must ask it again (launch, reconnect, New Chat, a new host).
  var centralProvidersHostID: String?
  var centralProvidersRefreshDue = true
  var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
  var backgroundFallbackToken: UUID?
  var calendarRevision = 0
  var deviceScheduleTask: Task<Void, Never>?
  var processingDeviceSchedule = false

  let fixture: Bool
  let isolatedTestHost: Bool

  private static var smokeIsolationRequested: Bool {
    #if DEBUG
    return DeviceRuntimeSmoke.enabled
    #else
    return false
    #endif
  }
  /// The UI-test scenario and tab. Release builds compile no fixture environment
  /// lookups at all, rather than relying on the optimizer to remove them.
  static var uiScenario: String? {
    #if DEBUG
    ProcessInfo.processInfo.environment["WOVENMATTER_UI_SCENARIO"]
    #else
    nil
    #endif
  }
  static var uiTab: String? {
    #if DEBUG
    ProcessInfo.processInfo.environment["WOVENMATTER_UI_TAB"]
    #else
    nil
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
    if isolatedTestHost || fixture { quickChatNotifications = QuickChatNotifications(center: RecordingQuickChatNotificationCenter()) }
    if isolatedTestHost {
      // App-hosted unit tests must never open the real library or Keychain.
      // Explicit injected models exercise networking against their fake transport.
      do { store = try MobileStore(file: FileManager.default.temporaryDirectory.appendingPathComponent("WovenMatterTestHost-" + UUID().uuidString).appendingPathComponent("library.json")) }
      catch { errorMessage = error.localizedDescription }
      return
    }
    do {
      let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      // Release builds carry no fixture plumbing; scripts/verify-ios-app.sh checks the binary.
      #if DEBUG
      let namespace = ProcessInfo.processInfo.environment["WOVENMATTER_UI_FIXTURE_NAMESPACE"] ?? "default"
      #else
      let namespace = "default"
      #endif
      let safeNamespace = namespace.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
      let filename = fixture ? "fixture-library-\(safeNamespace).json" : "mobile-library.json"
      let libraryRoot = root.appendingPathComponent("WovenMatter")
      store = try MobileStore(file: libraryRoot.appendingPathComponent(filename))
      membershipFile = libraryRoot.appendingPathComponent(fixture ? "fixture-membership-\(safeNamespace).json" : "membership.json")
      executionDirectory = libraryRoot.appendingPathComponent(fixture ? "fixture-execution-\(safeNamespace)" : "execution", isDirectory: true)
      #if DEBUG
      httpPerformer = DevelopmentTailnet(ProcessInfo.processInfo.environment["WOVENMATTER_DEV_TAILNET"])
      #endif
    } catch { errorMessage = "The local library could not open: " + error.localizedDescription }
  }
  init(store: MobileStore, transport: any LibraryTransport) {
    fixture = false; isolatedTestHost = false; automaticSynchronization = false; self.store = store
    quickChatNotifications = QuickChatNotifications(center: RecordingQuickChatNotificationCenter())
    executionWorkspaceID = "central"
    engine = MobileSyncEngine(store: store, transport: transport)
    online = true
  }
  func flushLocalWrites() async { await saveTask?.value; await chatDraftTask?.value }
  var folders: [LibraryFolder] { state.folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
  var notes: [LibraryNote] { state.notes.values.sorted { ($0.isPinned == true) != ($1.isPinned == true) ? $0.isPinned == true : $0.updatedAt > $1.updatedAt } }
  var conversations: [LibraryConversation] { state.conversations.values.sorted { ($0.isPinned == true) != ($1.isPinned == true) ? $0.isPinned == true : $0.updatedAt > $1.updatedAt } }
  var selectedNote: LibraryNote? { selectedNoteID.flatMap { state.notes[$0] } }
  var selectedConversation: LibraryConversation? { selectedConversationID.flatMap { state.conversations[$0] } }
  var transcript: LibraryTranscript? { selectedConversationID.flatMap { historyPages[$0] ?? state.transcripts[$0] } }
  /// The selected chat's message that its workspace has not shown with its turn yet.
  var pendingSend: PendingSend? {
    pendingSends[draftKey].flatMap { $0.isFinished(in: transcript) ? nil : $0 }
  }
  /// The transcript the chat shows: the owner's, plus a message just sent
  /// that the owner does not show yet. Earlier history pages show as stored.
  var displayedTranscript: LibraryTranscript? {
    guard let pending = pendingSend, selectedConversationID.map({ historyPages[$0] == nil }) ?? true else { return transcript }
    return pending.displayed(in: transcript, conversationID: draftKey)
  }
  /// Quiet progress under a message just sent, until its turn appears.
  var sendProgress: String? {
    guard let pending = pendingSend, !pending.hasStarted(in: transcript) else { return nil }
    return (pending.phase == .sending ? "Sending to " : "Starting on ") + executionName + "…"
  }
  var activeRunID: String? {
    if let id = selectedConversationID, let record = executionRecords[id] { return (record.status == "running" || record.status == "stopping") ? record.runID : nil }
    return selectedConversationID.flatMap { state.transcripts[$0]?.activeRunID } ?? selectedConversation?.activeRunID
  }
  var centralProvider: HarnessCapabilities? { selectedConversationID.flatMap { sessionCapabilities[$0] } ?? providers.first { $0.id == (selectedConversation?.providerID ?? providerID) } }
  var allPending: [PendingInteraction] { pending + localPending + remotePending.values.flatMap { $0 } }
  var currentPending: [PendingInteraction] { allPending.filter { $0.conversationID == selectedConversationID } }

  func run() async {
    guard !isolatedTestHost else { return }
    DictationSession.shared.saveHistory = { [weak self] record in
      guard let store = self?.store else { throw MobileStore.Failure.incompatibleStore }
      try await store.dictations.save(record)
    }
    DictationSession.shared.retrySavingHistory()
    if !booted {
      booted = true
      defer { initialized = true }
      await reload()
      if fixture {
        #if DEBUG
        await seedFixture()
        #endif
      } else {
        do { try await store?.recoverPairingTransition(); await reload(); credential = try MobileCredentialVault.load() }
        catch { errorMessage = error.localizedDescription; return }
        do {
          if let pending = credential, pending.confirmationPending == true {
            credential = nil
            try await acceptPairing(pending, allowingLibraryChange: true) { try MobileCredentialVault.save($0) }
            await completeMemberPairing(endpoint: pending.endpoint, hostDeviceID: pending.hostDeviceID)
          } else { try configureTransport() }
        } catch { pairingError = error.localizedDescription; credential = nil }
        do { try await store?.interruptExecutorJobs(); try await loadExecutionConfiguration() }
        catch { errorMessage = error.localizedDescription }
        #if DEBUG
        await DevelopmentTailnet.applyLaunchOptions(to: self)
        #endif
      }
    }
    if let store { await analytics.configure(store.analytics, transport: await analyticsTransport()) }
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
    let unfinished = pendingSends.filter { key, pending in pending.phase == .sending || !pending.isFinished(in: state.transcripts[key]) }
    if unfinished.count != pendingSends.count { pendingSends = unfinished }
    calendarRevision &+= 1
    await refreshSynchronizationStatus()
  }
  func configureTransport() throws {
    guard let credential, let store else { connectionLabel = "Saved on this device"; return }
    guard credential.deviceID == state.deviceID else { throw LibraryAPIError(code: "device_identity_changed", message: "Pair this local library with your Mac again. The saved credential belongs to a previous app installation; your local notes are safe.") }
    if try configureMemberTransport() { return }
    let client = try HTTPSLibraryTransport(credential: credential, metadata: deviceMetadata, performer: httpPerformer)
    transport = client; engine = MobileSyncEngine(store: store, transport: client)
  }
  func pair(url: URL) async {
    guard !isolatedTestHost, !fixture, let store, !pairingInProgress else { return }
    pairingInProgress = true; pairingError = nil
    defer { pairingInProgress = false }
    do {
      let payload = try PairingPayload.parseURL(url)
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
          await completeMemberPairing(endpoint: payload.endpoint, hostDeviceID: pending.hostDeviceID)
          pairingText = ""
          await analytics.configure(store.analytics, transport: await analyticsTransport())
          await refresh(); await refreshExecutionWorkspaces(force: true)
          return
        } catch MobileConnectionError.revoked {
          // Expired or explicitly revoked enrollment needs the fresh QR offer.
          try MobileCredentialVault.clear()
        }
      }
      let target = try await HTTPSLibraryTransport.previewPairing(payload, deviceID: current.deviceID,
        deviceName: UIDevice.current.name, metadata: deviceMetadata, performer: httpPerformer)
      if (current.workspaceID ?? current.detachedWorkspaceID) != target,
        !localRunTasks.isEmpty || processingDeviceSchedule {
        throw DeviceExecutionError.unavailable("Finish the running device agents before changing the central database.")
      }
      await flushLocalWrites()
      stopDeviceScheduler()
      defer { if connectionForeground { startDeviceScheduler() } }
      // The member key: the Mac adds this phone as a member, and every later
      // request to any Mac or Linux member is signed with it.
      let identity = try loadMemberIdentity()
      let paired = try await HTTPSLibraryTransport.pair(payload, deviceID: current.deviceID,
        deviceName: UIDevice.current.name, metadata: deviceMetadata, expectedWorkspaceID: target, requiresConfirmation: true,
        memberPublicKey: identity.publicKey, performer: httpPerformer)
      // Pairing again with another Mac of the same library moves nothing:
      // the next sync rebinds to it like to any other member host. The Mac
      // names its registry's libraries, because it adds this phone as a
      // member only once the pairing is confirmed.
      let previous = current.workspaceID ?? current.detachedWorkspaceID
      let keepLibrary = paired.hostDeviceID != nil && previous != nil && previous != target
        && (paired.libraryIDs ?? []).contains(previous ?? "")
      try await acceptPairing(paired, allowingLibraryChange: true, keepLibrary: keepLibrary) { try MobileCredentialVault.save($0) }
      await completeMemberPairing(endpoint: payload.endpoint, hostDeviceID: paired.hostDeviceID)
      // Kept for member sync, which this Mac refused after all: bind the
      // replica to it the way a first pairing does.
      if keepLibrary, membership?.memberRequestsAccepted == false { try await store.prepareForPairing(paired.workspaceID) }
      pairingText = ""
      // Analytics start with the new pairing, not at the next launch.
      await analytics.configure(store.analytics, transport: await analyticsTransport())
      await refresh()
      await refreshExecutionWorkspaces(force: true)
    } catch { pairingError = error.localizedDescription }
  }
  /// Library sync with the current host. A refresh asked for while one runs
  /// (a `library` item, an edit) runs once more when it finishes, so no
  /// announced change waits for a later trigger.
  func refresh() async {
    guard engine != nil else { return }
    guard !refreshInProgress else { refreshAgain = true; return }
    repeat {
      refreshAgain = false
      await refreshOnce()
    } while refreshAgain && engine != nil && !Task.isCancelled
    // The host may have changed: the library stream's timer follows it.
    libraryStreamChanged()
  }
  private func refreshOnce() async {
    guard let engine, !refreshInProgress else { return }
    refreshInProgress = true; connecting = true
    let generation = connectionGeneration
    defer { refreshInProgress = false; connecting = false }
    do {
      // Library sync: notes, calendar, dictation, history and artifacts. It
      // reads nothing live of a session; the open chat streams, so its
      // transcript is not read again for the offline cache.
      await engine.setStreamedTranscripts(Set(workspaceStreams.keys.filter { streamConnected($0) }
        .compactMap { streamedConversationID(for: $0) }))
      try await engine.synchronize()
      guard generation == connectionGeneration, !Task.isCancelled else { return }
      await adoptCurrentLibraryHost(engine)
      // The central list is the current host's: asked again after launch, a
      // reconnect, the app becoming active, a new host or when New Chat opens.
      let host = libraryHostDeviceID
      let connectionChanged = centralProvidersRefreshDue || providers.isEmpty || host != centralProvidersHostID
      let refreshedProviders = connectionChanged ? try await engine.providers() : providers
      // The host's stream pushes the central route's questions and approvals
      // and resolves lost replies when it connects. Without one they are read
      // once per connection here, and when a chat opens or after a command.
      let refreshedPending: [PendingInteraction]? = streamsCentral ? [] : connectionChanged ? try await engine.pending() : nil
      if connectionChanged, !streamsCentral { try await engine.recoverCommandReceipts() }
      let status = await engine.synchronizationStatus()
      guard generation == connectionGeneration, !Task.isCancelled else { return }
      providers = refreshedProviders
      if let refreshedPending, refreshedPending != pending { pending = refreshedPending }
      if connectionChanged { centralProvidersHostID = host; centralProvidersRefreshDue = false }
      synchronizationStatus = status
      online = true; connectionLabel = "Connected"
      centralRetryCount = 0
      centralRefreshAfter = Date().addingTimeInterval(15)
      if providerID.isEmpty { providerID = providers.first(where: { $0.available })?.id ?? "" }
      await reload(); rememberAgentCatalog()
    } catch {
      guard generation == connectionGeneration, !Task.isCancelled else { return }
      let status = await engine.synchronizationStatus()
      guard generation == connectionGeneration else { return }
      synchronizationStatus = status
      await adoptCurrentLibraryHost(engine)
      online = status.centralReachable == true
      centralProvidersRefreshDue = true
      connectionLabel = online ? "Connected" : "Disconnected"
      centralRetryCount += 1
      centralRefreshAfter = Date().addingTimeInterval(Self.connectionRetryDelay(centralRetryCount))
      await reload()
    }
  }
  func openFolder(_ id: String?, workspaceID: String? = nil, unfiled: Bool = false) {
    selectedFolderID = id
    selectedFolderWorkspaceID = (workspaceID ?? id.flatMap { state.folders[$0]?.execution?.workspaceID }).map(canonicalWorkspaceID)
    folderContentsUnfiled = unfiled; folderContentsPresented = true; tab = .folders
  }
  func closeFolder() { selectedFolderID = nil; selectedFolderWorkspaceID = nil; folderContentsUnfiled = false; folderContentsPresented = false }
  func newFolder(name: String) async {
    guard let store, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    do { let folder = try await store.createFolder(name: name); await analytics.record(.active); await reload(); openFolder(folder.id) }
    catch { errorMessage = error.localizedDescription }
  }
  func newNote() async {
    guard let store else { return }
    do {
      let scoped = tab == .folders && folderContentsPresented
      let note = try await store.createNote(folderID: scoped ? selectedFolderID : nil, title: "Untitled note", content: NoteDocument().encoded())
      await analytics.record(.active)
      selectedNoteID = note.id; tab = .note; await reload()
    } catch { errorMessage = error.localizedDescription }
  }
  func openNote(_ id: String) async {
    selectedNoteID = id; tab = .note
    if state.uncachedNoteIDs.contains(id), online, let store, let transport {
      do { try await store.cacheNote(transport.asset(id)); await reload() }
      catch { errorMessage = error.localizedDescription }
    }
  }
  func selectConversation(_ id: String, workspaceID: String? = nil) async {
    selectedConversationRoute = (id, workspaceID ?? preferredExecutionRoute(for: id))
    selectedConversationID = id; tab = .chat
    if isViewingRemoteQuickChat { await refreshRemoteQuickChatHistory() }
    else if selectedExecutionWorkspaceID == "local" { await openDeviceConversation(id) }
    else if selectedExecutionWorkspaceID == "central" {
      // The library host's stream follows it; without a stream it is read once.
      await followSelectedConversation()
      if !streamsCentral { await refreshCentralConversation(id) }
    }
    else { await refreshExecutionWorkspaces(force: true) }
  }
  /// "Load conversation": the stream already follows the chat; a chat nothing
  /// streams, or that has no transcript yet, is read once.
  func refreshConversation() async {
    let owner = selectedExecutionWorkspaceID
    if isViewingRemoteQuickChat { await refreshRemoteQuickChatHistory() }
    else if owner == "local", let id = selectedConversationID { await openDeviceConversation(id) }
    else if owner == "central" {
      await followSelectedConversation()
      if let id = selectedConversationID, !streamsCentral || state.transcripts[id] == nil { await refreshCentralConversation(id) }
    }
    else { await refreshDirectWorkspace(owner) }
  }
  /// One read of a central chat's live view, for a host that does not stream
  /// it: its transcript and capabilities, and the central questions and
  /// approvals. Only when the chat opens, on "Load conversation" and after a command.
  func refreshCentralConversation(_ conversationID: String?) async {
    guard online, let engine else { return }
    do {
      if let conversationID {
        try await engine.refreshTranscript(conversationID)
        if let capability = try? await transport?.capabilities(conversationID) { sessionCapabilities[conversationID] = capability }
      }
      if !streamsCentral { pending = try await engine.pending() }
      await reload()
    } catch { /* Saved history stays visible; the next explicit read retries. */ }
  }
  /// After a central command: the stream shows its effect. Without a stream
  /// the chat is read once. Library sync follows shortly, as after any change.
  func afterCentralCommand(_ conversationID: String?) async {
    await followSelectedConversation()
    if !streamsCentral { await refreshCentralConversation(conversationID ?? selectedConversationID) }
    requestSynchronization()
  }
  /// A chat its workspace's stream does not serve (the server ended its
  /// subscription): read once, never polled.
  func readConversationOnce(_ conversationID: String) async {
    let route = executionRoute(for: conversationID)
    if route == "central" { await refreshCentralConversation(conversationID); return }
    guard route != "local", let client = workspaceClients[route] else { return }
    do {
      _ = try await client.refreshTranscript(conversationID)
      if let capability = try? await client.capabilities(conversationID) { sessionCapabilities[conversationID] = capability }
      await reload()
    } catch { workspaceProblems[route] = error.localizedDescription }
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
  func newChat(referencing noteID: String? = nil, workspaceID: String? = nil) {
    if tab != .folders || !folderContentsPresented { selectedFolderID = nil; selectedFolderWorkspaceID = nil }
    if let workspaceID { selectedFolderWorkspaceID = workspaceID }
    newChatNoteID = noteID; chatSetupProblem = nil; chatChooserPresented = true
  }
  func saveNote(id: String, title: String, content: String, base: LibraryNote) {
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
  func compactSaveLabel(_ id: String) -> String {
    if let value = saveStates[id], value != "Saved on this device" {
      return value.hasPrefix("Saving") ? "Saving…" : "Save failed"
    }
    if state.conflicts[id] != nil { return "Sync conflict" }
    if state.workspaceID != nil && state.isDirty(id) { return "Sync pending" }
    return "Saved"
  }
  func saveLabel(_ id: String) -> String {
    if let value = saveStates[id], value != "Saved on this device" { return value }
    if state.conflicts[id] != nil { return "Saved on this device · conflict needs attention" }
    guard state.workspaceID != nil else { return "Saved on this device" }
    if state.isDirty(id) { return "Saved on this device · waiting to sync" }
    return "Saved · synced with Mac"
  }
  func linkedData(note: LibraryNote, tableID: String? = nil) async throws -> LinkedDataPreview {
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
    let pendingLaunch = target == nil ? MobileLaunchRecord.reusable(state.launches, workspaceID: nil, providerID: route, text: text, noteID: noteID) : nil
    sending = true
    defer { sending = false }
    await saveTask?.value
    await chatDraftTask?.value
    if runID != nil && provider?.canSteer != true { errorMessage = "This session does not currently support steering. Stop it or wait for completion."; return }
    if target == nil && (provider?.available != true || provider?.canStart != true) { errorMessage = "Choose an available agent route on your Mac."; return }
    let cleared = beginPendingSend(key: sourceKey, text: text, conversationID: target)
    var accepted = false
    defer { if !accepted { withdrawPendingSend(sourceKey, restoring: draftContext, over: cleared) } }
    do {
      let receipt: LibraryCommandReceipt
      if target == nil {
        try await requireWorkspaceConnection("central")
        let conversationID = pendingLaunch?.create.conversationID ?? UUID().uuidString.lowercased()
        let launch: MobileLaunchRecord
        if let pendingLaunch { launch = pendingLaunch } else {
          launch = .init(create: .init(deviceID: deviceID, kind: .createSession, conversationID: conversationID, providerID: route, folderID: folder),
            initialSend: .init(deviceID: deviceID, kind: .send, conversationID: conversationID, text: text, noteID: noteID))
        }
        let result = try await engine.startConversation(launch)
        guard result.accepted, let accepted = result.sendReceipt else {
          if result.createReceipt?.status == .completed, result.sendReceipt?.status == .rejected, selectedConversationID == target {
            updateChatDraft(key: conversationID, draft: .init(text: text, noteID: noteID))
            selectedConversationID = conversationID
          }
          await reload(); errorMessage = result.sendReceipt?.message ?? result.createReceipt?.message ?? "The Mac hasn’t confirmed this request. Try again here when it’s connected."; return
        }
        receipt = accepted
        if selectedConversationID == target { selectedConversationID = receipt.conversationID ?? conversationID }
      } else {
        let unresolved = state.commands.first { $0.command.conversationID == target && ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) && ($0.command.kind == .send || $0.command.kind == .steer) }
        let command: LibraryCommand
        if let unresolved {
          guard unresolved.command.text == text, unresolved.command.noteID == noteID else {
            // Later input must not overtake it; offer to resend the saved original instead.
            unconfirmedSendConversationID = target
            errorMessage = "The previous message hasn’t been confirmed. Retry it before sending different input."; return
          }
          command = unresolved.command
        } else {
          command = .init(deviceID: deviceID, kind: runID == nil ? .send : .steer, conversationID: target, runID: runID, text: text, noteID: noteID)
        }
        receipt = try await engine.submit(command)
      }
      guard receipt.status != .rejected, receipt.status != .outcomeUnknown else { errorMessage = receipt.message ?? "The Mac did not accept this command."; await reload(); return }
      let conversationID = receipt.conversationID ?? target ?? selectedConversationID ?? sourceKey
      acceptPendingSend(from: sourceKey, to: conversationID); accepted = true
      if draftBuffer[sourceKey] == cleared && providerID == route { updateChatDraft(key: sourceKey, draft: cleared) }
      await afterCentralCommand(conversationID)
    } catch { errorMessage = workspaceActionMessage(error); await reload() }
  }
  /// Resends the saved unconfirmed message with its original command ID. The
  /// owner deduplicates by that ID, so a message that did arrive is not repeated.
  func retryUnconfirmedSend() async {
    guard let id = unconfirmedSendConversationID, !sending else { return }
    sending = true; defer { sending = false }
    let route = executionRoute(for: id)
    do {
      var receipt: LibraryCommandReceipt?
      let unresolved: (MobileCommandRecord) -> Bool = { $0.command.conversationID == id && ($0.receipt == nil || $0.receipt?.status == .outcomeUnknown) && ($0.command.kind == .send || $0.command.kind == .steer) }
      if route == "central" {
        guard let engine else { throw MobileConnectionError.offline }
        if let pending = state.commands.first(where: unresolved) { receipt = try await engine.submit(pending.command) }
      } else {
        guard let client = workspaceClients[route], let store else { throw DeviceExecutionError.unavailable("This execution workspace is unavailable.") }
        if let pending = await store.journal.commandRecords(workspaceID: route).first(where: unresolved) { receipt = try await client.submit(pending.command) }
      }
      if let receipt, receipt.status == .outcomeUnknown {
        errorMessage = receipt.message ?? "The previous message still hasn’t been confirmed. Try again when the device is connected."
      } else {
        unconfirmedSendConversationID = nil; errorMessage = receipt?.status == .rejected ? receipt?.message ?? "The previous message was not accepted." : nil
      }
      if route == "central" { await afterCentralCommand(id) } else { await refreshDirectWorkspace(route) }
    } catch { errorMessage = workspaceActionMessage(error) }
  }
  /// New chats whose first message has no confirmed outcome. Each keeps its
  /// original command IDs and text until its owner confirms or rejects it.
  var unconfirmedLaunches: [MobileLaunchRecord] { state.launches.filter { !$0.accepted && !$0.terminalFailure } }
  /// Resends a saved launch with its original IDs. An owner that already ran it
  /// answers from its receipt, so the first message is never sent twice.
  func retryUnconfirmedLaunch(_ id: String) async {
    guard !sending, let launch = unconfirmedLaunches.first(where: { $0.id == id }) else { return }
    sending = true; defer { sending = false }
    do {
      let result: MobileLaunchRecord
      if let workspaceID = launch.create.workspaceID {
        guard let client = workspaceClients[workspaceID] else { throw DeviceExecutionError.unavailable("This execution workspace is unavailable.") }
        result = try await client.startConversation(launch)
      } else {
        guard online, let engine else { throw MobileConnectionError.offline }
        result = try await engine.startConversation(launch)
      }
      await reload()
      if result.accepted { errorMessage = nil; selectedConversationID = result.create.conversationID }
      else { errorMessage = result.sendReceipt?.message ?? result.createReceipt?.message ?? "This new chat still hasn’t been confirmed. It stays saved; try again when connected." }
      if let workspaceID = launch.create.workspaceID { await refreshDirectWorkspace(workspaceID) }
      else { await afterCentralCommand(result.create.conversationID) }
    } catch { errorMessage = workspaceActionMessage(error); await reload() }
  }
  /// Shows a saved launch's first message in the new-chat composer. The launch
  /// itself stays saved; sending the same message to the same agent reuses it.
  func restoreUnconfirmedLaunch(_ id: String) {
    guard let launch = unconfirmedLaunches.first(where: { $0.id == id }) else { return }
    selectedConversationID = nil
    updateChatDraft(key: draftKey, draft: .init(text: launch.initialSend.text ?? "", noteID: launch.initialSend.noteID, providerID: launch.create.providerID))
  }
  func stop() async {
    if selectedExecutionWorkspaceID == "local" { await stopOnDevice(); return }
    if selectedExecutionWorkspaceID != "central" { await stopExecutionWorkspace(); return }
    guard let conversationID = selectedConversationID, let runID = activeRunID, online, activeProvider?.canStop == true else { return }
    await submit(.init(deviceID: state.deviceID, kind: .stop, conversationID: conversationID, runID: runID))
  }
  func respond(_ interaction: PendingInteraction, response: InteractionResponse) async {
    if let approval = localApprovals.removeValue(forKey: interaction.id) {
      localPending.removeAll { $0.id == interaction.id }
      if !response.answers.isEmpty {
        localQuestionAnswers[interaction.id] = response.answers.values.flatMap { $0 }.joined(separator: "\n")
      }
      approval.continuation.resume(returning: response.cancelled ? .withdrawn
        : response.optionID == "allow" || !response.answers.isEmpty ? .allowed : .declined)
      return
    }
    if executionRoute(for: interaction.conversationID) != "central" { await respondInExecutionWorkspace(interaction, response: response); return }
    await submit(.init(deviceID: state.deviceID, kind: .respond, conversationID: interaction.conversationID,
      runID: interaction.runID, interactionID: interaction.id, response: response))
  }
  func workspace(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult {
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
  func perform(_ action: LibraryWorkspaceAction) async -> Bool {
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
          let command = LibraryCommand(deviceID: state.deviceID, kind: .workspace, conversationID: id, workspaceAction: action)
          let result = try await client.submit(command)
          guard result.status == .completed else { errorMessage = result.message ?? "The workspace has not confirmed this change."; return false }
          if action.qualifiesForAnalytics { await analytics.record(.active) }
          await refreshDirectWorkspace(owner); return true
        } catch { errorMessage = error.localizedDescription; return false }
      }
    }
    guard online, let engine else { errorMessage = MobileConnectionError.offline.localizedDescription; return false }
    guard !workspaceActionInProgress else { return false }
    workspaceActionInProgress = true; defer { workspaceActionInProgress = false }
    await reload()
    // An unconfirmed change orders only later changes to the same item. Repeating
    // it resends its original command; other items proceed independently.
    let pending = state.commands.first { $0.command.kind == .workspace && ($0.receipt == nil || $0.receipt?.status == .accepted || $0.receipt?.status == .outcomeUnknown)
      && $0.command.workspaceAction?.confirmationScope == action.confirmationScope }
    if let pending, pending.command.workspaceAction != action {
      errorMessage = "The previous change to this item hasn’t been confirmed yet. Repeat that change to retry it, or try again shortly."
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
      await afterCentralCommand(conversationID)
      return true
    } catch { errorMessage = error.localizedDescription; await reload(); return false }
  }
  func canEditNoteDetails(_ id: String) -> Bool {
    store != nil && state.notes[id]?.contentIncluded == true && !state.uncachedNoteIDs.contains(id) && state.conflicts[id] == nil
  }
  /// Rename and move use the same durable local edits as the note editor. They
  /// must work before a new phone note has ever reached the central library.
  func editNoteDetails(_ id: String, action: String, title: String, folderID: String?) async -> Bool {
    guard ["rename", "move"].contains(action), let store else { return false }
    await flushLocalWrites()
    await reload()
    guard canEditNoteDetails(id), let note = state.notes[id] else {
      errorMessage = "Download this note and resolve any saved conflict before changing its details."
      return false
    }
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard action != "rename" || !name.isEmpty else { errorMessage = "Enter a note title."; return false }
    guard action != "move" || folderID == nil || state.folders[folderID!] != nil else {
      errorMessage = "This folder is no longer available."; return false
    }
    do {
      try await store.editNote(id: id, title: action == "rename" ? name : note.title, content: note.content,
        folderID: action == "move" ? folderID : note.folderID, base: note)
      await reload(); return true
    } catch { errorMessage = error.localizedDescription; return false }
  }
  /// Only a phone that has never been bound to a library deletes notes on its
  /// own: every note there was created on it and never sent anywhere. Once a
  /// phone has been paired, a note may exist in a library even at revision 0
  /// (a create that was sent but not answered, or a note re-created for a new
  /// library host), so deleting waits until the phone is paired again and the
  /// note goes to the library's Trash.
  func canDeleteNoteLocally(_ id: String) -> Bool {
    isStandalone && state.detachedWorkspaceID == nil && state.notes[id] != nil && state.notes[id]?.revision == 0
  }
  /// Deletes a note that lives only on this device, with the same durable
  /// store path an editor uses. Pairing later never sees it.
  func deleteLocalNote(_ id: String) async -> Bool {
    guard canDeleteNoteLocally(id), let store else { return false }
    await flushLocalWrites()
    await reload()
    guard let note = state.notes[id] else { return true }
    do {
      try await store.deleteWorkspaceNote(id: id, base: note)
      if selectedNoteID == id { selectedNoteID = nil }
      await analytics.record(.active)
      await reload(); return true
    } catch { errorMessage = error.localizedDescription; return false }
  }
  func canonicalNoteForAction(_ id: String) async throws -> LibraryNote {
    guard online, let engine, let store else { throw MobileConnectionError.offline }
    await flushLocalWrites()
    try await engine.synchronize()
    await reload()
    return try await store.canonicalNote(id: id)
  }
  func exportFile(_ request: LibraryWorkspaceRead) async throws -> URL {
    guard case .file(let file) = try await workspace(request) else { throw MobileConnectionError.invalidResponse }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WovenMatterExport-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = URL(fileURLWithPath: file.name).lastPathComponent
    let url = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "Export" : name)
    try file.data.write(to: url, options: [.atomic, .completeFileProtection])
    return url
  }
  private func submit(_ command: LibraryCommand) async {
    guard online, let engine else { errorMessage = MobileConnectionError.offline.localizedDescription; return }
    do {
      let result = try await engine.submit(command)
      if result.status == .rejected || result.status == .outcomeUnknown { errorMessage = result.message ?? "This request was not accepted." }
      await reload(); await afterCentralCommand(command.conversationID)
    } catch { errorMessage = error.localizedDescription; await reload() }
  }

  #if DEBUG
  /// UI-test seed data; compiled only into Debug builds, like the fixture environment.
  private func seedFixture() async {
    guard let store else { return }
    // A fresh install that was never paired: nothing seeded, no library host.
    if Self.uiScenario?.hasPrefix("standalone") == true {
      if Self.uiScenario == "standalone-timer" {
        // The timer Quick Chat's tool creates, through the same local tool path.
        let at = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
        let response = await store.executeLocalTool(.init(arguments: ["timers", "create", "--text", "Stretch", "--at", at],
          requestID: UUID().uuidString.lowercased()), context: .init(sessionID: "standalone-quick-chat", workspaceID: state.deviceID, enabled: [.timers]))
        if response.success { _ = try? await store.reconcileTimerReminders(sessionIDs: ["standalone-quick-chat"], now: Date()) }
        calendarRevision &+= 1
      }
      tab = Tab(rawValue: Self.uiTab ?? "Home") ?? .home; return
    }
    do {
      if state.notes.isEmpty {
        let note = LibraryNote(id: "11111111-1111-4111-8111-111111111111", folderID: "inbox", title: "Launch Plan", content: try NoteDocument(blocks: [
          .richText(.init(text: "Capture ideas wherever you are.")),
          .richText(.init(style: .bulletedList, text: "Your notes are saved on this device.")),
          .richText(.init(style: .bulletedList, text: "Reconnect to bring the plan back to your Mac.")),
        ]).encoded())
        try await store.apply(LibrarySnapshot(workspaceID: "fixture", cursor: 1, folders: [.init(id: "inbox", name: "Inbox")], notes: [note], conversations: [
          .init(id: "fixture-chat", title: "Launch plan", folderID: "inbox", providerID: "local:codex", runtimeKind: "codex", preview: "A focused plan for the next release.")]))
        try await store.cache(.init(conversationID: "fixture-chat", messages: [
          .init(id: "user", conversationID: "fixture-chat", runID: "11111111-1111-4111-8111-111111111111", role: "user", content: "Summarize the launch plan.", sequence: 0),
          .init(id: "assistant", conversationID: "fixture-chat", runID: "11111111-1111-4111-8111-111111111111", role: "assistant", content: "A focused plan for the next release.\n\n• Capture the idea in a note.\n• Review it together on the Mac.\n• Keep the next step small and clear.", status: "completed", sequence: 2)], activities: [.init(id: "activity", runID: "11111111-1111-4111-8111-111111111111", title: "Run finished", detail: "The plan is ready for review.", status: "completed", sequence: 1)], runs: [.init(id: "11111111-1111-4111-8111-111111111111", status: "completed")]))
      }
      await reload()
      if Self.uiScenario == "conflict", state.conflicts.isEmpty,
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
      let scenario = Self.uiScenario ?? ""
      if scenario.hasPrefix("running-tools") {
        let runID = "11111111-1111-4111-8111-111111111111"
        let startedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-8))
        let currentStatus = scenario == "running-tools-settled" ? "completed" : "running"
        let activities = try [("fixture-read", "completed"), ("fixture-current", currentStatus)].enumerated().map { index, value in
          let activity = AgentRunActivity(id: value.0, kind: .tool, title: "Read file", status: value.1, toolName: "read_file",
            rawInputJSON: "{\"path\":\"plan.md\"}")
          let projection = String(decoding: try JSONEncoder().encode(activity), as: UTF8.self)
          return LibraryActivity(id: value.0, runID: runID, title: "Read file", status: value.1, projectionJSON: projection, sequence: Int64(index + 1))
        }
        let transcript = LibraryTranscript(conversationID: "fixture-chat", messages: [
          .init(id: "user", conversationID: "fixture-chat", runID: runID, role: "user", content: "Inspect the launch plan.", createdAt: startedAt, sequence: 0)
        ], activities: activities, activeRunID: runID, runs: [.init(id: runID, status: "running", startedAt: startedAt)])
        try await store.journal.append(workspaceID: "fixture-execution", transcript: transcript)
        try await store.cache(transcript)
        if scenario == "running-tools-expanded" {
          let state = transcriptStates.state(for: "fixture-chat")
          state.setExpanded(ConversationTranscriptState.disclosureKey(runID: runID, itemID: "group:fixture-read"), true)
          state.setExpanded(ConversationTranscriptState.disclosureKey(runID: runID, itemID: "activity:fixture-current"), true)
        }
        online = true // Fixture presentation only; no transport or inference is configured.
        await reload()
      }
      if scenario == "message-attachments" {
        // A streamed remote message with the files its workspace received.
        let runID = "11111111-1111-4111-8111-111111111111"
        try await store.cache(.init(conversationID: "fixture-chat", messages: [
          .init(id: "user", conversationID: "fixture-chat", runID: runID, role: "user", content: "Review these for the launch.", sequence: 0, attachments: [
            .init(id: "fixture-sha-1", name: "launch-checklist.md", mimeType: "text/markdown", byteCount: 2_048),
            .init(id: "fixture-sha-2", name: "hero.png", mimeType: "image/png", byteCount: 348_160)]),
          .init(id: "assistant", conversationID: "fixture-chat", runID: runID, role: "assistant", content: "Both files are ready for review.", status: "completed", sequence: 1)],
          runs: [.init(id: runID, status: "completed")]), preservingOlderPages: false)
        await reload()
      }
      if scenario == "permissions" || scenario == "tools-menu" {
        let descriptor = InferenceModel(id: "gpt-fixture", name: "GPT-6.1 Sol", provider: "openai", api: "openai-responses", baseUrl: "https://example.invalid", reasoning: true)
        executionRecords["fixture-chat"] = .init(id: "fixture-chat", title: "Launch plan", thinkingLevel: "high", connectionID: "fixture", modelJSON: try descriptor.descriptorJSON(), status: "ready", updatedAt: "")
      }
      var scenarioNoteID: String?
      if scenario == "table-note" {
        // A note whose only block is a read-only table; relaunches reuse it.
        if let existing = state.notes.values.first(where: { $0.title == "Table only" }) { scenarioNoteID = existing.id }
        else {
          let table = NoteTableBlock(id: "fixture-table", columns: [.init(width: 120), .init(width: 120)],
            rows: [.init(cells: [.init(text: "Item"), .init(text: "Owner")]), .init(cells: [.init(text: "Launch"), .init(text: "Mac")])], headerRowCount: 1)
          scenarioNoteID = try await store.createNote(folderID: nil, title: "Table only", content: NoteDocument(blocks: [.table(table)]).encoded()).id
        }
        await reload()
      }
      if scenario == "offline-device" {
        let workspace = ExecutionWorkspace(id: "11111111-2222-4333-8444-555555555555", libraryID: "fixture", ownerDeviceID: "fixture-host", kind: .linux, name: "Offline Linux")
        executionWorkspaces = [workspace]
        workspaceProviders[workspace.id] = [.init(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)]
        workspaceReachable[workspace.id] = false
      }
      if scenario == "workspace-organization" || scenario == "remote-folders-empty" {
        let mac = "aaaaaaaa-1111-4111-8111-111111111111", linux = "bbbbbbbb-2222-4222-8222-222222222222", ipad = "cccccccc-3333-4333-8333-333333333333"
        executionWorkspaces = [
          .init(id: mac, libraryID: "fixture", ownerDeviceID: mac, kind: .mac, name: "Studio Mac", capabilities: ["history.central.v1"]),
          .init(id: linux, libraryID: "fixture", ownerDeviceID: mac, kind: .linux, name: "Linux workspace"),
          .init(id: ipad, libraryID: "fixture", ownerDeviceID: ipad, kind: .ios, name: "Travel iPad", capabilities: ["quick-chat", "notes"])
        ]
        providers = [.init(id: "pi", runtimeKind: "pi", displayName: "Pi Durable", available: true)]
        workspaceProviders[mac] = providers; workspaceProviders[linux] = providers
        workspaceReachable[mac] = true; workspaceReachable[linux] = true
        let localFolder = LibraryFolder(id: "dddddddd-4444-4444-8444-444444444444", name: "Phone ideas", execution: .init(workspaceID: "device:" + state.deviceID, rootPath: "/fixture/phone"))
        let macFolder = LibraryFolder(id: "eeeeeeee-5555-4555-8555-555555555555", name: "Mac projects", execution: .init(workspaceID: "device:" + mac, rootPath: "/fixture/mac"))
        let ipadFolder = LibraryFolder(id: "ffffffff-6666-4666-8666-666666666666", name: "Travel notes", execution: .init(workspaceID: "device:" + ipad, rootPath: "/fixture/ipad"))
        let document = try NoteDocument().encoded()
        let localNote = LibraryNote(id: "organization-local-note", title: "Unfiled phone idea", content: document)
        let ipadNote = LibraryNote(id: "organization-ipad-note", folderID: ipadFolder.id, title: "Packing list", content: document)
        let chat = LibraryConversation(id: "organization-ipad-chat", title: "Weekend plans", providerID: "pi-durable-device", runtimeKind: "pi", workspaceID: ipad)
        let fixtureFolders = [localFolder, macFolder, ipadFolder]
        let fixtureNotes = [localNote, ipadNote]
        // Fixture launches can reuse a namespace to verify persistence. Replace
        // the seeded rows instead of handing duplicate IDs to the snapshot.
        try await store.apply(.init(workspaceID: "fixture", cursor: 2,
          folders: folders.filter { row in !fixtureFolders.contains { $0.id == row.id } } + fixtureFolders,
          notes: notes.filter { row in !fixtureNotes.contains { $0.id == row.id } } + fixtureNotes,
          conversations: conversations.filter { $0.id != chat.id } + [chat]))
        try await store.cache(.init(conversationID: chat.id, messages: [
          .init(id: "organization-message", conversationID: chat.id, role: "assistant", content: "Your weekend plan, saved from the iPad.", sequence: 0)
        ]))
        await reload()
      }
      if scenario == "unreachable-workspaces" {
        // A saved Mac and Linux workspace that are not reachable, beside one
        // reachable Linux workspace whose Mac reports some agents not ready.
        let mac = "aaaaaaaa-7777-4777-8777-777777777777", stale = "bbbbbbbb-8888-4888-8888-888888888888", linux = "cccccccc-9999-4999-8999-999999999999"
        let copied = "dddddddd-0000-4000-8000-000000000000"
        executionWorkspaces = [
          .init(id: mac, libraryID: "fixture", ownerDeviceID: mac, kind: .mac, name: "Office Mac", capabilities: ["history.central.v1"]),
          .init(id: stale, libraryID: "fixture", ownerDeviceID: mac, kind: .linux, name: "Old Linux box"),
          .init(id: linux, libraryID: "fixture", ownerDeviceID: linux, kind: .linux, name: "Build server"),
          // A library copied from another Mac keeps that Mac's row as history only.
          .init(id: copied, libraryID: "fixture", ownerDeviceID: copied, kind: .mac, name: "Copied MacBook Air", capabilities: ["history.central.v1"], retainedHistory: true)
        ]
        func agent(_ id: String, _ name: String, ready: Bool) -> HarnessCapabilities { .init(id: id, runtimeKind: id, displayName: name, available: ready, canStart: ready) }
        let cached = [agent("default_agent", "Pi Durable", ready: true), agent("codex", "Codex", ready: false), agent("claude_code", "Claude Code", ready: false),
          agent("grok_build", "Grok Build", ready: true), agent("opencode", "OpenCode", ready: false)]
        workspaceProviders[mac] = cached; workspaceProviders[stale] = cached; workspaceProviders[copied] = cached
        workspaceProviders[linux] = [agent("default_agent", "Pi Durable", ready: true), agent("codex", "Codex", ready: false)]
        knownAgentIDs = Set([mac, stale, linux, copied].flatMap { id in cached.map { id + ":" + $0.id } })
        workspaceReachable[mac] = false; workspaceReachable[linux] = true; workspaceReachable[copied] = true
        let fixtureFolders = [
          LibraryFolder(id: "dddddddd-7777-4777-8777-777777777777", name: "Mac projects", execution: .init(workspaceID: "device:" + mac, rootPath: "/fixture/mac")),
          LibraryFolder(id: "eeeeeeee-8888-4888-8888-888888888888", name: "Retired machine", execution: .init(workspaceID: "device:ffffffff-0000-4000-8000-000000000000", rootPath: "/fixture/old")),
          LibraryFolder(id: "ffffffff-9999-4999-8999-999999999999", name: "Releases", execution: .init(workspaceID: "remote:" + linux, rootPath: "/srv/releases"))
        ]
        try await store.apply(.init(workspaceID: "fixture", cursor: 2,
          folders: folders.filter { row in !fixtureFolders.contains { $0.id == row.id } } + fixtureFolders, notes: notes, conversations: conversations))
        await reload()
      }
      if scenario.hasPrefix("member-macs") { try await seedMemberMacsFixture(store, send: scenario == "member-macs-send") }
      selectedNoteID = scenarioNoteID ?? notes.first?.id
      selectedConversationID = scenario == "member-macs-send" ? Self.memberMacsFixtureChat : "fixture-chat"
      if Self.uiScenario == "pairing" { pairingPresented = true }
      tab = Tab(rawValue: Self.uiTab ?? "Folders") ?? .folders
      if scenario == "member-macs-chooser" { newChat() }
    } catch { errorMessage = error.localizedDescription }
  }
  #endif
}

extension LibraryWorkspaceAction {
  /// The item whose changes must be confirmed in order.
  var confirmationScope: String {
    switch self {
    case .conversation(let id, _, _, _), .goal(let id, _), .configureSession(let id, _, _, _), .sessionTools(let id, _, _): "conversation:" + id
    case .note(let id, _, _, _, _): "note:" + id
    case .saveCalendar(let id, _, _), .deleteCalendar(let id, _, _): "calendar:" + id
    case .retryLibrary(let id): "library:" + id
    }
  }
}
