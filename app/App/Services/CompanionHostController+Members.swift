import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

extension CompanionHostController {
    /// This Mac's member signer: the same key as its paired-Mac identity.
    func memberSigner() async throws -> MemberRequestSigner {
        try await peerSync.members().identity.signer
    }

    /// Signed administration of any Linux host in the registry, whichever Mac
    /// added it. Nothing is issued to this Mac; the host verifies each request.
    func hostAdministration(for workspace: CompanionExecutionWorkspace) async throws -> RemoteHostAdministrationClient {
        guard workspace.kind == .linux, !workspace.deleted, let endpoint = workspace.endpoint else {
            throw CompanionAPIError(code: "workspace_unavailable", message: "\(workspace.name)'s address has not reached this Mac yet.")
        }
        return try RemoteHostAdministrationClient(endpoint: endpoint, signer: try await memberSigner(), send: remoteHostSend)
    }

    /// A delegated device grant issued by the Linux host itself, so enrolling a
    /// phone never needs the Mac that added the host.
    func provisionAtLinuxHost(_ workspace: CompanionExecutionWorkspace, deviceID: String, name: String) async throws -> CompanionExecutionCredential {
        let credential = try await hostAdministration(for: workspace).provisionExecutionDevice(workspace: workspace, deviceID: deviceID, name: name)
        guard credential.deviceID == deviceID, credential.workspace.id == workspace.id, credential.workspace.libraryID == workspace.libraryID else {
            throw CompanionAPIError(code: "wrong_workspace", message: "The workspace returned an execution grant for a different identity.")
        }
        return credential
    }
}
