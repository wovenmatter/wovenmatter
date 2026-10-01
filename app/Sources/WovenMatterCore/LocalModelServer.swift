import Foundation

public struct LocalModelServer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var url: String
    public var models: [String]
    public var verifiedAt: Date
    public init(id: String = "local-server-" + UUID().uuidString.lowercased(), url: String, models: [String], verifiedAt: Date = .now) {
        self.id = id; self.url = url; self.models = models; self.verifiedAt = verifiedAt
    }
    public var name: String { URL(string: url)?.host ?? "Local Model Server" }
}
