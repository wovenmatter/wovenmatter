import Foundation
import LibraryClient
import WovenMatterCore
import WovenMatterClient

/// Execution transport to another member's workspace (a paired Mac's
/// `/wovenmatter/v1/execution/*` or a Linux host's Node server behind
/// `/wovenmatter-execution/<id>/`), authenticated by this Mac's member
/// signature. Nothing is provisioned or stored for it, so any Mac reaches any
/// workspace as soon as both are members.
final class SignedExecutionWorkspaceTransport: ExecutionWorkspaceTransport, @unchecked Sendable {
    let workspace: ExecutionWorkspace
    let client: MemberSignedHTTPClient
    private var deviceID: String { client.signer.deviceID }

    /// `audience` is the member that serves the workspace (`MemberDirectory.audience(for:)`);
    /// by default its execution device, which is a Mac's member ID.
    init(workspace: ExecutionWorkspace, signer: MemberRequestSigner, audience: String? = nil,
         send: MemberSignedHTTPClient.Send? = nil) throws {
        guard let endpoint = workspace.endpoint else { throw MobileConnectionError.insecureEndpoint }
        guard let audience = audience ?? workspace.executionDeviceID else { throw MemberRequestError.audienceUnknown }
        self.workspace = workspace
        client = try MemberSignedHTTPClient(endpoint: endpoint, signer: signer, audience: audience, headers: [
            "X-Woven-Protocol": String(LibraryProtocol.version), "X-Woven-Library": workspace.libraryID,
            "X-Woven-Workspace": workspace.id, "X-Woven-Device": signer.deviceID
        ], send: send)
    }

    private func call<Value: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Value {
        do { return try await client.request(path, method: method, query: query, body: body) }
        catch let error as MemberSignedHTTPError {
            switch error {
            case .http(let status, _, _) where status == 401 || status == 403: throw MobileConnectionError.revoked
            case .http(426, _, _): throw MobileConnectionError.versionMismatch
            case .http(let status, _, let message): throw MobileConnectionError.http(status, message)
            case .insecureEndpoint: throw MobileConnectionError.insecureEndpoint
            case .invalidResponse, .responseTooLarge: throw MobileConnectionError.invalidResponse
            }
        }
    }

    func identity() async throws -> ExecutionWorkspace {
        let value: ExecutionWorkspace = try await call("v1/execution")
        guard value.id == workspace.id, value.libraryID == workspace.libraryID else { throw MobileStore.Failure.wrongWorkspace }
        return value
    }
    func providers() async throws -> [HarnessCapabilities] { try await call("v1/execution/providers") }
    func pending() async throws -> [PendingInteraction] { try await call("v1/execution/interactions") }
    func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt {
        guard command.deviceID == deviceID else { throw MobileConnectionError.revoked }
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any] ?? [:]
        value["libraryID"] = workspace.libraryID; value["workspaceID"] = workspace.id
        return try await call("v1/execution/commands", method: "POST", body: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    func receipt(_ id: String) async throws -> LibraryCommandReceipt? {
        do { return try await call("v1/execution/commands/" + Self.safeID(id), query: [.init(name: "deviceID", value: deviceID)]) }
        catch MobileConnectionError.http(404, _) { return nil }
    }
    func events(after: Int64) async throws -> ExecutionJournalPage {
        try await call("v1/execution/events", query: [.init(name: "after", value: String(after))])
    }
    func conversations() async throws -> [LibraryConversation] { try await call("v1/execution/conversations") }
    func transcript(_ id: String) async throws -> LibraryTranscript {
        try await call("v1/execution/conversations/" + Self.safeID(id) + "/transcript")
    }
    func transcript(_ id: String, before: String) async throws -> LibraryTranscript {
        try await call("v1/execution/conversations/" + Self.safeID(id) + "/transcript", query: [.init(name: "before", value: before)])
    }
    func capabilities(_ id: String) async throws -> HarnessCapabilities {
        try await call("v1/execution/conversations/" + Self.safeID(id) + "/capabilities")
    }
    func readWorkspace(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult {
        try await call("v1/execution/workspace-read", method: "POST", body: JSONEncoder().encode(request))
    }

    static func safeID(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 200,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else {
            throw MobileConnectionError.invalidResponse
        }
        return value
    }
}
