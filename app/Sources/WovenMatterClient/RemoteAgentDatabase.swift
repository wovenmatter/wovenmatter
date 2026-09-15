import Foundation
import WovenMatterCore

public struct RemoteAgentDatabase: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let preference: AgentDatabasePreference
}

public struct RemoteDatabaseData: Codable, Sendable {
    public let jsonBase64: String?
    public let query: AgentDatabaseQueryResponse?
}

struct RemoteDatabaseRequest: Encodable {
    let databaseID: String
    var preference: AgentDatabasePreference? = nil
    var relativePath: String? = nil
    var sqliteQuery: String? = nil
}

struct RemoteDatabaseFailure: Decodable { let error: String }
