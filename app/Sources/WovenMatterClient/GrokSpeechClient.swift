import Foundation

public enum GrokSpeechError: LocalizedError, Equatable, Sendable {
    case signInRequired, restricted, exhausted, throttled, unavailable, incomplete, audioBacklog
    public var errorDescription: String? {
        switch self {
        case .signInRequired: "Connect or reconnect your Grok subscription in Settings → Connections."
        case .restricted:
            "This Grok subscription does not currently have access to dictation. Check your plan in Connections."
        case .exhausted:
            "Your Grok dictation allowance is exhausted. No API key was used. Check your account usage in Connections."
        case .throttled: "Grok is temporarily limiting dictation requests. Try again shortly."
        case .unavailable: "Grok dictation could not connect. Check your connection and try again."
        case .incomplete: "Grok did not finish the transcription. Your existing text is unchanged."
        case .audioBacklog: "Dictation stopped because the connection could not keep up with the microphone."
        }
    }
    public static func classify(status: Int?, message: String = "") -> Self {
        let text = message.lowercased()
        if status == 401 || text.contains("unauthorized") || text.contains("token_expired") { return .signInRequired }
        if status == 402 || text.contains("quota") || text.contains("exhausted") || text.contains("usage_limit")
            || text.contains("usage limit") || text.contains("insufficient") || text.contains("credit")
        {
            return .exhausted
        }
        if status == 403 || text.contains("subscription") || text.contains("not entitled") { return .restricted }
        if status == 429 || text.contains("rate_limit") { return .throttled }
        return .unavailable
    }
}

public enum GrokSpeechEvent: Equatable, Sendable {
    case ready
    case partial(String)
    case done(String, duration: Double?)
    case failure(GrokSpeechError)
    public static func decode(_ data: Data) throws -> Self? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "transcript.created": return .ready
        case "transcript.partial": return .partial(object["text"] as? String ?? "")
        case "transcript.done": return .done(object["text"] as? String ?? "", duration: object["duration"] as? Double)
        case "error":
            let error = object["error"] as? [String: Any] ?? object
            return .failure(
                .classify(
                    status: error["status"] as? Int,
                    message: [error["code"], error["message"]].compactMap { $0 as? String }.joined(separator: " ")))
        default: return nil
        }
    }
}

/// A native, subscription-only STT socket. No environment keys, model fallback,
/// audio files, or Default Agent/remote process is involved.
public protocol GrokSpeechTransport: Sendable {
    func connect(credential: DefaultAgentCredential) async throws
    func send(_ audio: Data) async throws
    func finish() async throws
    func next(timeout: Duration) async throws -> GrokSpeechEvent?
    func cancel() async
}

public actor GrokSpeechClient: GrokSpeechTransport {
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    public init() {}
    public static func request(credential: DefaultAgentCredential) throws -> URLRequest {
        guard credential.type == "oauth", let token = credential.access, !token.isEmpty else {
            throw GrokSpeechError.signInRequired
        }
        let url = URL(
            string:
                "wss://api.x.ai/v1/stt?model=grok-voice-transcribe-2.0&sample_rate=16000&encoding=pcm&interim_results=true"
        )!
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("wovenmatter", forHTTPHeaderField: "x-grok-client-identifier")
        request.setValue("WovenMatter/Dictation", forHTTPHeaderField: "User-Agent")
        return request
    }
    public func connect(credential: DefaultAgentCredential) async throws {
        let request = try Self.request(credential: credential)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        self.session = session
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        let event = try await next(timeout: .seconds(20))
        if case .failure(let error) = event { throw error }
        guard event == .ready else { throw GrokSpeechError.unavailable }
    }
    public func send(_ audio: Data) async throws {
        guard let socket else { throw CancellationError() }
        try await socket.send(.data(audio))
    }
    public func finish() async throws {
        guard let socket else { throw CancellationError() }
        try await socket.send(.string("{\"type\":\"audio.done\"}"))
    }
    public func next(timeout: Duration = .seconds(60)) async throws -> GrokSpeechEvent? {
        guard let socket else { throw CancellationError() }
        do {
            return try await withThrowingTaskGroup(of: GrokSpeechEvent?.self) { group in
                group.addTask {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: return nil
                    }
                    return try GrokSpeechEvent.decode(data)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    socket.cancel(with: .goingAway, reason: nil)
                    throw GrokSpeechError.incomplete
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        } catch is CancellationError { throw CancellationError() } catch let error as GrokSpeechError {
            throw error
        } catch {
            throw GrokSpeechError.classify(status: (socket.response as? HTTPURLResponse)?.statusCode)
        }
    }
    public func cancel() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
