import Foundation
import WovenMatterDashboardStore

/// Content identities and display metadata cross the boundary. The execution owner
/// resolves retained files and creates opening copies; the UI reads the shared catalog.
enum BackendLibraryCommand: Codable, Sendable {
    case open(id: String)
    case openAttachment(contentHash: String, fileName: String, mimeType: String)
    case retry(id: String)
}

struct BackendLibraryResult: Codable, Sendable {
    var url: URL?
}

struct BackendLibraryService: Sendable {
    let service: LibraryService

    func execute(_ command: BackendLibraryCommand) async throws -> BackendLibraryResult {
        switch command {
        case let .open(id): return try await .init(url: service.openURL(id: id))
        case let .openAttachment(contentHash, fileName, mimeType):
            return try await .init(url: service.openAttachmentURL(
                contentHash: contentHash, fileName: fileName, mimeType: mimeType))
        case let .retry(id):
            try await service.retry(id: id)
            return .init()
        }
    }
}
