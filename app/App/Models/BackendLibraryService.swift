import Foundation
import WovenMatterCore
import WovenMatterClient
import WovenMatterLibraryStore

/// Content identities and display metadata cross the boundary. The execution owner
/// resolves retained files and creates opening copies; the UI reads the shared catalog.
enum BackendLibraryCommand: Codable, Sendable {
    case open(id: String)
    case openSavedArtifact(id: String, revision: Int64)
    /// `remoteConversationID` names a session another machine runs, whose file
    /// this Mac reads from that machine the first time it opens.
    case openAttachment(contentHash: String, fileName: String, mimeType: String, remoteConversationID: String? = nil)
    case retry(id: String)
}

struct BackendLibraryResult: Codable, Sendable {
    var url: URL?
}

struct BackendLibraryService: Sendable {
    /// Reads a message file from the machine that runs its session
    /// (`GET v1/execution/attachments/<sha256>`), checked against its digest.
    typealias RemoteAttachment = @Sendable (_ conversationID: String, _ reference: LibraryAttachmentReference) async throws -> Data
    let service: LibraryService
    var remoteAttachment: RemoteAttachment?

    func execute(_ command: BackendLibraryCommand) async throws -> BackendLibraryResult {
        switch command {
        case let .openSavedArtifact(id, revision):
            return try await .init(url: service.openSavedArtifactURL(id: id, revision: revision))
        case let .open(id): return try await .init(url: service.openURL(id: id))
        case let .openAttachment(contentHash, fileName, mimeType, conversationID?):
            guard let remoteAttachment else { throw BackendRPCError.remote("This file is on the machine that runs its session.") }
            let reference = LibraryAttachmentReference(id: contentHash, name: fileName, mimeType: mimeType)
            return try await .init(url: service.openAttachmentURL(contentHash: contentHash, fileName: fileName, mimeType: mimeType) {
                try await remoteAttachment(conversationID, reference)
            })
        case let .openAttachment(contentHash, fileName, mimeType, nil):
            return try await .init(url: service.openAttachmentURL(
                contentHash: contentHash, fileName: fileName, mimeType: mimeType))
        case let .retry(id):
            try await service.retry(id: id)
            return .init()
        }
    }
}
