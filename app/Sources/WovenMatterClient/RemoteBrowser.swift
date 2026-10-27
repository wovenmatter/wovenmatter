import Foundation

public struct RemoteBrowserTab: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public init(id: String, title: String, url: String) { self.id = id; self.title = title; self.url = url }
}

public struct RemoteBrowserTabs: Codable, Equatable, Sendable {
    public let running: Bool
    public let tabs: [RemoteBrowserTab]
    public let profiles: [String]?
    public let profile: String?
    public init(running: Bool, tabs: [RemoteBrowserTab], profiles: [String]? = nil, profile: String? = nil) {
        self.running = running; self.tabs = tabs; self.profiles = profiles; self.profile = profile
    }
}

public struct RemoteBrowserSelfTest: Codable, Equatable, Sendable {
    public let ok: Bool
    public let reason: String?
    public let missingLibraries: [String]?
    public let hint: String?

    public init(ok: Bool, reason: String? = nil, missingLibraries: [String]? = nil, hint: String? = nil) {
        self.ok = ok; self.reason = reason; self.missingLibraries = missingLibraries; self.hint = hint
    }
}

public struct RemoteBrowserFrame: Codable, Equatable, Sendable {
    public let tabID: String
    public let imageBase64: String
    public let frameID: String?
    public let imageID: String?
    public init(tabID: String, imageBase64: String, frameID: String? = nil, imageID: String? = nil) {
        self.tabID = tabID; self.imageBase64 = imageBase64; self.frameID = frameID; self.imageID = imageID
    }
}

/// An explicit user gesture, bound to the page image the user actually saw.
public struct RemoteBrowserAction: Codable, Equatable, Sendable {
    public var actionID = UUID().uuidString.lowercased()
    public var tabID = ""
    public var frameID = ""
    public var gestureID: String?
    public var kind: String
    public var x: Double?
    public var y: Double?
    public var endX: Double?
    public var endY: Double?
    public var deltaX: Double?
    public var deltaY: Double?
    public var button: String?
    public var clickCount: Int?
    public var modifiers: Int?
    public var key: String?
    public var text: String?
    public init(kind: String) { self.kind = kind }
}

public struct RemoteBrowserActionResult: Codable, Sendable {
    public let tabID: String
    public let accepted: Bool
    public let text: String?
    public init(tabID: String, accepted: Bool, text: String? = nil) { self.tabID = tabID; self.accepted = accepted; self.text = text }
}

public struct RemoteBrowserActionBatchResult: Codable, Sendable {
    public let results: [RemoteBrowserActionResult]
    public init(results: [RemoteBrowserActionResult]) { self.results = results }
}

/// Bounded streaming parser. Only the newest frame waits for the consumer.
final class RemoteBrowserStreamDecoder: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<RemoteBrowserFrame, any Error>.Continuation
    private var buffer = Data()
    private var lastImage: String?
    init(_ continuation: AsyncThrowingStream<RemoteBrowserFrame, any Error>.Continuation) { self.continuation = continuation }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // A workspace stream cannot redirect its credentials to another origin.
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType == "application/x-ndjson" else {
            continuation.finish(throwing: RemoteWorkspaceClientError.invalidResponse("Update or reconnect this workspace to use its live browser."))
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        do {
            while let newline = buffer.firstIndex(of: 10) {
                guard buffer.distance(from: buffer.startIndex, to: newline) <= 3 * 1024 * 1024 else { throw BackendRPCError.invalidFrame }
                let frame = try JSONDecoder().decode(RemoteBrowserFrame.self, from: buffer[..<newline])
                if !frame.imageBase64.isEmpty { lastImage = frame.imageBase64 }
                guard let lastImage else { throw BackendRPCError.invalidFrame }
                continuation.yield(.init(tabID: frame.tabID, imageBase64: lastImage, frameID: frame.frameID, imageID: frame.imageID))
                buffer.removeSubrange(...newline)
            }
            guard buffer.count <= 3 * 1024 * 1024 else { throw BackendRPCError.invalidFrame }
        } catch { continuation.finish(throwing: error); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish(throwing: error ?? URLError(.networkConnectionLost))
        session.finishTasksAndInvalidate()
    }
}
