import Foundation
import WovenMatterCore

@MainActor
public protocol CompanionCommandServing: AnyObject {
    func providers() -> [CompanionProvider]
    func pendingInteractions() -> [CompanionPendingInteraction]
    func sessionCapabilities(conversationID: String) async throws -> CompanionProvider
    func transcript(conversationID: String, before: String?) async throws -> CompanionTranscript
    func receipt(commandID: String, deviceID: String) throws -> CompanionCommandReceipt?
    func execute(_ command: CompanionCommand, deviceID: String) async throws -> CompanionCommandReceipt
}

/// One authenticated, workspace-bound API per serving attempt. The activity
/// predicate captures that attempt, so a delayed request cannot cross stop/restart.
@MainActor
public final class CompanionWorkspaceAPI {
    private let database: WorkspaceDatabase
    private let authentication: CompanionAuthentication
    private let commands: any CompanionCommandServing
    private let isActive: @MainActor @Sendable () -> Bool
    private let onPair: @MainActor @Sendable () async -> Void
    private let onMutation: @MainActor @Sendable () -> Void
    private let onRequest: @MainActor @Sendable () -> Void
    private let linkedData: @MainActor @Sendable (DatabaseArtifactLink) async throws -> DatabaseTabularData
    private var linkedReadInFlight = false
    public init(database: WorkspaceDatabase, authentication: CompanionAuthentication,
                commands: any CompanionCommandServing,
                isActive: @escaping @MainActor @Sendable () -> Bool,
                onPair: @escaping @MainActor @Sendable () async -> Void = {},
                onMutation: @escaping @MainActor @Sendable () -> Void = {},
                onRequest: @escaping @MainActor @Sendable () -> Void = {},
                linkedData: @escaping @MainActor @Sendable (DatabaseArtifactLink) async throws -> DatabaseTabularData = { _ in
                    throw CompanionAPIError(code: "linked_data_unavailable", message: "This database is unavailable on the Mac.")
                }) {
        self.database = database; self.authentication = authentication; self.commands = commands
        self.isActive = isActive; self.onPair = onPair; self.onMutation = onMutation; self.onRequest = onRequest
        self.linkedData = linkedData
    }

    public func handle(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse {
        guard isActive() else { return .error("unavailable", "Companion sharing is stopped.", status: 503) }
        do {
            guard let target = URLComponents(string: "http://localhost" + request.target) else {
                return .error("invalid_request", "Invalid request path.", status: 400)
            }
            var path = target.path
            if path.hasPrefix("/wovenmatter/") { path = String(path.dropFirst("/wovenmatter".count)) }
            let workspaceID = try database.companionWorkspaceID()
            if request.method == "POST", path == "/v1/pair" {
                let command = try JSONDecoder().decode(CompanionPairRequest.self, from: request.body)
                let result = try await authentication.pair(command, workspaceID: workspaceID)
                await onPair()
                return try .json(result)
            }
            guard request.headers["x-woven-protocol"] == String(CompanionProtocol.version) else {
                return .error("version_mismatch", "Update Woven Matter on both devices to compatible versions.", status: 426)
            }
            guard let bearer = request.bearer else { return .error("unauthorized", "Pair this iPhone in Mac Settings.", status: 401) }
            let device = try await authentication.authenticate(bearer: bearer)
            guard isActive() else {
                return .error("unavailable", "Companion sharing stopped before this request was accepted.", status: 503)
            }
            guard request.headers["x-woven-workspace"] == workspaceID else {
                return .error("workspace_mismatch", "This credential belongs to a different workspace. Your local writing is preserved.", status: 409)
            }
            onRequest()
            let values = target.queryItems ?? []
            func query(_ name: String) -> String? { values.first(where: { $0.name == name })?.value }
            if request.method == "GET" {
                switch path {
                case "/v1/hello":
                    return try .json(CompanionHello(workspaceID: workspaceID,
                        hostName: Host.current().localizedName ?? "Woven Matter Mac",
                        capabilities: ["notes.conditional.v1", "folders.flat.v1", "changes.replay.v1", "commands.receipts.v1", "interactions.first-response.v1", "transcripts.paged.v1", "assets.linked-data.v1"]))
                case "/v1/snapshot": return try .json(database.companionSnapshot())
                case "/v1/changes":
                    guard let after = Int64(query("after") ?? query("cursor") ?? "0"), after >= 0 else {
                        return .error("invalid_cursor", "The change cursor is invalid.", status: 400)
                    }
                    let limit = max(1, min(200, Int(query("limit") ?? "200") ?? 200))
                    let wait = max(0, min(25, Double(query("wait") ?? "0") ?? 0))
                    let deadline = Date().addingTimeInterval(wait)
                    var page = try database.companionChanges(after: after, limit: limit)
                    while page.changes.isEmpty && !page.resetRequired && Date() < deadline && isActive() {
                        try await Task.sleep(for: .milliseconds(250))
                        _ = try await authentication.authenticate(bearer: bearer)
                        page = try database.companionChanges(after: after, limit: limit)
                    }
                    return try .json(page)
                case "/v1/providers": return try .json(commands.providers())
                case "/v1/pending": return try .json(commands.pendingInteractions())
                default: break
                }
                let components = path.split(separator: "/").map(String.init)
                if components.count == 4, components[0] == "v1", components[1] == "assets", components[3] == "linked-data" {
                    guard let note = try database.companionNote(id: components[2]),
                          let document = try? NoteDocument.editableDocument(from: note.content) else {
                        return .error("not_found", "This document cannot be previewed by this version of the Mac app.", status: 404)
                    }
                    let tableID = query("tableID")
                    let link: DatabaseArtifactLink?
                    if let tableID {
                        guard let block = document.blocks.first(where: { $0.id == tableID }), case .table(let table) = block else {
                            return .error("not_found", "This table is no longer in the document.", status: 404)
                        }
                        link = table.databaseLink ?? document.databaseLink
                    } else { link = document.databaseLink }
                    guard let link else { return .error("not_found", "This document has no linked database.", status: 404) }
                    guard !linkedReadInFlight else {
                        return .error("rate_limited", "A database preview is already loading. Try again shortly.", status: 429)
                    }
                    linkedReadInFlight = true
                    defer { linkedReadInFlight = false }
                    let data = try await linkedData(link)
                    guard isActive() else { return .error("unavailable", "Companion sharing is stopped.", status: 503) }
                    _ = try await authentication.authenticate(bearer: bearer)
                    let response = try CompanionHTTPResponse.json(CompanionLinkedData(noteID: note.id, noteRevision: note.revision,
                        tableID: tableID, columns: data.columns, rows: data.rows, json: data.json))
                    guard response.body.count <= 32 * 1_024 * 1_024 else {
                        return .error("preview_too_large", "Open this large database preview on your Mac.", status: 413)
                    }
                    return response
                }
                if components.count == 3, components[0] == "v1", components[1] == "command-receipts" {
                    guard let receipt = try commands.receipt(commandID: components[2], deviceID: device.id) else {
                        return .error("not_found", "The Mac has no receipt for this command. Retry explicitly using the same command ID.", status: 404)
                    }
                    return try .json(receipt)
                }
                if components.count == 4, components[0] == "v1", components[1] == "sessions" {
                    if components[3] == "transcript" {
                        return try .json(try await commands.transcript(conversationID: components[2], before: query("before")))
                    }
                    if components[3] == "capabilities" {
                        return try .json(try await commands.sessionCapabilities(conversationID: components[2]))
                    }
                }
                if components.count == 3, components[0] == "v1", ["assets", "notes"].contains(components[1]) {
                    guard let note = try database.companionNote(id: components[2]) else {
                        return .error("not_found", "This document is no longer available.", status: 404)
                    }
                    return try .json(note)
                }
            } else if request.method == "POST" {
                if path == "/v1/mutations" {
                    let mutation = try JSONDecoder().decode(CompanionMutation.self, from: request.body)
                    guard mutation.deviceID == device.id else { return .error("wrong_device", "Mutation belongs to another device.", status: 403) }
                    let result = try database.applyCompanionMutation(mutation)
                    onMutation()
                    return try .json(result)
                }
                if path == "/v1/commands" {
                    let command = try JSONDecoder().decode(CompanionCommand.self, from: request.body)
                    guard command.deviceID == device.id else { return .error("wrong_device", "Command belongs to another device.", status: 403) }
                    return try .json(try await commands.execute(command, deviceID: device.id))
                }
            }
            return .error("not_found", "Unknown companion endpoint.", status: 404)
        } catch let error as CompanionAPIError {
            let status = error.code == "unauthorized" ? 401 : error.code == "version_mismatch" ? 426 : error.code == "rate_limited" ? 429 : 400
            return .error(error.code, error.message, status: status)
        } catch is DecodingError { return .error("invalid_request", "The request did not match the companion protocol.", status: 400) }
        catch { return .error("workspace_error", "The Mac could not complete this request. Your pending writing is preserved; check the Mac and retry.", status: 500) }
    }
}
