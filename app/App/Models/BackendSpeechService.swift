import Foundation
import WovenMatterClient

struct BackendSpeechRequest: Codable, Sendable {
    var id: UUID?
    var audio: Data?
}
struct BackendSpeechReply: Codable, Sendable {
    var accountLabel: String?
    var event: GrokSpeechEvent?
    var failure: GrokSpeechError?
}

/// Audio is forwarded in bounded chunks without files, logs or persisted RPC responses.
actor BackendSpeechService {
    var isActive: Bool { activeID != nil }
    private var activeID: UUID?
    private var transport: (any GrokSpeechTransport)?
    private var expiry: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var sending = false
    private var reading = false
    private var events: [GrokSpeechEvent] = []
    private var eventTask: Task<Void, Never>?
    private var eventWaiter: CheckedContinuation<GrokSpeechEvent?, Never>?
    private var eventTimeout: Task<Void, Never>?
    private let credential: @Sendable () async throws -> DefaultAgentCredential
    private let makeTransport: @Sendable () -> any GrokSpeechTransport

    init(credential: @escaping @Sendable () async throws -> DefaultAgentCredential = {
        try await ProviderAccountCoordinator.shared.grokDictationCredential()
    }, makeTransport: @escaping @Sendable () -> any GrokSpeechTransport = { GrokSpeechClient() }) {
        self.credential = credential; self.makeTransport = makeTransport
    }
    func handle(method: String, payload: Data) async throws -> Data {
        let request = try JSONDecoder().decode(BackendSpeechRequest.self, from: payload)
        var reply = BackendSpeechReply()
        do {
            switch method {
            case "speech.availability": reply.accountLabel = try await credential().accountLabel ?? "Grok subscription"
            case "speech.start":
                guard let id = request.id else { throw GrokSpeechError.unavailable }
                await cancel()
                activeID = id
                let token = try await credential()
                guard activeID == id else { throw CancellationError() }
                var speech = makeTransport(); transport = speech; touch(id)
                do { try await speech.connect(credential: token) }
                catch GrokSpeechError.signInRequired {
                    await speech.cancel()
                    guard activeID == id, let access = token.access,
                        let renewed = try await ProviderAccountCoordinator.shared.renewRejectedAccess(provider: "xai", access: access)
                    else { throw GrokSpeechError.signInRequired }
                    guard activeID == id else { throw CancellationError() }
                    speech = makeTransport(); transport = speech
                    try await speech.connect(credential: renewed)
                }
                guard activeID == id else { await speech.cancel(); throw CancellationError() }
                reply.accountLabel = token.accountLabel ?? "Grok subscription"
                let connectedSpeech = speech
                eventTask = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            if let event = try await connectedSpeech.next(timeout: .seconds(60)) {
                                await self?.received(event, id: id)
                                if case .done = event { return }
                                if case .failure = event { return }
                            }
                        }
                    } catch { await self?.received(.failure(error as? GrokSpeechError ?? .unavailable), id: id) }
                }
            case "speech.cancel":
                if request.id == activeID { await cancel() }
            default:
                guard let id = request.id, id == activeID, let speech = transport else { throw GrokSpeechError.incomplete }
                touch(id)
                switch method {
                case "speech.send":
                    guard let audio = request.audio, audio.count <= 65_536, !sending else { throw GrokSpeechError.audioBacklog }
                    sending = true
                    defer { sending = false }
                    try await speech.send(audio)
                case "speech.finish": try await speech.finish()
                case "speech.next":
                    guard !reading else { throw GrokSpeechError.audioBacklog }
                    reading = true
                    defer { reading = false }
                    reply.event = await nextEvent()
                    if case .done = reply.event { await cancel() }
                    if case .failure = reply.event { await cancel() }
                default: throw GrokSpeechError.unavailable
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            if request.id == activeID { await cancel() }
            reply.failure = error as? GrokSpeechError ?? .unavailable
        }
        return try JSONEncoder().encode(reply)
    }
    private func received(_ event: GrokSpeechEvent, id: UUID) {
        guard activeID == id else { return }
        if let waiter = eventWaiter {
            eventWaiter = nil; eventTimeout?.cancel(); eventTimeout = nil
            waiter.resume(returning: event)
        } else {
            // Partial transcripts replace each other instead of growing a queue.
            if case .partial = events.last { events.removeLast() }
            if events.count < 64 { events.append(event) }
            else { events = [.failure(.audioBacklog)] }
        }
    }
    private func nextEvent() async -> GrokSpeechEvent? {
        if !events.isEmpty { return events.removeFirst() }
        return await withCheckedContinuation { continuation in
            eventWaiter = continuation
            eventTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                await self?.completeEventWait()
            }
        }
    }
    private func completeEventWait() {
        let waiter = eventWaiter; eventWaiter = nil; eventTimeout = nil
        waiter?.resume(returning: nil)
    }
    private func touch(_ id: UUID) {
        lastActivity = .now
        guard expiry == nil else { return }
        expiry = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard await self?.expireIfIdle(id) == false else { return }
            }
        }
    }
    private func expireIfIdle(_ id: UUID) async -> Bool {
        guard activeID == id else { return true }
        if lastActivity.duration(to: .now) >= .seconds(70) { await cancel(); return true }
        return false
    }
    private func cancel() async {
        let previous = transport
        activeID = nil; transport = nil; expiry?.cancel(); expiry = nil
        eventTask?.cancel(); eventTask = nil; events = []
        eventTimeout?.cancel(); completeEventWait()
        await previous?.cancel()
    }
}

actor BackendSpeechTransport: GrokSpeechTransport {
    typealias Request = @Sendable (String, Data) async throws -> Data
    private let request: Request
    private let id = UUID()
    init(request: @escaping Request) { self.request = request }
    func connect(credential: DefaultAgentCredential) async throws { _ = try await call("start") }
    func send(_ audio: Data) async throws {
        guard audio.count <= 65_536 else { throw GrokSpeechError.audioBacklog }
        _ = try await call("send", audio: audio)
    }
    func finish() async throws { _ = try await call("finish") }
    func next(timeout: Duration) async throws -> GrokSpeechEvent? { try await call("next").event }
    func cancel() async { _ = try? await call("cancel") }
    private func call(_ operation: String, audio: Data? = nil) async throws -> BackendSpeechReply {
        let data = try await request("speech." + operation, JSONEncoder().encode(BackendSpeechRequest(id: id, audio: audio)))
        let reply = try JSONDecoder().decode(BackendSpeechReply.self, from: data)
        if let error = reply.failure { throw error }
        return reply
    }
    static func availability(request: Request) async throws -> String {
        let data = try await request("speech.availability", JSONEncoder().encode(BackendSpeechRequest()))
        let reply = try JSONDecoder().decode(BackendSpeechReply.self, from: data)
        if let error = reply.failure { throw error }
        return reply.accountLabel ?? "Grok subscription"
    }
}
