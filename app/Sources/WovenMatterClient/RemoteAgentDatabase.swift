import Foundation
import WovenMatterCore

public struct RemoteAgentDatabase: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let revision: Int64
    public let updatedAt: String
    public let owner: String
}

struct RemoteDatabaseFailure: Decodable { let error: String }
