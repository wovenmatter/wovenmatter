import Foundation
import Observation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

@MainActor @Observable
final class WorkspaceAgentToolsModel {
    typealias SessionHandler = @MainActor (String, WovenMatterToolCommand, WovenMatterToolRequest) async throws -> WovenMatterToolResponse
    typealias NoteHandler = @MainActor (String, NoteEditingRequest, String) async throws -> NoteEditingResponse
    typealias NoteRestoreHandler = @MainActor (String, String, String, String, String) async throws -> NoteEditingResponse
    typealias UsageHandler = @MainActor (WovenMatterToolCommand) async throws -> WovenMatterToolResponse
    let database: WorkspaceDatabase
    private(set) var settings: WorkspaceToolSettings
    private(set) var sessionPolicies: [String: WorkspaceSessionTools] = [:]
    private(set) var relationships: [String: WorkspaceSessionRelationship] = [:]
    private(set) var timers: [WorkspaceSessionTimer] = []
    private(set) var receipts: [String: [WorkspaceSessionDelivery]] = [:]
    private var observedSessions: [UUID: String] = [:]
    private(set) var hasOlderReceipts: Set<String> = []
    var error: String?
    private var services: [String: WovenMatterToolService] = [:]
    private var remoteBridges: [String: WovenMatterRemoteToolBridge] = [:]
    private var pendingBridges: [String: Task<WovenMatterRemoteToolBridge, any Error>] = [:]
    private let ownerID = UUID()
    private var stopped = false
    private let endpointDirectory: URL
    private let sessionHandler: SessionHandler
    private let noteHandler: NoteHandler
    private let noteRestoreHandler: NoteRestoreHandler
    private let usageHandler: UsageHandler
    private let onMutation: @MainActor () async -> Void

    init(database: WorkspaceDatabase, sessionHandler: @escaping SessionHandler,
         noteHandler: @escaping NoteHandler, noteRestoreHandler: @escaping NoteRestoreHandler, usageHandler: @escaping UsageHandler,
         onMutation: @escaping @MainActor () async -> Void) throws {
        self.database = database
        self.settings = try database.toolSettings()
        self.sessionHandler = sessionHandler
        self.noteHandler = noteHandler
        self.noteRestoreHandler = noteRestoreHandler
        self.usageHandler = usageHandler
        self.onMutation = onMutation
        endpointDirectory = URL(fileURLWithPath: "/private/tmp/wmtools-" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        try FileManager.default.createDirectory(at: endpointDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try reload()
    }

    func reload() throws {
        let nextSettings = try database.toolSettings()
        if settings != nextSettings { settings = nextSettings }
        let nextRelationships = Dictionary(uniqueKeysWithValues: try database.sessionRelationships().map { ($0.sessionID, $0) })
        if relationships != nextRelationships { relationships = nextRelationships }
        let nextTimers = try database.sessionTimers()
        if timers != nextTimers { timers = nextTimers }
        var nextPolicies = sessionPolicies
        for id in sessionPolicies.keys { nextPolicies[id] = try? database.sessionTools(id) }
        if sessionPolicies != nextPolicies { sessionPolicies = nextPolicies }
        for id in Set(observedSessions.values) {
            if let oldest = receipts[id]?.last {
                let window = try database.sessionActivityWindow(sessionID: id, throughID: oldest.id)
                publishReceipts(window, for: id)
            } else { try loadInitialReceipts(id) }
        }
    }

    func observeSession(_ id: String?, token: UUID) {
        observedSessions[token] = id
        if let id {
            do { if receipts[id] == nil { try loadInitialReceipts(id) } }
            catch { self.error = error.localizedDescription }
        }
        let active = Set(observedSessions.values)
        let retainedReceipts = receipts.filter { active.contains($0.key) }
        if receipts != retainedReceipts { receipts = retainedReceipts }
        let retainedOlderReceipts = hasOlderReceipts.intersection(active)
        if hasOlderReceipts != retainedOlderReceipts { hasOlderReceipts = retainedOlderReceipts }
    }

    private func loadInitialReceipts(_ id: String) throws {
        let page = try database.sessionDeliveries(sessionID: id, limit: 201, activityOnly: true)
        publishReceipts(Array(page.prefix(200)), for: id)
        setHasOlderReceipts(page.count > 200, for: id)
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

    func loadOlderReceipts(sessionID: String) {
        guard let oldest = receipts[sessionID]?.last else { return }
        do {
            let page = try database.sessionDeliveries(sessionID: sessionID, limit: 201, beforeID: oldest.id, activityOnly: true)
            publishReceipts((receipts[sessionID] ?? []) + page.prefix(200), for: sessionID)
            setHasOlderReceipts(page.count > 200, for: sessionID)
        } catch { self.error = error.localizedDescription }
    }

    func endCoordination(sessionID: String) {
        do { try database.endCoordination(targetID: sessionID); try reload(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func setNotifications(sessionID: String, enabled: Bool) {
        do {
            if let source = try database.sessionRelationship(sessionID).coordinatorID {
                try database.setCoordinationNotifications(sourceID: source, targetID: sessionID, enabled: enabled)
            }
            try reload(); error = nil
        } catch { self.error = error.localizedDescription }
    }

    func pauseTimer(_ timer: WorkspaceSessionTimer, paused: Bool) {
        do { try database.pauseSessionTimer(id: timer.id, paused: paused); try reload(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func removeTimer(_ timer: WorkspaceSessionTimer) {
        do { try database.removeSessionTimer(id: timer.id); try reload(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func policy(for sessionID: String) -> WorkspaceSessionTools {
        if let value = sessionPolicies[sessionID] { return value }
        do {
            return try database.sessionTools(sessionID)
        } catch {
            return WorkspaceSessionTools(enabled: [])
        }
    }

    func saveSettings(_ value: WorkspaceToolSettings) {
        do { try database.saveToolSettings(value); settings = value; error = nil }
        catch { self.error = error.localizedDescription }
    }

    func setEnabled(_ group: WorkspaceToolGroup, enabled: Bool, sessionID: String, confirmedPausingTimers: Bool = false) throws {
        var policy = try database.sessionTools(sessionID)
        if enabled { policy.enabled.insert(group) } else { policy.enabled.remove(group) }
        try database.setSessionTools(policy, sessionID: sessionID, confirmedPausingTimers: confirmedPausingTimers)
        sessionPolicies[sessionID] = policy
        try reload()
    }

    func endpoint(for sessionID: String) throws -> String {
        guard !stopped else { throw CancellationError() }
        _ = try database.sessionTools(sessionID)
        if let service = services[sessionID] { return service.socketURL.path }
        let path = endpointDirectory.appending(path: UUID().uuidString.replacingOccurrences(of: "-", with: "") + ".sock")
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
        for pending in pendingBridges.values { pending.cancel() }
        pendingBridges.removeAll()
        for bridge in remoteBridges.values { bridge.stop() }
        remoteBridges.removeAll()
        for service in services.values { try? service.stop() }
        services.removeAll()
        try? FileManager.default.removeItem(at: endpointDirectory)
    }

    func discovery(sessionID: String, remote: RemoteWorkspaceConfiguration? = nil, noteID: String? = nil) async throws -> String {
        let path = try endpoint(for: sessionID)
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
        let enabled = try database.sessionTools(sessionID).enabled
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
        do {
            guard request.schemaVersion == 1, UUID(uuidString: request.requestID) != nil else {
                throw WorkspaceToolError.invalid("Unsupported tool request.")
            }
            let command = try WovenMatterToolCommand(request.arguments)
            if command.wantsHelp {
                return .init(result: .object(["help": .string(command.group.map(WovenMatterToolCommand.help) ?? WovenMatterToolCommand.usage)]))
            }
            guard let group = command.group else { throw WorkspaceToolError.invalid("Choose a tool group.") }
            // Scoped history reads have their own independent attachment/management
            // checks. All other commands require the group's current capability.
            if group != .history { try database.requireTool(group, sessionID: callerID) }
            try database.recordHistory(.init(conversationID: callerID, harness: "wovenmatter", kind: "cli.request",
                payload: String(decoding: try JSONEncoder().encode(request), as: UTF8.self)))
            let result: WovenMatterToolResponse
            switch group {
            case .history:
                result = .init(result: try database.queryAgentHistory(historyQuery(command), callerID: callerID,
                    allWorkspace: command.options["all-workspace"] != nil))
            case .notes: result = try await notes(command, request: request, callerID: callerID)
            case .sessions:
                if command.action == "list" || command.action == "status" {
                    var query = try historyQuery(command)
                    query.command = "conversations"
                    if command.action == "status" { query.id = try command.required("id", allowPositional: true) }
                    result = .init(result: try database.queryAgentHistory(query, callerID: callerID,
                        allWorkspace: command.options["all-workspace"] != nil))
                } else if command.action == "folders" {
                    result = .init(result: try database.listAgentFolders(callerID: callerID))
                } else { result = try await sessionHandler(callerID, command, request) }
            case .timers: result = try timer(command, callerID: callerID, requestID: request.requestID)
            case .calendar: result = try calendar(command, callerID: callerID, requestID: request.requestID)
            case .usage: result = try await usageHandler(command)
            case .library: result = try library(command, callerID: callerID)
            }
            // History queries persist reference IDs in the database's query
            // path. Re-journaling their full response recursively copies history.
            if group != .history {
                try database.recordHistory(.init(conversationID: callerID, harness: "wovenmatter", kind: "cli.response",
                    payload: String(decoding: try JSONEncoder().encode(result), as: UTF8.self)))
            }
            try reload()
            await onMutation()
            return .init(success: result.success, result: result.result, error: result.error, silent: result.silent, requestID: request.requestID)
        } catch {
            try? database.recordHistory(.init(conversationID: callerID, harness: "wovenmatter", kind: "cli.error", payload: error.localizedDescription))
            return .init(success: false, error: error.localizedDescription, requestID: request.requestID)
        }
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
        query.after = Int64(try command.integer("after", default: 0, range: 0...Int.max))
        query.limit = try command.integer("limit", default: 50, range: 1...200)
        query.offset = try command.integer("offset", default: 0, range: 0...(Int.max - 1))
        query.characters = try command.integer("characters", default: 65_536, range: 1...65_536)
        return query
    }

    private func notes(_ command: WovenMatterToolCommand, request: WovenMatterToolRequest, callerID: String) async throws -> WovenMatterToolResponse {
        switch command.action {
        case "list":
            return .init(result: try database.listAgentNotes(callerID: callerID, search: command.options["search"], folderID: command.options["folder"],
                after: Int64(try command.integer("after", default: 0, range: 0...Int.max)), limit: try command.integer("limit", default: 50, range: 1...200)))
        case "create":
            guard let kind = NoteArtifactKind(rawValue: command.options["kind"] ?? "note") else { throw WorkspaceToolError.invalid("Choose note, spreadsheet or html.") }
            let id = try database.createNote(folderID: command.options["folder"], title: command.required("title"), kind: kind, callerConversationID: callerID, requestID: request.requestID)
            return .init(result: .object(["id": .string(id)]))
        case "versions", "version":
            return .init(result: try database.queryAgentHistory(historyQuery(command), callerID: callerID))
        case "restore":
            return try .note(await noteRestoreHandler(callerID, command.required("note-id", allowPositional: true),
                command.required("version"), command.required("revision"), request.requestID))
        default:
            guard command.options["file"] == nil else { throw WorkspaceToolError.invalid("Read input files on the CLI host before sending the request.") }
            let args = Array(request.operationArguments.dropFirst())
            let edit = try WovenNoteCommandLine.request(arguments: args, environment: [:])
            return try .note(await noteHandler(callerID, edit, request.requestID))
        }
    }

    private func timer(_ command: WovenMatterToolCommand, callerID: String, requestID: String) throws -> WovenMatterToolResponse {
        let target = command.options["session"] ?? callerID
        if target != callerID {
            try database.requireTool(.sessions, sessionID: callerID)
            guard try database.sessionRelationship(target).coordinatorID == callerID else { throw WorkspaceToolError.accessRequired(target) }
        }
        if command.action == "list" { return try .value(database.sessionTimers(sessionID: target)) }
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
            return try .value(database.saveSessionTimer(timer, callerID: callerID, requestID: requestID,
                creating: command.action == "create"))
        }
        let id = try command.required("id", allowPositional: true)
        if command.action == "remove" { try database.removeSessionTimer(id: id, callerID: callerID, requestID: requestID) }
        else { try database.pauseSessionTimer(id: id, paused: command.action == "pause", callerID: callerID, requestID: requestID) }
        return .init(result: .object(["id": .string(id), "status": .string(command.action)]))
    }

    private func calendar(_ command: WovenMatterToolCommand, callerID: String, requestID: String) throws -> WovenMatterToolResponse {
        if command.action == "list" {
            return .init(result: try database.listAgentCalendar(callerID: callerID,
                since: command.options["since"].map(Self.date), until: command.options["until"].map(Self.date),
                after: Int64(command.integer("after", default: 0, range: 0...Int.max)), limit: command.integer("limit", default: 100, range: 1...200)))
        }
        if command.action == "remove" {
            try database.removeAgentCalendar(callerID: callerID, id: command.required("id", allowPositional: true), requestID: requestID)
            return .init()
        }
        let creating = command.action == "create"
        let id = try database.saveAgentCalendar(callerID: callerID, id: creating ? requestID : command.required("id", allowPositional: true),
            creating: creating, title: command.required("title"), details: command.options["description"], startsAt: Self.date(command.required("starts-at")),
            endsAt: command.options["ends-at"].map(Self.date), allDay: command.options["all-day"] != nil, requestID: requestID)
        return .init(result: .object(["id": .string(id)]))
    }

    private func library(_ command: WovenMatterToolCommand, callerID: String) throws -> WovenMatterToolResponse {
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
        return .init(result: try database.queryAgentLibrary(callerID: callerID,
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
