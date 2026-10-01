import Foundation
import WovenMatterDashboardStore

/// Only identities cross the boundary. The execution owner resolves retained files
/// and creates opening copies; the UI continues reading the shared catalog directly.
enum BackendLibraryCommand: Codable, Sendable {
    case open(id: String)
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
        case let .retry(id):
            try await service.retry(id: id)
            return .init()
        }
    }
}
