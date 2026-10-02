import Foundation
import Observation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

enum ExecutorControl: Codable, Sendable {
    case setup(ExecutorConfiguration, prepareHost: Bool = false), refresh, dashboard
    case selection(session: String, profiles: Set<String>)
    case enabled(session: String, enabled: Bool)
}

enum BackendToolsMutation: Codable, Sendable {
    case executor(ExecutorControl)
    case saveSettings(WorkspaceToolSettings, base: WorkspaceToolSettings? = nil)
    case saveTimer(WorkspaceSessionTimer)
    case setEnabled(group: WorkspaceToolGroup, enabled: Bool, sessionID: String, confirmedPausingTimers: Bool)
    case endCoordination(sessionID: String)
    case notifications(sessionID: String, enabled: Bool)
    case pauseTimer(id: String, paused: Bool)
    case removeTimer(id: String)
}

@MainActor @Observable
final class WorkspaceAgentToolsModel {
    typealias SessionHandler = @MainActor (String, WovenMatterToolCommand, WovenMatterToolRequest) async throws -> WovenMatterToolResponse
    typealias NoteHandler = @MainActor (String, NoteEditingRequest, String) async throws -> NoteEditingResponse
    typealias NoteRestoreHandler = @MainActor (String, String, String, String, String) async throws -> NoteEditingResponse
    typealias UsageHandler = @MainActor (WovenMatterToolCommand) async throws -> WovenMatterToolResponse
    typealias CalendarTaskHandler = @MainActor (String, WovenMatterToolCommand, WorkspaceCalendarTask?) async throws -> WorkspaceCalendarTask
    var executorControl: (@MainActor (ExecutorControl) async throws -> URL?)?
    private let executorHandler: SessionHandler?
    var executorDashboardURL: URL?
    var executorBusy = false
    func controlExecutor(_ control: ExecutorControl) async throws {
        guard let executorControl else { throw WorkspaceToolError.invalid("Executor manager is unavailable.") }
        executorBusy = true
        defer { executorBusy = false }
        executorDashboardURL = try await executorControl(control)
        try await reload()
    }
    var backendMutation: (@MainActor (BackendToolsMutation) async throws -> Void)?
    private let passiveProjection: Bool
    private var pendingSettingsWrites = 0
    private var settingsEditGeneration = UUID()
    private var committedSettings: WorkspaceToolSettings
    private var mutationTask: Task<Void, Never>?
    let calendarTaskHandler: CalendarTaskHandler?
    let database: WorkspaceDatabase
    private(set) var settings: WorkspaceToolSettings
    private(set) var sessionPolicies: [String: WorkspaceSessionTools] = [:]
    private(set) var relationships: [String: WorkspaceSessionRelationship] = [:]
    private(set) var timers: [WorkspaceSessionTimer] = []
    private(set) var receipts: [String: [WorkspaceSessionDelivery]] = [:]
    private var reloadGeneration = UUID()
    private var observedSessions: [UUID: String] = [:]
    private(set) var hasOlderReceipts: Set<String> = []
    var error: String?
    private var services: [String: WovenMatterToolService] = [:]
    private var remoteBridges: [String: WovenMatterRemoteToolBridge] = [:]
    private var pendingBridges: [String: Task<WovenMatterRemoteToolBridge, any Error>] = [:]
    private let ownerID = UUID()
    private var stopped = false
    private var receiptPageRequests: [String: UUID] = [:]
    private let endpointDirectory: URL
    private let sessionHandler: SessionHandler
    private let noteHandler: NoteHandler
    private let noteRestoreHandler: NoteRestoreHandler
    private let usageHandler: UsageHandler
    private let onMutation: @MainActor () async -> Void

    init(database: WorkspaceDatabase, sessionHandler: @escaping SessionHandler,
         noteHandler: @escaping NoteHandler, noteRestoreHandler: @escaping NoteRestoreHandler, usageHandler: @escaping UsageHandler,
         calendarTaskHandler: CalendarTaskHandler? = nil, executorHandler: SessionHandler? = nil, executorControl: (@MainActor (ExecutorControl) async throws -> URL?)? = nil, passiveProjection: Bool = false, onMutation: @escaping @MainActor () async -> Void) async throws {
        self.executorHandler = executorHandler
        self.executorControl = executorControl
        self.passiveProjection = passiveProjection
        self.calendarTaskHandler = calendarTaskHandler
        self.database = database
        let settings = try await database.toolSettings()
        self.settings = settings
        self.committedSettings = settings
        self.sessionHandler = sessionHandler
        self.noteHandler = noteHandler
        self.noteRestoreHandler = noteRestoreHandler
        self.usageHandler = usageHandler
        self.onMutation = onMutation
        endpointDirectory = URL(fileURLWithPath: "/private/tmp/wmtools-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        if !passiveProjection {
            try FileManager.default.createDirectory(at: endpointDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try await reload()
    }

    convenience init(projection database: WorkspaceDatabase, executorControl: (@MainActor (ExecutorControl) async throws -> URL?)? = nil,
                     send: @escaping @MainActor (BackendToolsMutation) async throws -> Void) async throws {
        try await self.init(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, passiveProjection: true, onMutation: {})
        backendMutation = send
        self.executorControl = executorControl
    }

    private func enqueue(_ mutation: BackendToolsMutation) {
        guard let backendMutation else { return }
        let previous = mutationTask
        mutationTask = Task {
            await previous?.value
            do {
                try await backendMutation(mutation)
                try await reload()
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    func setEnabledFromUI(_ group: WorkspaceToolGroup, enabled: Bool, sessionID: String, confirmedPausingTimers: Bool = false) async throws {
        if let backendMutation {
            try await backendMutation(.setEnabled(group: group, enabled: enabled,
                sessionID: sessionID, confirmedPausingTimers: confirmedPausingTimers))
            try await reload()
        } else { try await setEnabled(group, enabled: enabled, sessionID: sessionID, confirmedPausingTimers: confirmedPausingTimers) }
    }

    func reloadInBackground(policyIDs: Set<String> = []) async throws {
        try await reload(policyIDs: policyIDs)
    }

    func reload(policyIDs: Set<String> = []) async throws {
        guard !stopped else { return }
        let generation = UUID()
        reloadGeneration = generation
        let mayPublishSettings = pendingSettingsWrites == 0
        let observed = Set(observedSessions.values)
        let oldest = Dictionary(uniqueKeysWithValues: observed.compactMap { id in
            receipts[id]?.last.map { (id, $0.id) }
        })
        let snapshot = try await database.toolStateSnapshot(sessionIDs: observed.union(sessionPolicies.keys).union(policyIDs),
            oldestReceipts: oldest, receiptSessionIDs: observed)
        guard generation == reloadGeneration, !stopped, !Task.isCancelled else { return }
        if mayPublishSettings, pendingSettingsWrites == 0 {
            committedSettings = snapshot.settings
            if settings != snapshot.settings { settings = snapshot.settings }
        }
        let relationships = Dictionary(uniqueKeysWithValues: snapshot.relationships.map { ($0.sessionID, $0) })
        if self.relationships != relationships { self.relationships = relationships }
        if timers != snapshot.timers { timers = snapshot.timers }
        if sessionPolicies != snapshot.policies { sessionPolicies = snapshot.policies }
        for id in observed.intersection(observedSessions.values) {
            guard receipts[id]?.last?.id == oldest[id] else { continue }
            let rows = snapshot.receipts[id] ?? []
            if oldest[id] != nil { publishReceipts(rows, for: id) }
            else {
                publishReceipts(Array(rows.prefix(200)), for: id)
                setHasOlderReceipts(rows.count > 200, for: id)
            }
        }
    }

    func observeSessionFromUI(_ id: String?, token: UUID) {
        updateObservedSession(id, token: token)
        if id != nil {
            Task { do { try await reload() } catch { self.error = error.localizedDescription } }
        }
    }

    func observeSession(_ id: String?, token: UUID) async {
        updateObservedSession(id, token: token)
        if id != nil { do { try await reload() } catch { self.error = error.localizedDescription } }
    }

    private func updateObservedSession(_ id: String?, token: UUID) {
        reloadGeneration = UUID()
        observedSessions[token] = id
        let active = Set(observedSessions.values)
        receiptPageRequests = receiptPageRequests.filter { active.contains($0.key) }
        let retainedReceipts = receipts.filter { active.contains($0.key) }
        if receipts != retainedReceipts { receipts = retainedReceipts }
        let retainedOlderReceipts = hasOlderReceipts.intersection(active)
        if hasOlderReceipts != retainedOlderReceipts { hasOlderReceipts = retainedOlderReceipts }
    }

    private func publishReceipts(_ value: [WorkspaceSessionDelivery], for id: String) {
        // Polling must not invalidate the conversation on an unchanged snapshot.
        // Compare the complete payload, including status and native command,
        // rather than just receipt IDs or count.
        guard receipts[id] != value else { return }
        receipts[id] = value
    }

    private func setHasOlderReceipts(_ value: Bool, for id: String) {
        guard hasOlderReceipts.contains(id) != value else { return }
        if value { hasOlderReceipts.insert(id) } else { hasOlderReceipts.remove(id) }
    }

    func loadOlderReceipts(sessionID: String) async {
        reloadGeneration = UUID()
        guard let oldestID = receipts[sessionID]?.last?.id, !stopped else { return }
        let request = UUID()
        receiptPageRequests[sessionID] = request
        defer { if receiptPageRequests[sessionID] == request { receiptPageRequests[sessionID] = nil } }
        do {
            let page = try await database.sessionDeliveries(sessionID: sessionID, limit: 201,
                beforeID: oldestID, activityOnly: true)
            guard !stopped, !Task.isCancelled, receiptPageRequests[sessionID] == request,
                  observedSessions.values.contains(sessionID),
                  receipts[sessionID]?.last?.id == oldestID else { return }
            // Preserve new arrivals and fence snapshots captured before this window grew.
            reloadGeneration = UUID()
            let current = receipts[sessionID] ?? []
            let known = Set(current.map(\.id))
            publishReceipts(current + page.prefix(200).filter { !known.contains($0.id) }, for: sessionID)
            setHasOlderReceipts(page.count > 200, for: sessionID)
        } catch is CancellationError { }
        catch { if !stopped, receiptPageRequests[sessionID] == request { self.error = error.localizedDescription } }
    }

    func endCoordination(sessionID: String) async {
        if passiveProjection { enqueue(.endCoordination(sessionID: sessionID)); return }
        do { try await database.endCoordination(targetID: sessionID); try await reload(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func setNotifications(sessionID: String, enabled: Bool) async {
        if passiveProjection { enqueue(.notifications(sessionID: sessionID, enabled: enabled)); return }
        do {
            if let source = try await database.sessionRelationship(sessionID).coordinatorID {
                try await database.setCoordinationNotifications(sourceID: source, targetID: sessionID, enabled: enabled)
            }
            try await reload(); error = nil
        } catch { self.error = error.localizedDescription }
    }

    func pauseTimer(_ timer: WorkspaceSessionTimer, paused: Bool) async {
        if passiveProjection { enqueue(.pauseTimer(id: timer.id, paused: paused)); return }
        do { try await database.pauseSessionTimer(id: timer.id, paused: paused); try await reload(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func removeTimer(_ timer: WorkspaceSessionTimer) async {
        if passiveProjection { enqueue(.removeTimer(id: timer.id)); return }
        do { try await database.removeSessionTimer(id: timer.id); try await reload(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    /// SwiftUI reads a published value; loading is done by observeSession/reload.
    func policy(for sessionID: String) -> WorkspaceSessionTools {
        sessionPolicies[sessionID] ?? WorkspaceSessionTools(enabled: [])
    }

    func saveSettingsFromUI(_ value: WorkspaceToolSettings) {
        let generation = UUID()
        settingsEditGeneration = generation
        reloadGeneration = UUID()
        settings = value
        pendingSettingsWrites += 1
        let previous = mutationTask
        mutationTask = Task {
            await previous?.value
            // Compare against the last completed write, so a queued toggle can
            // undo its predecessor and a failed predecessor can be retried.
            let base = committedSettings
            var failure: String?
            do {
                if let backendMutation { try await backendMutation(.saveSettings(value, base: base)) }
                else { try await database.saveToolSettings(value, from: base) }
                committedSettings = value
            } catch { failure = error.localizedDescription }
            pendingSettingsWrites -= 1
            guard settingsEditGeneration == generation, pendingSettingsWrites == 0, !stopped else { return }
            guard let failure else { error = nil; return }

            // A failed optimistic edit must not keep displaying unsaved defaults.
            // Preserve newer edits, and reconcile an uncertain backend reply with
            // its committed database value without allowing a stale read to win.
            settings = committedSettings
            error = failure
            let rollbackGeneration = UUID()
            reloadGeneration = rollbackGeneration
            if let saved = try? await database.toolSettings() {
                guard settingsEditGeneration == generation, pendingSettingsWrites == 0,
                      reloadGeneration == rollbackGeneration, !stopped else { return }
                committedSettings = saved
                if settings != saved { settings = saved }
            }
        }
    }

    func saveTimer(_ timer: WorkspaceSessionTimer) async throws {
        if let backendMutation { try await backendMutation(.saveTimer(timer)) }
        else { _ = try await database.saveSessionTimer(timer, callerID: timer.sessionID) }
        try await reload()
    }

    func saveSettings(_ value: WorkspaceToolSettings) async {
        saveSettingsFromUI(value)
        await mutationTask?.value
    }

    func setEnabled(_ group: WorkspaceToolGroup, enabled: Bool, sessionID: String, confirmedPausingTimers: Bool = false) async throws {
        guard !passiveProjection else { throw WorkspaceToolError.invalid("Use the background service to change session tools.") }
        if group == .executor {
            guard let executorControl else { throw WorkspaceToolError.invalid("Executor manager is unavailable.") }
            _ = try await executorControl(.enabled(session: sessionID, enabled: enabled))
            try await reload(policyIDs: [sessionID])
            return
        }
        let policy = try await database.setSessionToolEnabled(group, enabled: enabled, sessionID: sessionID,
            confirmedPausingTimers: confirmedPausingTimers)
        sessionPolicies[sessionID] = policy
        try await reload()
    }

    func endpoint(for sessionID: String) async throws -> String {
        guard !passiveProjection else { throw CancellationError() }
        guard !stopped else { throw CancellationError() }
        _ = try await database.sessionTools(sessionID)
        guard !stopped else { throw CancellationError() }
        if let service = services[sessionID] { return service.socketURL.path }
        let path = endpointDirectory.appending(path: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".sock")
        let service = WovenMatterToolService(socketURL: path, maximumConnections: 4) { [weak self] request in
            guard let self else { return WovenMatterToolResponse(success: false, error: "Woven Matter closed this endpoint.") }
            return await self.handle(request, callerID: sessionID)
        }
        try service.start()
        services[sessionID] = service
        return path.path
    }

    func stop() {
        stopped = true
        reloadGeneration = UUID()
        receiptPageRequests.removeAll()
        for pending in pendingBridges.values { pending.cancel() }
        pendingBridges.removeAll()
        for bridge in remoteBridges.values { bridge.stop() }
        remoteBridges.removeAll()
        for service in services.values { try? service.stop() }
        services.removeAll()
        if !passiveProjection { try? FileManager.default.removeItem(at: endpointDirectory) }
    }

    func discovery(sessionID: String, remote: RemoteWorkspaceConfiguration? = nil, noteID: String? = nil) async throws -> String {
        let path = try await endpoint(for: sessionID)
        let cliPath: String
        var exports: [String]
        if let remote {
            if let bridge = remoteBridges[sessionID], bridge.isRunning {
                cliPath = bridge.remoteCLIPath
            } else {
                let pending: Task<WovenMatterRemoteToolBridge, any Error>
                if let existing = pendingBridges[sessionID] { pending = existing }
                else {
                    guard let sourceURL = Bundle.main.resourceURL?.appending(path: "wovenmatter-remote.py") else {
                        throw WorkspaceToolError.invalid("The bundled remote CLI is missing.")
                    }
                    let source = try String(contentsOf: sourceURL, encoding: .utf8)
                    pending = Task { try await WovenMatterRemoteToolBridge.start(configuration: remote, ownerID: ownerID, localSocket: path, source: source) }
                    pendingBridges[sessionID] = pending
                }
                defer { pendingBridges.removeValue(forKey: sessionID) }
                let bridge = try await pending.value
                guard !stopped else { bridge.stop(); throw CancellationError() }
                remoteBridges[sessionID] = bridge
                cliPath = bridge.remoteCLIPath
            }
            exports = ["unset WOVENMATTER_SOCKET"]
        } else {
            guard let resource = Bundle.main.resourceURL?.appending(path: "wovenmatter"), FileManager.default.isExecutableFile(atPath: resource.path) else {
                throw WorkspaceToolError.invalid("The bundled Woven Matter CLI is missing.")
            }
            cliPath = resource.path
            exports = ["export WOVENMATTER_SOCKET=" + Self.quote(path)]
        }
        exports.append("export WOVENMATTER_CLI=" + Self.quote(cliPath))
        if let noteID { exports.append("export WOVENMATTER_NOTE_ID=" + Self.quote(noteID)) }
        else { exports.append("unset WOVENMATTER_NOTE_ID") }
        let enabled = try await database.sessionTools(sessionID).enabled
        let groups = WorkspaceToolGroup.allCases.filter { enabled.contains($0) }.map(\.rawValue).joined(separator: ", ")
        return """
        <wovenmatter-tools>
        This is Woven Matter session \(sessionID). Its enabled app tools are: \(groups.isEmpty ? "none" : groups).
        Use this session-bound CLI for app data and session actions. Read detailed help only when needed; do not open the app's SQLite files.
        \(exports.joined(separator: "\n"))
        "$WOVENMATTER_CLI" help
        "$WOVENMATTER_CLI" GROUP help
        Session messages are attributed to you. Read only relevant history. Managing a session is an ongoing assignment; release it when finished. Tool changes take effect immediately.
        </wovenmatter-tools>
        """
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func handle(_ request: WovenMatterToolRequest, callerID: String) async -> WovenMatterToolResponse {
        await execute(request, callerID: callerID).bounded()
    }

    private func execute(_ request: WovenMatterToolRequest, callerID: String) async -> WovenMatterToolResponse {
        guard !passiveProjection else { return .init(success: false, error: "Tool execution belongs to the background service.") }
        var parsedCommand: WovenMatterToolCommand?
        do {
            guard request.schemaVersion == 1, let requestUUID = UUID(uuidString: request.requestID) else {
                throw WorkspaceToolError.invalid("Unsupported tool request.")
            }
            var request = request
            request.requestID = requestUUID.uuidString.lowercased()
            let command = try WovenMatterToolCommand(request.arguments)
            parsedCommand = command
            if let suppliedRequestID = command.options["request-id"] {
                guard let suppliedUUID = UUID(uuidString: suppliedRequestID),
                      suppliedUUID.uuidString.lowercased() == request.requestID else {
                    throw WorkspaceToolError.invalid("--request-id must match the request envelope.")
                }
            }
            if command.wantsHelp {
                return .init(result: .object(["help": .string(WovenMatterToolCommand.help(for: command))]))
            }
            guard let group = command.group else { throw WorkspaceToolError.invalid("Choose a tool group.") }
            // Scoped history reads have their own independent attachment/management
            // checks. All other commands require the group's current capability.
            if group != .history { try await database.requireTool(group, sessionID: callerID) }
            let result: WovenMatterToolResponse
            switch group {
            case .history:
                result = .init(result: try await database.queryAgentHistory(historyQuery(command), callerID: callerID,
                    allWorkspace: command.options["all-workspace"] != nil))
            case .notes: result = try await notes(command, request: request, callerID: callerID)
            case .sessions:
                if command.action == "list" || command.action == "status" {
                    var query = try historyQuery(command)
                    query.command = "conversations"
                    if command.action == "status" { query.id = try command.required("id", allowPositional: true) }
                    var page = try await database.queryAgentHistory(query, callerID: callerID,
                        allWorkspace: command.options["all-workspace"] != nil)
                    if command.action == "status", var object = page.objectValue, let id = query.id {
                        guard object["rows"]?.arrayValue?.isEmpty == false else {
                            throw WorkspaceToolError.notFound("The requested session was not found.")
                        }
                        object["relationship"] = try WovenMatterToolResponse.value(
                            await database.sessionRelationship(id)).result ?? .null
                        page = .object(object)
                    }
                    result = .init(result: page)
                } else if command.action == "folders" {
                    result = .init(result: try await database.listAgentFolders(callerID: callerID,
                        after: Int64(command.integer("after", default: 0, range: 0...Int.max)),
                        limit: command.integer("limit", default: 100, range: 1...200)))
                } else { result = try await sessionHandler(callerID, command, request) }
            case .timers: result = try await timer(command, callerID: callerID, requestID: request.requestID)
            case .calendar: result = try await calendar(command, callerID: callerID, requestID: request.requestID)
            case .usage: result = try await usageHandler(command)
            case .library: result = try await library(command, callerID: callerID)
            case .executor:
                guard let executorHandler else { throw WorkspaceToolError.invalid("Executor manager is unavailable.") }
                result = try await executorHandler(callerID, command, request)
            }
            if command.isMutation {
                try await recordCLIMutation(command: command, callerID: callerID, requestID: request.requestID,
                    success: result.success, code: result.code)
            }
            try await reload()
            await onMutation()
            return .init(success: result.success, result: result.result, error: result.error,
                code: result.code, silent: result.silent, requestID: request.requestID)
        } catch {
            let code = Self.errorCode(error)
            if let command = parsedCommand, command.isMutation {
                let canonicalID = UUID(uuidString: request.requestID)?.uuidString.lowercased() ?? request.requestID
                try? await recordCLIMutation(command: command, callerID: callerID, requestID: canonicalID,
                    success: false, code: code)
            }
            return .init(success: false, error: error.localizedDescription, code: code,
                requestID: UUID(uuidString: request.requestID)?.uuidString.lowercased() ?? request.requestID)
        }
    }

    private func recordCLIMutation(command: WovenMatterToolCommand, callerID: String,
                                   requestID: String, success: Bool, code: String?) async throws {
        var payload: [String: String] = [
            "group": command.group?.rawValue ?? "unknown", "action": command.action,
            "requestID": requestID, "success": success ? "true" : "false"
        ]
        if let code { payload["code"] = code }
        try await database.recordHistory(.init(conversationID: callerID, harness: "wovenmatter",
            kind: "cli.mutation", payload: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)))
    }

    private static func errorCode(_ error: any Error) -> String {
        if let error = error as? WorkspaceToolError {
            switch error {
            case .disabled: return "tool_disabled"
            case .accessRequired: return "access_required"
            case .coordinationConflict: return "coordination_conflict"
            case .managedLimit: return "managed_limit"
            case .atCapacity: return "at_capacity"
            case .notFound: return "not_found"
            case .revisionRequired: return "revision_required"
            case .revisionConflict: return "revision_conflict"
            case .timerPauseConfirmation: return "confirmation_required"
            case .invalid: return "invalid_request"
            }
        }
        if let error = error as? WorkspaceNoteMutationError {
            switch error {
            case .folderNotFound, .noteNotFound: return "not_found"
            case .revisionConflict: return "revision_conflict"
            }
        }
        if error is CancellationError { return "cancelled" }
        return "operation_failed"
    }

    private func historyQuery(_ command: WovenMatterToolCommand) throws -> WorkspaceHistoryQuery {
        var query = WorkspaceHistoryQuery(command: command.action)
        if command.action == "search" { query.search = try command.required("search", allowPositional: true) }
        else { query.id = command.options["id"] ?? command.positional.first; query.search = command.options["search"] }
        query.conversationID = command.options["conversation"]
        query.runID = command.options["run"]
        query.harness = command.options["harness"]
        query.folderID = command.options["folder"]
        query.kind = command.options["kind"]
        query.since = command.options["since"]
        query.until = command.options["until"]
        query.sort = command.options["sort"] ?? (command.action == "conversations" ||
            (command.group == .sessions && command.action == "list") ? "newest" : "oldest")
        let initialCursor = query.sort == "newest" ? Int.max : 0
        query.after = Int64(try command.integer("after", default: initialCursor, range: 0...Int.max))
        query.limit = try command.integer("limit", default: 50, range: 1...200)
        query.offset = try command.integer("offset", default: 0, range: 0...(Int.max - 1))
        query.characters = try command.integer("characters", default: 65_536, range: 1...65_536)
        return query
    }

    private func notes(_ command: WovenMatterToolCommand, request: WovenMatterToolRequest, callerID: String) async throws -> WovenMatterToolResponse {
        switch command.action {
        case "list":
            let newest = (command.options["sort"] ?? "newest") == "newest"
            let initialCursor = newest ? Int.max : 0
            return .init(result: try await database.listAgentNotes(callerID: callerID, search: command.options["search"], folderID: command.options["folder"],
                after: Int64(try command.integer("after", default: initialCursor, range: 0...Int.max)),
                limit: try command.integer("limit", default: 50, range: 1...200), newestFirst: newest))
        case "folders":
            return .init(result: try await database.listAgentFolders(callerID: callerID, requiredTool: .notes,
                after: Int64(command.integer("after", default: 0, range: 0...Int.max)),
                limit: command.integer("limit", default: 100, range: 1...200)))
        case "create":
            guard let kind = NoteArtifactKind(rawValue: command.options["kind"] ?? "note") else { throw WorkspaceToolError.invalid("Choose note, spreadsheet or html.") }
            let id = try await database.createNote(folderID: command.options["folder"], title: command.required("title"), kind: kind, callerConversationID: callerID, requestID: request.requestID)
            return .init(result: .object(["id": .string(id)]))
        case "versions", "version":
            var query = try historyQuery(command)
            query.id = command.options[command.action == "versions" ? "note-id" : "version"]
                ?? command.options["id"] ?? command.positional.first
            return .init(result: try await database.queryAgentHistory(query, callerID: callerID))
        case "restore":
            return try noteMutationAcknowledgement(await noteRestoreHandler(callerID,
                command.required("note-id", allowPositional: true), command.required("version"),
                command.required("revision"), request.requestID))
        default:
            guard command.options["file"] == nil else { throw WorkspaceToolError.invalid("Read input files on the CLI host before sending the request.") }
            var args = Array(request.operationArguments.dropFirst())
            if command.options["note-id"] == nil, let noteID = command.positional.first {
                args += ["--note-id", noteID]
            }
            let edit = try WovenNoteCommandLine.request(arguments: args, environment: [:])
            let response = try await noteHandler(callerID, edit, request.requestID)
            if command.action == "read" {
                return try noteReadChunk(response,
                    offset: command.integer("offset", default: 0, range: 0...(Int.max - 1)),
                    characters: command.integer("characters", default: 65_536, range: 1...65_536))
            }
            return try noteMutationAcknowledgement(response)
        }
    }

    private func noteMutationAcknowledgement(_ response: NoteEditingResponse) throws -> WovenMatterToolResponse {
        var object: [String: GatewayJSONValue] = ["id": .string(response.noteID)]
        object["title"] = response.title.map(GatewayJSONValue.string) ?? .null
        object["revision"] = response.revision.map(GatewayJSONValue.string) ?? .null
        object["replayed"] = .bool(response.replayed == true)
        return .init(success: response.success, result: .object(object), error: response.error,
            code: response.success ? nil : "mutation_failed")
    }

    private func noteReadChunk(_ response: NoteEditingResponse, offset: Int,
                               characters: Int) throws -> WovenMatterToolResponse {
        guard response.success, let document = response.document else {
            return .init(success: false, error: response.error ?? "The note could not be read.", code: "read_failed")
        }
        let content = try document.encoded()
        let actualOffset = min(offset, content.count)
        let start = content.index(content.startIndex, offsetBy: actualOffset)
        let end = content.index(start, offsetBy: min(characters, content.distance(from: start, to: content.endIndex)))
        let next = content.distance(from: content.startIndex, to: end)
        return .init(result: .object([
            "id": .string(response.noteID),
            "title": response.title.map(GatewayJSONValue.string) ?? .null,
            "revision": response.revision.map(GatewayJSONValue.string) ?? .null,
            "kind": .string(document.kind.rawValue),
            "content": .string(String(content[start..<end])),
            "contentCharacters": .number(Double(content.count)),
            "offset": .number(Double(actualOffset)),
            "hasMore": .bool(next < content.count),
            "nextOffset": .number(Double(next))
        ]))
    }

    private func timer(_ command: WovenMatterToolCommand, callerID: String, requestID: String) async throws -> WovenMatterToolResponse {
        let target = command.options["session"] ?? callerID
        if target != callerID {
            try await database.requireTool(.sessions, sessionID: callerID)
            guard try await database.sessionRelationship(target).coordinatorID == callerID else { throw WorkspaceToolError.accessRequired(target) }
        }
        if command.action == "list" {
            return .init(result: try await database.querySessionTimers(callerID: callerID, sessionID: target,
                after: Int64(command.integer("after", default: 0, range: 0...Int.max)),
                limit: command.integer("limit", default: 100, range: 1...200)))
        }
        if command.action == "create" || command.action == "update" {
            let id = command.action == "create" ? requestID : try command.required("id", allowPositional: true)
            let interval: Double?
            if let raw = command.options["every"] {
                guard let value = Double(raw) else { throw WorkspaceToolError.invalid("--every requires seconds.") }
                interval = value
            } else { interval = nil }
            let timer = WorkspaceSessionTimer(id: id, sessionID: target,
                instruction: try command.required("text"), nextFireAt: try Self.date(command.required("at")),
                intervalSeconds: interval, isPaused: command.options["paused"] != nil)
            return try await .value(database.saveSessionTimer(timer, callerID: callerID, requestID: requestID,
                creating: command.action == "create"))
        }
        let id = try command.required("id", allowPositional: true)
        if command.action == "remove" { try await database.removeSessionTimer(id: id, callerID: callerID, requestID: requestID) }
        else { try await database.pauseSessionTimer(id: id, paused: command.action == "pause", callerID: callerID, requestID: requestID) }
        return .init(result: .object(["id": .string(id), "status": .string(command.action)]))
    }

    private func library(_ command: WovenMatterToolCommand, callerID: String) async throws -> WovenMatterToolResponse {
        var query = LibraryQuery()
        query.search = command.options["search"] ?? ""
        if let workspace = command.options["workspace"] {
            query.workspaces = Set(workspace.split(separator: ",").map { String($0).lowercased() })
        }
        if let harness = command.options["harness"] {
            query.harnesses = Set(harness.split(separator: ",").map(String.init))
        }
        if let kind = command.options["kind"] {
            guard let value = LibraryItemKind(rawValue: kind) else { throw WorkspaceToolError.invalid("Use file, link, or photo.") }
            query.kind = value
        }
        if let sender = command.options["sender"] {
            guard let value = LibrarySender(rawValue: sender) else { throw WorkspaceToolError.invalid("Use me or agent.") }
            query.sender = value
        }
        query.since = try command.options["since"].map(Self.date)
        query.until = try command.options["until"].map(Self.date)
        if let since = query.since, let until = query.until, until < since {
            throw WorkspaceToolError.invalid("--until must be at or after --since.")
        }
        return .init(result: try await database.queryAgentLibrary(callerID: callerID,
            id: command.action == "read" ? try command.required("id", allowPositional: true) : nil,
            query: query, limit: command.integer("limit", default: 100, range: 1...200),
            offset: command.integer("offset", default: 0, range: 0...Int.max)))
    }

    static func date(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else { throw WorkspaceToolError.invalid("Use an ISO 8601 date with a time zone.") }
        return date
    }
}
