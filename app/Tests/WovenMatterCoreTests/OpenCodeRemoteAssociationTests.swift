import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct OpenCodeRemoteAssociationTests {
    @Test func sameServiceSessionIDStaysIndependentAcrossWorkspacesAndCannotCrossBind() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let owner = UUID(), firstHost = UUID(), secondHost = UUID()
        let firstIdentity = "remote-workspace:" + firstHost.uuidString.lowercased()
        let secondIdentity = "remote-workspace:" + secondHost.uuidString.lowercased()
        let first = try await database.createRemoteACPSession(runtimeKind: .opencode, remoteWorkspaceID: firstHost,
            remoteWorkspaceName: "First", title: "First session", ownerDeviceID: owner,
            openCodeAssociation: (firstIdentity, "ses_same"))
        let second = try await database.createRemoteACPSession(runtimeKind: .opencode, remoteWorkspaceID: secondHost,
            remoteWorkspaceName: "Second", title: "Second session", ownerDeviceID: owner,
            openCodeAssociation: (secondIdentity, "ses_same"))
        #expect(first != second)
        let reopened = try await database.createRemoteACPSession(runtimeKind: .opencode, remoteWorkspaceID: firstHost,
            remoteWorkspaceName: "First", title: "Ignored duplicate", ownerDeviceID: owner,
            openCodeAssociation: (firstIdentity, "ses_same"))
        #expect(reopened == first)
        #expect(try await database.openCodeLinks().count == 2)
        #expect(try await database.localACPSession(conversationID: first).remoteWorkspaceID == firstHost)
        #expect(try await database.localACPSession(conversationID: second).remoteWorkspaceID == secondHost)
        await #expect(throws: (any Error).self) {
            try await database.createRemoteACPSession(runtimeKind: .opencode, remoteWorkspaceID: firstHost,
                remoteWorkspaceName: "First", title: "Wrong host", ownerDeviceID: owner,
                openCodeAssociation: (secondIdentity, "ses_other"))
        }
        #expect(try await database.openCodeLinks().count == 2)
    }
}
