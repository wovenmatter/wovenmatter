import Foundation
import WovenMatterCore

/// The WebKit document sees a value projection, never host persistence objects.
struct DashboardArtifactStateSnapshot: Encodable, Equatable {
    var values: [String: GatewayJSONValue]
    var versions: [String: Int]

    init(_ entries: [String: ArtifactStateEntry]) {
        values = entries.compactMapValues(\.value)
        versions = entries.mapValues(\.version)
    }

    init(_ snapshot: ArtifactStateSnapshot) {
        values = snapshot.values
        versions = snapshot.versions
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{\"values\":{},\"versions\":{}}"
    }
}

struct DashboardArtifactStateMessage: Decodable {
    let token: String
    let requestID: String
    let edit: ArtifactStateEdit
    let previousRequestID: String?

    static func decode(_ body: Any, token: String) throws -> Self {
        guard JSONSerialization.isValidJSONObject(body) else { throw ArtifactInputError.invalidMessage }
        let bytes = try JSONSerialization.data(withJSONObject: body)
        guard bytes.count <= 80 * 1_024 else { throw ArtifactInputError.invalidMessage }
        let message = try JSONDecoder().decode(Self.self, from: bytes)
        guard message.token == token, !message.requestID.isEmpty, message.requestID.utf8.count <= 64 else {
            throw ArtifactInputError.invalidMessage
        }
        return message
    }
}

enum ArtifactInputError: LocalizedError {
    case invalidMessage, unavailable, saveFailed
    var errorDescription: String? {
        switch self {
        case .invalidMessage: "This Artifact sent an invalid input-state request."
        case .unavailable: "This Artifact is no longer available for editing."
        case .saveFailed: "Artifact inputs could not be saved. Keep this view open and retry, or recover the document draft."
        }
    }
}
