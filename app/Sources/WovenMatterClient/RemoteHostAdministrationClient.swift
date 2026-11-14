import Foundation
import WovenMatterCore

/// Administration of a Linux host by any Mac member, as signed requests to
/// its server's `/v1/host/*` routes over the host's private tailnet address
/// (docs/architecture/WOVEN_EVERYWHERE.md, "Membership and device keys").
/// Only first install needs Tailscale SSH from the Mac that adds the machine.
public struct RemoteHostAdministrationClient: Sendable {
    private let client: MemberSignedHTTPClient

    /// `endpoint` is the host's execution endpoint, such as
    /// `https://host.tailnet.ts.net/wovenmatter-execution/<id>`, and `audience`
    /// the host's member device ID (the registry's `executionDeviceID`).
    public init(endpoint: URL, signer: MemberRequestSigner, audience: String, send: MemberSignedHTTPClient.Send? = nil) throws {
        client = try MemberSignedHTTPClient(endpoint: endpoint, signer: signer, audience: audience, send: send)
    }

    /// `remote-host.sh status` plus `library` and `memberIdentity`.
    public func status() async throws -> JSONValue {
        try await client.request("v1/host/status", timeout: 60)
    }

    public func logs(lines: Int = 200) async throws -> String {
        guard (1...1_000).contains(lines) else { throw RemoteWorkspaceClientError.invalidResponse("Choose between 1 and 1,000 log lines.") }
        let value: JSONValue = try await client.request("v1/host/logs", query: [.init(name: "lines", value: String(lines))], timeout: 60)
        return value.objectValue?["logs"]?.stringValue ?? ""
    }

    /// Accepted with 202; the host restarts its service a moment later.
    public func restart() async throws {
        let _: JSONValue = try await client.request("v1/host/restart", method: "POST")
    }

    /// Bytes, or nil for no cap.
    public func configureBots(poolBytes: Int64?, diskBytes: Int64?) async throws -> JSONValue {
        let body: [String: Any] = ["poolBytes": poolBytes.map { $0 as Any } ?? NSNull(), "diskBytes": diskBytes.map { $0 as Any } ?? NSNull()]
        return try await client.request("v1/host/bots-configure", method: "POST", body: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
    }

    /// Uploads a host bundle; the host verifies it against `fingerprint` and
    /// updates in its own transient unit (202). Poll `updateState()`.
    public func update(bundle: Data, fingerprint: String, roles: String? = nil) async throws {
        var query = [URLQueryItem(name: "fingerprint", value: fingerprint)]
        if let roles { query.append(.init(name: "roles", value: roles)) }
        let _: JSONValue = try await client.request("v1/host/update", method: "POST", query: query, body: bundle,
            headers: ["Content-Type": "application/octet-stream"], timeout: 600)
    }

    /// `{state: none|running|succeeded|failed, result?, error?}`.
    public func updateState() async throws -> JSONValue {
        try await client.request("v1/host/update")
    }

    /// Replaces the host's installer bearer, so a removed Mac that installed it
    /// can no longer administer it over Tailscale SSH. The new value is never
    /// sent to a signed caller.
    public func rotateInstallerBearer() async throws {
        let _: JSONValue = try await client.request("v1/host/installer-bearer", method: "POST")
    }

    /// Hands the host the signed member records (`LibraryMemberAdoption`).
    public func adoptMembers(_ adoption: Data) async throws -> JSONValue {
        try await client.request("v1/host/members/adopt", method: "POST", body: adoption)
    }

    /// The bundle a signed update uploads, built from this Mac's own app as an
    /// SSH install would, and its deployment fingerprint.
    public static func hostBundle(root: URL? = nil) throws -> (bundle: Data, fingerprint: String) {
        let root = try root ?? RemoteWorkspaceSSHClient.loadDeploymentRoot()
        try RemoteHostLibrary.require(root: root, architecture: nil)
        let deployment = try RemoteWorkspaceDeployment(root: root)
        return (try RemoteHostBundle.archive(root: root, deployment: deployment), deployment.fingerprint)
    }
}
