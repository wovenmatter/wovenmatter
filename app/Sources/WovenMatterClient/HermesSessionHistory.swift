import Foundation
import WovenMatterCore

public struct HermesSessionImport: Sendable {
    public let identity: String
    public let title: String
    public let createdAt: Date
    public let messages: [HermesValue]
    public let nativeSnapshot: HermesValue?
    public let nativeSnapshotData: Data?
    public init(identity: String, title: String, createdAt: Date, messages: [HermesValue], nativeSnapshot: HermesValue? = nil,
                nativeSnapshotData: Data? = nil) {
        self.identity = identity; self.title = title; self.createdAt = createdAt; self.messages = messages
        self.nativeSnapshot = nativeSnapshot
        self.nativeSnapshotData = nativeSnapshotData
    }

    public func nativeArchiveBatch() throws -> WorkspaceNativeRunRecordBatch {
        let parsed = HermesGatewayClient.parseIdentity(identity)
        var records = try messages.map { row in
            let bytes = try NativeHarnessArchive.encode(row)
            let id = row["id"].number.flatMap { Int64(exactly: $0) }.map(String.init) ?? NativeHarnessArchive.digest(bytes)
            return NativeHarnessArchive.record(id: "message:" + id, kind: "message", data: bytes, completeness: "native-export")
        }
        if let nativeSnapshot {
            records.append(NativeHarnessArchive.record(id: "session.export", kind: "session",
                data: try nativeSnapshotData ?? NativeHarnessArchive.encode(nativeSnapshot), completeness: "native-export"))
        }
        return WorkspaceNativeRunRecordBatch(sourceID: "hermes:" + (parsed.home ?? "unresolved-profile"),
            nativeSessionID: parsed.storedID, records: records)
    }
}

public enum HermesSessionHistory {
    /// Native export includes durable row IDs, full tool results and original metadata.
    /// The RPC display history intentionally omits some of these fields.
    public static func load(connection: HermesGatewayConnection, sessionID: String) async throws -> HermesSessionImport {
        guard !sessionID.isEmpty, let segment = sessionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            throw HermesGatewayError.message("Invalid Hermes session ID.")
        }
        let raw = try await fetchData(connection: connection, path: "/api/sessions/" + segment + "/export", maximumResponseBytes: 64 * 1_024 * 1_024)
        let snapshot = try HermesValue.decode(raw)
        guard snapshot["id"].text == sessionID, case .array(let messages) = snapshot["messages"] else {
            throw HermesGatewayError.message("Hermes returned a different or incomplete session export.")
        }
        var ids: Set<Double> = []
        for message in messages {
            guard let id = message["id"].number, id >= 1, id <= 9_007_199_254_740_991, id.rounded() == id, ids.insert(id).inserted else {
                throw HermesGatewayError.message("Hermes export is missing unique message identities.")
            }
        }
        return HermesSessionImport(identity: HermesGatewayClient.identity(home: connection.identityHome, storedID: sessionID, imported: true),
            title: snapshot["title"].string ?? "Hermes conversation",
            createdAt: Date(timeIntervalSince1970: snapshot["started_at"].number ?? Date().timeIntervalSince1970), messages: messages,
            nativeSnapshot: snapshot, nativeSnapshotData: raw)
    }
    public static func fetch(connection: HermesGatewayConnection, path: String, method: String = "GET", body: HermesValue? = nil,
                             maximumResponseBytes: Int? = 32 * 1_024 * 1_024) async throws -> HermesValue {
        try HermesValue.decode(await fetchData(connection: connection, path: path, method: method, body: body,
            maximumResponseBytes: maximumResponseBytes))
    }

    private static func fetchData(connection: HermesGatewayConnection, path: String, method: String = "GET", body: HermesValue? = nil,
                                  maximumResponseBytes: Int? = 32 * 1_024 * 1_024) async throws -> Data {
        guard (1...65535).contains(connection.port), path.hasPrefix("/api/"), !path.contains("..") else {
            throw HermesGatewayError.message("Invalid Hermes request.")
        }
        let url = URL(string: "http://127.0.0.1:\(connection.port)" + connection.apiPrefix + path)!
        var request = URLRequest(url: url)
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        request.httpMethod = method
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.timeoutInterval = 45
        let session = URLSession(configuration: .ephemeral, delegate: NativeArchiveDownloadDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw HermesGatewayError.message("Hermes could not complete the request. Its existing state has not been changed.")
        }
        var data = Data()
        for try await byte in bytes {
            if let maximumResponseBytes, data.count >= maximumResponseBytes {
                throw HermesGatewayError.message("Hermes response exceeds the bounded import limit. Its native session remains available; retry archive synchronization or import a smaller session.")
            }
            data.append(byte)
        }
        return data
    }

}
