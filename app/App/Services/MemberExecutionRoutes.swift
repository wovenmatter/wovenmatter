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
    /// `PUT execution/attachments/<sha256>?name=&mimeType=`.
    func uploadAttachment(_ data: Data, sha256: String, name: String, mimeType: String) async throws -> LibraryAttachmentReference
    /// `GET execution/providers/<id>/options`: `SessionSettings` with an empty `conversationID`.
    func sessionOptions(providerID: String, workingDirectory: String?, model: String?) async throws -> SessionSettings
    /// `POST execution/library-file`.
    func libraryFile(conversationID: String?, path: String) async throws -> MemberLibraryFile
    /// `GET execution`: the workspace as its host describes it now.
    func descriptor() async throws -> ExecutionWorkspace
    /// `POST default-agent/control-sessions` and its `GET`, `DELETE` and `answer`.
    func startDefaultAgentControl(_ request: Data) async throws -> DefaultAgentControlSession
    func defaultAgentControl(id: String) async throws -> DefaultAgentControlSession
    func answerDefaultAgentControl(id: String, answerTo: String, answer: String) async throws -> DefaultAgentControlSession
    func cancelDefaultAgentControl(id: String) async throws
    /// `GET sign-ins`: the host's own accounts and local model servers (no secrets).
    func signIns() async throws -> DeviceSignIns
    /// `POST sign-ins`: one change, saved only on the host.
    func changeSignIns(_ change: DeviceSignInChange) async throws -> DeviceSignIns
    /// `POST projects`: a blank directory in the host's managed workspace
    /// root, for a new folder. The host refuses a name that is already there.
    func createProject(name: String) async throws -> RemoteProjectDirectory
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
        catch let error as MemberSignedHTTPError { throw Self.refusal(error) }
    }

    private static func refusal(_ error: MemberSignedHTTPError) -> any Error {
        switch error {
        case .http(let status, let code, let message):
            if status == 401 { return MobileConnectionError.revoked }
            // The server names some refusals (`unlock_refused`) and words others.
            let named = code.flatMap { value in value.count <= 64 && value.allSatisfy({ $0.isLowercase || $0 == "_" }) ? value : nil }
            return LibraryAPIError(code: named ?? "http_\(status)", message: message)
        case .insecureEndpoint: return MobileConnectionError.insecureEndpoint
        case .invalidResponse, .responseTooLarge: return MobileConnectionError.invalidResponse
        }
    }

    func uploadAttachment(_ data: Data, sha256: String, name: String, mimeType: String) async throws -> LibraryAttachmentReference {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw MobileConnectionError.invalidResponse }
        return try await member("execution/attachments/" + sha256, method: "PUT",
            query: [.init(name: "name", value: name), .init(name: "mimeType", value: mimeType)], body: data,
            headers: ["Content-Type": "application/octet-stream"], timeout: 300)
    }

    func sessionOptions(providerID: String, workingDirectory: String?, model: String?) async throws -> SessionSettings {
        var query: [URLQueryItem] = []
        if let workingDirectory { query.append(.init(name: "workingDirectory", value: workingDirectory)) }
        if let model { query.append(.init(name: "model", value: model)) }
        return try await member("execution/providers/" + Self.safeID(providerID) + "/options", query: query, timeout: 90)
    }

    func libraryFile(conversationID: String?, path: String) async throws -> MemberLibraryFile {
        var body: [String: String] = ["path": path]
        if let conversationID { body["conversationID"] = conversationID }
        return try await member("execution/library-file", method: "POST",
            body: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), timeout: 120)
    }

    func descriptor() async throws -> ExecutionWorkspace {
        try await member("execution")
    }

    func startDefaultAgentControl(_ request: Data) async throws -> DefaultAgentControlSession {
        try await member("default-agent/control-sessions", method: "POST", body: request)
    }

    func defaultAgentControl(id: String) async throws -> DefaultAgentControlSession {
        try await member("default-agent/control-sessions/" + Self.safeID(id))
    }

    func answerDefaultAgentControl(id: String, answerTo: String, answer: String) async throws -> DefaultAgentControlSession {
        try await member("default-agent/control-sessions/" + Self.safeID(id) + "/answer", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["answerTo": answerTo, "answer": answer], options: [.sortedKeys]))
    }

    func cancelDefaultAgentControl(id: String) async throws {
        let _: JSONValue = try await member("default-agent/control-sessions/" + Self.safeID(id), method: "DELETE")
    }

    func signIns() async throws -> DeviceSignIns {
        try await member("sign-ins")
    }

    func changeSignIns(_ change: DeviceSignInChange) async throws -> DeviceSignIns {
        // A local model server check can take two 20-second requests on the host.
        try await member("sign-ins", method: "POST", body: JSONEncoder().encode(change), timeout: 60)
    }

    func createProject(name: String) async throws -> RemoteProjectDirectory {
        do {
            return try await client.request("projects", method: "POST",
                body: JSONSerialization.data(withJSONObject: ["name": name, "reuseExisting": false], options: [.sortedKeys]))
        } catch MemberSignedHTTPError.http(status: 500, let code, let message) {
            // The host words what it refuses: 400 for a name it does not
            // allow, 409 for one already there. A 500 is a directory it could
            // not make (no space, no permission, no workspace root). Its own
            // words are kept; a bare code or an empty answer says none of that.
            let wordless = message == code || message == MemberSignedHTTPError.unexplained(status: 500)
            throw LibraryAPIError(code: "http_500", message: wordless
                ? "The host could not create this directory. Check its free space and permissions."
                : message)
        } catch let error as MemberSignedHTTPError { throw Self.refusal(error) }
    }
}
