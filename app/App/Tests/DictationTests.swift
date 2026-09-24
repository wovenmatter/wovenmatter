import AppKit
import Foundation
import Testing
import WovenMatterClient

private actor SpeechFixture: GrokSpeechTransport {
    private let stream: AsyncStream<GrokSpeechEvent>
    private let continuation: AsyncStream<GrokSpeechEvent>.Continuation
    private(set) var credentials: [DefaultAgentCredential] = []
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func connect(credential: DefaultAgentCredential) { credentials.append(credential) }
    func send(_ audio: Data) {}
    func finish() {}
    func next(timeout: Duration) async -> GrokSpeechEvent? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
    func cancel() { continuation.finish() }
    func emit(_ event: GrokSpeechEvent) { continuation.yield(event) }
}

/// A response already in flight may arrive after cancellation. Keep delivery
/// under test control instead of assuming the transport suppresses late events.
private actor DelayedSpeechFixture: GrokSpeechTransport {
    private var response: CheckedContinuation<GrokSpeechEvent?, Never>?
    private(set) var receiving = false
    private(set) var delivered = false
    func connect(credential: DefaultAgentCredential) {}
    func send(_ audio: Data) {}
    func finish() {}
    func next(timeout: Duration) async -> GrokSpeechEvent? {
        receiving = true
        let event = await withCheckedContinuation { response = $0 }
        delivered = true
        return event
    }
    func cancel() {}
    func complete(_ event: GrokSpeechEvent) {
        response?.resume(returning: event)
        response = nil
    }
}

@MainActor private final class CaptureFixture: DictationCapturing {
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private(set) var stopped = false
    func start() -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.continuation = continuation
        return stream
    }
    func stop() {
        stopped = true
        continuation?.finish()
        continuation = nil
    }
    func fail(_ error: any Error) { continuation?.finish(throwing: error) }
}

@MainActor private final class UndoEditor: NSTextView {
    let history = UndoManager()
    override var undoManager: UndoManager? { history }
}

@MainActor @Suite(.serialized) struct DictationTests {
    private func fixture() -> (DictationModel, SpeechFixture, CaptureFixture, String) {
        _ = NSApplication.shared
        let domain = "wovenmatter.dictation.test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        let speech = SpeechFixture()
        let capture = CaptureFixture()
        let model = DictationModel(
            preferences: defaults, permission: { true },
            credential: {
                var credential = DefaultAgentCredential(type: "oauth")
                credential.access = "fixture-subscription"
                return credential
            }, makeAudio: { capture }, makeClient: { speech })
        model.enabled = true
        return (model, speech, capture, domain)
    }
    private func editor(_ text: String, id: String, selection: NSRange) -> (DictationEditor, UndoEditor) {
        let view = UndoEditor()
        view.string = text
        view.allowsUndo = true
        view.setSelectedRange(selection)
        let editor = DictationEditor()
        editor.bind(view, identity: id)
        return (editor, view)
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Dictation state did not settle")
    }
    @Test func entireRecordingGoesToStopDestinationAndIsOneUndoableEdit() async throws {
        let (model, speech, capture, domain) = fixture()
        defer {
            model.cancel()
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        let (a, viewA) = editor("Original A", id: "A", selection: NSRange(location: 10, length: 0))
        let (b, viewB) = editor("Before old after", id: "B", selection: NSRange(location: 7, length: 3))
        model.toggle(editor: a)
        try await settle { model.phase == .recording }
        model.activeEditor = b
        #expect(model.isRecording)
        model.toggle(editor: b)
        #expect(capture.stopped)
        model.activeEditor = a  // Navigation during finalization cannot redirect.
        await speech.emit(.done("whole recording", duration: 3))
        try await settle { model.phase == .idle }
        #expect(viewA.string == "Original A")
        #expect(viewB.string == "Before whole recording after")
        #expect(viewB.selectedRange().location == 22)
        viewB.history.undo()
        #expect(viewB.string == "Before old after")
        viewB.history.redo()
        #expect(viewB.string == "Before whole recording after")
        #expect(await speech.credentials.count == 1)
    }
    @Test func noteTargetPreservesRichTextAndWorkspaceExitStopsRecording() async throws {
        let (model, speech, capture, domain) = fixture()
        defer {
            model.cancel()
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        let (a, viewA) = editor("Chat", id: "chat", selection: NSRange(location: 4, length: 0))
        let (note, view) = editor("A note: ", id: "note", selection: NSRange(location: 8, length: 0))
        view.isRichText = true
        view.textStorage?.addAttribute(
            .font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: 0, length: 6))
        model.toggle(editor: a)
        try await settle { model.phase == .recording }
        model.activeEditor = note
        model.leaveWorkspace()
        #expect(capture.stopped)
        await speech.emit(.done("dictated note", duration: 2))
        try await settle { model.phase == .idle }
        #expect(viewA.string == "Chat")
        #expect(view.string == "A note: dictated note")
        #expect((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
    }
    @Test func deniedPermissionNeverLoadsCredentialsOrStartsAudio() async throws {
        _ = NSApplication.shared
        let domain = "wovenmatter.dictation.test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        var reads = 0
        let capture = CaptureFixture()
        let model = DictationModel(
            preferences: defaults, permission: { false },
            credential: {
                reads += 1
                return .init(type: "oauth")
            }, makeAudio: { capture }, makeClient: { SpeechFixture() })
        defer {
            model.cancel()
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        model.enabled = true
        let (editor, view) = editor("Keep", id: "A", selection: NSRange(location: 4, length: 0))
        model.toggle(editor: editor)
        try await settle { model.phase == .idle }
        #expect(reads == 0)
        #expect(model.error?.contains("Microphone access") == true)
        #expect(view.string == "Keep")
    }
    @Test func disablingDictationStopsCaptureWithoutDisconnectingTheAccount() async throws {
        let (model, speech, capture, domain) = fixture()
        defer {
            model.cancel()
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        let (a, view) = editor("Keep", id: "A", selection: NSRange(location: 4, length: 0))
        model.toggle(editor: a)
        try await settle { model.phase == .recording }
        model.enabled = false
        await speech.emit(.done("late", duration: nil))
        #expect(capture.stopped)
        #expect(model.phase == .idle)
        #expect(view.string == "Keep")
        await model.refreshAvailability()
        #expect(model.availability.contains("Connected"))
    }
    @Test func audioBacklogReportsTheCaptureFailureAndStopsRecording() async throws {
        let (model, _, capture, domain) = fixture()
        defer {
            model.cancel()
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        let (a, view) = editor("Keep", id: "A", selection: NSRange(location: 4, length: 0))
        model.toggle(editor: a)
        try await settle { model.phase == .recording }
        capture.fail(GrokSpeechError.audioBacklog)
        try await settle { model.phase == .idle }
        #expect(capture.stopped)
        #expect(view.string == "Keep")
        #expect(model.error == GrokSpeechError.audioBacklog.localizedDescription)
        #expect(model.retainedTranscript == nil)
        #expect(model.phase == .idle)
    }
    @Test func reusedEditorRetainsTranscript() async throws {
        let (model, speech, _, domain) = fixture()
        defer {
            model.cancel()
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        let (a, view) = editor("Keep", id: "A", selection: NSRange(location: 4, length: 0))
        model.toggle(editor: a)
        try await settle { model.phase == .recording }
        model.toggle(editor: a)
        a.identity = "B"
        view.string = "Different conversation"
        await speech.emit(.done("retained words", duration: nil))
        try await settle { model.phase == .idle }
        #expect(view.string == "Different conversation")
        #expect(model.retainedTranscript == "retained words")
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        model.insertRetained(into: a)
        #expect(view.string == "Different conversationretained words")
    }

    @Test func cancelledRecordingCannotInsertIntoANewerFinishingRecording() async throws {
        _ = NSApplication.shared
        let domain = "wovenmatter.dictation.test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        let oldSpeech = DelayedSpeechFixture()
        let currentSpeech = SpeechFixture()
        var starts = 0
        let model = DictationModel(
            preferences: defaults, permission: { true },
            credential: {
                .init(type: "oauth")
            }, makeAudio: { CaptureFixture() },
            makeClient: {
                starts += 1
                return starts == 1 ? oldSpeech : currentSpeech
            })
        defer {
            model.cancel()
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        model.enabled = true
        let (target, view) = editor("Draft ", id: "A", selection: NSRange(location: 6, length: 0))
        model.toggle(editor: target)
        try await settle { model.phase == .recording }
        #expect(await oldSpeech.receiving)
        model.cancel()
        model.toggle(editor: target)
        try await settle { model.phase == .recording }
        model.stop(editor: target)
        await oldSpeech.complete(.done("obsolete", duration: nil))
        // Let the cancelled task handle its delivered response before completing
        // the new recording, exposing any use of the new destination/writer.
        for _ in 0..<20 { await Task.yield() }
        #expect(await oldSpeech.delivered)
        #expect(view.string == "Draft ")
        #expect(model.phase == .finishing)
        await currentSpeech.emit(.done("current", duration: nil))
        try await settle { model.phase == .idle }
        #expect(view.string == "Draft current")
    }
}

@MainActor @Test func backendSpeechProxyKeepsCredentialsOnOwner() async throws {
    let fixture = SpeechFixture()
    let service = BackendSpeechService(credential: {
        var value = DefaultAgentCredential(type: "oauth")
        value.access = "fixture-private-access"
        value.displayName = "Fixture account"
        return value
    }, makeTransport: { fixture })
    let request: BackendSpeechTransport.Request = { method, payload in
        try await service.handle(method: method, payload: payload)
    }
    let availability = try await service.handle(method: "speech.availability", payload: JSONEncoder().encode(BackendSpeechRequest()))
    #expect(!String(decoding: availability, as: UTF8.self).contains("fixture-private-access"))
    #expect(try await BackendSpeechTransport.availability(request: request) == "Fixture account")
    let proxy = BackendSpeechTransport(request: request)
    try await proxy.connect(credential: DefaultAgentCredential(type: "oauth"))
    #expect(await fixture.credentials.first?.access == "fixture-private-access")
    try await proxy.send(Data([0, 1, 0, 1]))
    await fixture.emit(.partial("hello"))
    #expect(try await proxy.next(timeout: .seconds(1)) == .partial("hello"))
    try await proxy.finish()
    await fixture.emit(.done("hello", duration: 1))
    #expect(try await proxy.next(timeout: .seconds(1)) == .done("hello", duration: 1))
    await proxy.cancel()
}

@MainActor @Test func backendSpeechProxyRejectsOversizedAudio() async throws {
    let proxy = BackendSpeechTransport(request: { _, _ in
        Issue.record("Oversized audio must never cross the RPC boundary")
        return Data()
    })
    await #expect(throws: GrokSpeechError.audioBacklog) {
        try await proxy.send(Data(count: 65_537))
    }
}

/// Keep cleanup suspended so a second start can overtake an older start.
private actor DelayedCancellationSpeechFixture: GrokSpeechTransport {
    private var cancellation: CheckedContinuation<Void, Never>?
    private(set) var isCancelling = false
    func connect(credential: DefaultAgentCredential) {}
    func send(_ audio: Data) {}
    func finish() {}
    func next(timeout: Duration) async -> GrokSpeechEvent? {
        try? await Task.sleep(for: .seconds(60))
        return nil
    }
    func cancel() async {
        isCancelling = true
        await withCheckedContinuation { cancellation = $0 }
    }
    func finishCancellation() {
        cancellation?.resume()
        cancellation = nil
    }
}

private final class SpeechSequenceFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var first: (any GrokSpeechTransport)?
    private let subsequent: any GrokSpeechTransport
    init(first: any GrokSpeechTransport, subsequent: any GrokSpeechTransport) {
        self.first = first; self.subsequent = subsequent
    }
    func make() -> any GrokSpeechTransport {
        lock.withLock {
            defer { first = nil }
            return first ?? subsequent
        }
    }
}

@Test(.timeLimit(.minutes(1))) func newerBackendRecordingSurvivesEarlierStartCleanup() async throws {
    let original = DelayedCancellationSpeechFixture()
    let current = SpeechFixture()
    let sequence = SpeechSequenceFixture(first: original, subsequent: current)
    let service = BackendSpeechService(credential: { .init(type: "oauth") }, makeTransport: { sequence.make() })
    let initialID = UUID(), obsoleteID = UUID(), currentID = UUID()
    func payload(_ id: UUID) throws -> Data { try JSONEncoder().encode(BackendSpeechRequest(id: id)) }
    _ = try await service.handle(method: "speech.start", payload: payload(initialID))
    let obsolete = Task { try await service.handle(method: "speech.start", payload: payload(obsoleteID)) }
    for _ in 0..<1_000 {
        if await original.isCancelling { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await original.isCancelling)
    _ = try await service.handle(method: "speech.start", payload: payload(currentID))
    await original.finishCancellation()
    do {
        _ = try await obsolete.value
        Issue.record("A superseded recording start should be cancelled")
    } catch is CancellationError {}
    await current.emit(.partial("current recording"))
    let result = try JSONDecoder().decode(BackendSpeechReply.self,
        from: await service.handle(method: "speech.next", payload: payload(currentID)))
    #expect(result.failure == nil)
    #expect(result.event == .partial("current recording"))
    _ = try await service.handle(method: "speech.cancel", payload: payload(currentID))
}

private actor DelayedSendSpeechFixture: GrokSpeechTransport {
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var isSending = false
    func connect(credential: DefaultAgentCredential) {}
    func send(_ audio: Data) async {
        isSending = true
        await withCheckedContinuation { pending = $0 }
    }
    func finish() {}
    func next(timeout: Duration) async -> GrokSpeechEvent? {
        try? await Task.sleep(for: .seconds(60))
        return nil
    }
    func cancel() {}
    func finishSend() { pending?.resume(); pending = nil }
}

@Test(.timeLimit(.minutes(1))) func previousBackendRecordingDoesNotBlockNewAudio() async throws {
    let original = DelayedSendSpeechFixture()
    let current = SpeechFixture()
    let sequence = SpeechSequenceFixture(first: original, subsequent: current)
    let service = BackendSpeechService(credential: { .init(type: "oauth") }, makeTransport: { sequence.make() })
    let initialID = UUID(), currentID = UUID()
    func payload(_ id: UUID, audio: Data? = nil) throws -> Data {
        try JSONEncoder().encode(BackendSpeechRequest(id: id, audio: audio))
    }
    _ = try await service.handle(method: "speech.start", payload: payload(initialID))
    let oldSend = Task { try await service.handle(method: "speech.send", payload: payload(initialID, audio: Data([0, 1]))) }
    for _ in 0..<1_000 {
        if await original.isSending { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await original.isSending)
    _ = try await service.handle(method: "speech.start", payload: payload(currentID))
    let reply = try JSONDecoder().decode(BackendSpeechReply.self,
        from: await service.handle(method: "speech.send", payload: payload(currentID, audio: Data([0, 1]))))
    #expect(reply.failure == nil)
    #expect(await service.isActive)
    await original.finishSend()
    _ = try await oldSend.value
    _ = try await service.handle(method: "speech.cancel", payload: payload(currentID))
}
