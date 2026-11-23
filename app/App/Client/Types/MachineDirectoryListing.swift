import Foundation

/// One directory on a machine and the directories inside it.
struct MachineDirectoryListing: Equatable, Sendable {
    struct Directory: Identifiable, Equatable, Sendable {
        let name: String
        let path: String
        var id: String { path }
    }

    let path: String
    let parent: String?
    let directories: [Directory]
    /// More directories exist than were listed.
    let truncated: Bool
}
