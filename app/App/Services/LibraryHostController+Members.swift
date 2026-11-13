import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterLibraryStore

extension LibraryHostController {
    /// This Mac's member signer: the same key as its paired-Mac identity.
    func memberSigner() async throws -> MemberRequestSigner {
        try await peerSync.members().identity.signer
    }

    /// Signed administration of any Linux host in the registry, whichever Mac
    /// added it. Nothing is issued to this Mac; the host verifies each request.
    func hostAdministration(for workspace: ExecutionWorkspace) async throws -> RemoteHostAdministrationClient {
        let directory = try await peerSync.members()
        guard workspace.kind == .linux, !workspace.deleted, let endpoint = workspace.endpoint, let host = await directory.audience(for: workspace) else {
            throw LibraryAPIError(code: "workspace_unavailable", message: "\(workspace.name)'s address or member identity has not reached this Mac yet.")
        }
        return try RemoteHostAdministrationClient(endpoint: endpoint, signer: directory.identity.signer, audience: host, send: remoteHostSend)
    }

    /// A delegated device grant issued by the Linux host itself, so enrolling a
    /// phone never needs the Mac that added the host.
    func provisionAtLinuxHost(_ workspace: ExecutionWorkspace, deviceID: String, name: String) async throws -> ExecutionCredential {
        let credential = try await hostAdministration(for: workspace).provisionExecutionDevice(workspace: workspace, deviceID: deviceID, name: name)
        guard credential.deviceID == deviceID, credential.workspace.id == workspace.id, credential.workspace.libraryID == workspace.libraryID else {
            throw LibraryAPIError(code: "wrong_workspace", message: "The workspace returned an execution grant for a different identity.")
        }
        return credential
    }
}
