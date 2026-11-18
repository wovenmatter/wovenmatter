import Foundation
import LibraryClient
import WovenMatterCore
import WovenMatterClient

/// The Linux server's member routes beyond the shared execution transport
/// (docs/architecture/WOVEN_EVERYWHERE.md, "Linux sessions"): message files,
/// options before a session exists, Library file retention, adoption and Pi
/// Durable's unlock and settings. A Mac reaches every one with its member
/// signature; signed Macs administer the host as its installer bearer does.
protocol MemberExecutionRoutes: Sendable {
    /// `PUT v1/execution/attachments/<sha256>?name=&mimeType=`.
    func uploadAttachment(_ data: Data, sha256: String, name: String, mimeType: String) async throws -> LibraryAttachmentReference
    /// `GET v1/execution/providers/<id>/options`: `SessionSettings` with an empty `conversationID`.
    func sessionOptions(providerID: String, workingDirectory: String?, model: String?) async throws -> SessionSettings
    /// `POST v1/execution/library-file`.
    func libraryFile(conversationID: String?, path: String) async throws -> MemberLibraryFile
    /// `POST v1/execution/adopt`, with the transcript this Mac already shows.
    func adopt(_ body: Data) async throws
    /// `POST v1/default-agent/unlock`; false when the host refused the key.
    func unlockDefaultAgent(workspace: String, unlockKey: String) async throws -> Bool
    /// `POST v1/default-agent/configuration`, for a host that was never configured.
    func configureDefaultAgent(_ payload: Data) async throws -> DefaultAgentSyncReceipt
    /// `POST v1/default-agent/control-sessions` and its `GET`, `DELETE` and `answer`.
    func startDefaultAgentControl(_ request: Data) async throws -> DefaultAgentControlSession
    func defaultAgentControl(id: String) async throws -> DefaultAgentControlSession
    func answerDefaultAgentControl(id: String, answerTo: String, answer: String) async throws -> DefaultAgentControlSession
    func cancelDefaultAgentControl(id: String) async throws
    /// `GET v1/sign-ins`: the host's own accounts and local model servers (no secrets).
    func signIns() async throws -> DeviceSignIns
    /// `POST v1/sign-ins`: one change, saved only on the host.
    func changeSignIns(_ change: DeviceSignInChange) async throws -> DeviceSignIns
}

/// A file an agent wrote on the host, read for Library retention.
struct MemberLibraryFile: Codable, Equatable, Sendable {
    var name: String
    var mimeType: String
    var byteCount: Int64
    var sha256: String
    /// Base64.
    var data: String
}

/// One run of Pi Durable's settings helper on a host: its sign-in
/// `notifications`, a `prompt` to answer, then its `result` or `error`.
struct DefaultAgentControlSession: Decodable, Sendable {
    var id: String
    var state: String
    var notifications: [JSONValue]
    var prompt: JSONValue?
    var result: JSONValue?
    var error: String?
    var promptID: String? { prompt?.objectValue?["id"]?.stringValue }

    /// The helper's own output lines, as the SSH launcher delivered them:
    /// the notifications after `seen`, the prompt, then the terminal line.
    func lines(after seen: Int) -> [Data] {
        var values: [JSONValue] = notifications.dropFirst(seen).map { .object(["notification": $0]) }
        if let prompt, var body = prompt.objectValue, let id = body.removeValue(forKey: "id") {
            values.append(.object(["id": id, "prompt": .object(body)]))
        }
        if state == "succeeded" { values.append(.object(["result": result ?? .object([:])])) }
        if state == "failed" { values.append(.object(["error": .string(error ?? "Pi Durable settings did not complete on this workspace.")])) }
        return values.compactMap { try? JSONEncoder().encode($0) }
    }
}

/// A host's Pi Durable vault is its own and always open: only a host from before
/// per-device sign-ins reports itself locked. It is unlocked with that host's
/// own vault key (the Keychain's `encryption-key` for the workspace scope), so
/// it keeps what it already holds. No credential is ever sent to it.
enum DefaultAgentHostUnlock {
    static func unlock(scope: String, name: String, routes: any MemberExecutionRoutes,
                       existingKey: @Sendable (String) throws -> String? = { try DefaultAgentSupport.key("encryption-key", scope: $0) }) async throws {
        if let key = try existingKey(scope), !key.isEmpty, try await routes.unlockDefaultAgent(workspace: scope, unlockKey: key) { return }
        throw LibraryAPIError(code: MemberExecutionClient.defaultAgentLocked, message: "Pi Durable is locked on \(name). Open Woven Matter on the Mac that set it up.")
    }
}

/// What this Mac sends a Linux host's Pi Durable. Never a provider credential,
/// an account list or borrowed access, whatever the host reports.
enum DefaultAgentHostSync {
    struct Plan {
        /// Chat settings (`v1/default-agent/configuration`), for a host that keeps its own sign-ins.
        var configuration: DefaultAgentPayload?
        /// That host's own vault key (`v1/default-agent/unlock`), for a host from
        /// before per-device sign-ins: it stays unlocked with what it holds.
        var unlockKey: String?
    }
    static func plan(scope: String, vault: DefaultAgentHostVault, settingsOnly: DefaultAgentPayload,
                     vaultKey: @Sendable (String) async throws -> String? = { scope in
                         try await ProviderConnectionStore.shared.perform(invalidatesAccounts: false) { try DefaultAgentSupport.key("encryption-key", scope: scope) }
                     }) async throws -> Plan {
        let key = try await vaultKey(scope).flatMap { $0.isEmpty ? nil : $0 }
        if vault.isLegacy { return Plan(configuration: nil, unlockKey: key) }
        var payload = DefaultAgentPayload(config: settingsOnly.config, credentials: [:], workspace: settingsOnly.workspace)
        payload.revision = settingsOnly.revision
        // Once, to open a vault sealed with this Mac's key that waits there.
        if vault.legacyVault == true { payload.unlockKey = key }
        return Plan(configuration: payload, unlockKey: nil)
    }
    /// Once the host keeps its own vault and nothing there waits for this Mac's key,
    /// what this Mac kept for that workspace is moved aside (never deleted).
    static func acknowledged(_ receipt: DefaultAgentSyncReceipt, scope: String,
                             forget: @Sendable (String) async throws -> Void = { scope in
                                 try await ProviderConnectionStore.shared.perform { try ProviderConnectionAccounts.setAsideHostCopies(scope: scope) }
                             }) async {
        guard receipt.deviceVault == true, receipt.legacyVault != true else { return }
        try? await forget(scope)
    }
}

/// Message files sent to a Linux host: 25 MiB each, eight and 50 MiB per message.
enum MemberAttachmentLimits {
    static let fileBytes = 25 * 1_024 * 1_024
    static let files = 8
    static let messageBytes = 50 * 1_024 * 1_024

    static func check(_ attachments: [AgentFileAttachmentDraft]) throws {
        guard attachments.count <= files else {
            throw LibraryAPIError(code: "attachment_unavailable", message: "Send at most \(files) files in one message to this workspace.")
        }
        var total: Int64 = 0
        for attachment in attachments {
            guard attachment.sizeBytes <= Int64(fileBytes) else {
                throw LibraryAPIError(code: "attachment_unavailable", message: "\(attachment.fileName) is larger than 25 MB. Send a smaller file.")
            }
            total += attachment.sizeBytes
        }
        guard total <= Int64(messageBytes) else {
            throw LibraryAPIError(code: "attachment_unavailable", message: "These files are larger than 50 MB together. Send fewer or smaller files.")
        }
    }
}

extension SignedExecutionWorkspaceTransport: MemberExecutionRoutes {
    /// A refusal keeps its status and code: a locked vault or a refused key is
    /// not a revoked membership.
    private func member<Value: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
                                          headers: [String: String] = [:], timeout: TimeInterval = 30) async throws -> Value {
        do { return try await client.request(path, method: method, query: query, body: body, headers: headers, timeout: timeout) }
        catch let error as MemberSignedHTTPError {
            switch error {
            case .http(let status, let code, let message):
                if status == 401 { throw MobileConnectionError.revoked }
                // The server names some refusals (`unlock_refused`) and words others.
                let named = code.flatMap { value in value.count <= 64 && value.allSatisfy({ $0.isLowercase || $0 == "_" }) ? value : nil }
                throw LibraryAPIError(code: named ?? "http_\(status)", message: message)
            case .insecureEndpoint: throw MobileConnectionError.insecureEndpoint
            case .invalidResponse, .responseTooLarge: throw MobileConnectionError.invalidResponse
            }
        }
    }

    func uploadAttachment(_ data: Data, sha256: String, name: String, mimeType: String) async throws -> LibraryAttachmentReference {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw MobileConnectionError.invalidResponse }
        return try await member("v1/execution/attachments/" + sha256, method: "PUT",
            query: [.init(name: "name", value: name), .init(name: "mimeType", value: mimeType)], body: data,
            headers: ["Content-Type": "application/octet-stream"], timeout: 300)
    }

    func sessionOptions(providerID: String, workingDirectory: String?, model: String?) async throws -> SessionSettings {
        var query: [URLQueryItem] = []
        if let workingDirectory { query.append(.init(name: "workingDirectory", value: workingDirectory)) }
        if let model { query.append(.init(name: "model", value: model)) }
        return try await member("v1/execution/providers/" + Self.safeID(providerID) + "/options", query: query, timeout: 90)
    }

    func libraryFile(conversationID: String?, path: String) async throws -> MemberLibraryFile {
        var body: [String: String] = ["path": path]
        if let conversationID { body["conversationID"] = conversationID }
        return try await member("v1/execution/library-file", method: "POST",
            body: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), timeout: 120)
    }

    func adopt(_ body: Data) async throws {
        let _: JSONValue = try await member("v1/execution/adopt", method: "POST", body: body, timeout: 120)
    }

    func unlockDefaultAgent(workspace: String, unlockKey: String) async throws -> Bool {
        struct Reply: Decodable { var unlocked: Bool }
        do {
            let reply: Reply = try await member("v1/default-agent/unlock", method: "POST",
                body: JSONSerialization.data(withJSONObject: ["workspace": workspace, "unlockKey": unlockKey], options: [.sortedKeys]))
            return reply.unlocked
        } catch let error as LibraryAPIError where error.code == "unlock_refused" { return false }
    }

    func configureDefaultAgent(_ payload: Data) async throws -> DefaultAgentSyncReceipt {
        try await member("v1/default-agent/configuration", method: "POST", body: payload, timeout: 120)
    }

    func startDefaultAgentControl(_ request: Data) async throws -> DefaultAgentControlSession {
        try await member("v1/default-agent/control-sessions", method: "POST", body: request)
    }

    func defaultAgentControl(id: String) async throws -> DefaultAgentControlSession {
        try await member("v1/default-agent/control-sessions/" + Self.safeID(id))
    }

    func answerDefaultAgentControl(id: String, answerTo: String, answer: String) async throws -> DefaultAgentControlSession {
        try await member("v1/default-agent/control-sessions/" + Self.safeID(id) + "/answer", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["answerTo": answerTo, "answer": answer], options: [.sortedKeys]))
    }

    func cancelDefaultAgentControl(id: String) async throws {
        let _: JSONValue = try await member("v1/default-agent/control-sessions/" + Self.safeID(id), method: "DELETE")
    }

    func signIns() async throws -> DeviceSignIns {
        try await member("v1/sign-ins")
    }

    func changeSignIns(_ change: DeviceSignInChange) async throws -> DeviceSignIns {
        // A local model server check can take two 20-second requests on the host.
        try await member("v1/sign-ins", method: "POST", body: JSONEncoder().encode(change), timeout: 60)
    }
}
