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
        var iterator = stream.makeAsyncIterator(); return await iterator.next()
    }
    func cancel() { continuation.finish() }
    func emit(_ event: GrokSpeechEvent) { continuation.yield(event) }
}

@MainActor private final class CaptureFixture: DictationCapturing {
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private(set) var stopped = false
    func start() -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.continuation = continuation; return stream
    }
    func stop() { stopped = true; continuation?.finish(); continuation = nil }
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
        let speech = SpeechFixture(), capture = CaptureFixture()
        let model = DictationModel(preferences: defaults, permission: { true }, credential: {
            var credential = DefaultAgentCredential(type: "oauth"); credential.access = "fixture-subscription"
            return credential
        }, makeAudio: { capture }, makeClient: { speech })
        model.enabled = true
        return (model, speech, capture, domain)
    }
    private func editor(_ text: String, id: String, selection: NSRange) -> (DictationEditor, UndoEditor) {
        let view = UndoEditor(); view.string = text; view.allowsUndo = true; view.setSelectedRange(selection)
        let editor = DictationEditor(); editor.bind(view, identity: id)
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
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        let (a, viewA) = editor("Original A", id: "A", selection: NSRange(location: 10, length: 0))
        let (b, viewB) = editor("Before old after", id: "B", selection: NSRange(location: 7, length: 3))
        model.toggle(editor: a)
        try await settle { model.phase == .recording }
        model.activeEditor = b
        #expect(model.isRecording)
        model.toggle(editor: b)
        #expect(capture.stopped)
        model.activeEditor = a // Navigation during finalization cannot redirect.
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
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        let (a, viewA) = editor("Chat", id: "chat", selection: NSRange(location: 4, length: 0))
        let (note, view) = editor("A note: ", id: "note", selection: NSRange(location: 8, length: 0))
        view.isRichText = true
        view.textStorage?.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: NSRange(location: 0, length: 6))
        model.toggle(editor: a); try await settle { model.phase == .recording }
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
        let model = DictationModel(preferences: defaults, permission: { false }, credential: {
            reads += 1; return .init(type: "oauth")
        }, makeAudio: { capture }, makeClient: { SpeechFixture() })
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        model.enabled = true
        let (editor, view) = editor("Keep", id: "A", selection: NSRange(location: 4, length: 0))
        model.toggle(editor: editor)
        try await settle { model.phase == .idle }
        #expect(reads == 0); #expect(model.error?.contains("Microphone access") == true)
        #expect(view.string == "Keep")
    }
    @Test func disablingDictationStopsCaptureWithoutDisconnectingTheAccount() async throws {
        let (model, speech, capture, domain) = fixture()
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        let (a, view) = editor("Keep", id: "A", selection: NSRange(location: 4, length: 0))
        model.toggle(editor: a); try await settle { model.phase == .recording }
        model.enabled = false
        await speech.emit(.done("late", duration: nil))
        #expect(capture.stopped); #expect(model.phase == .idle); #expect(view.string == "Keep")
        await model.refreshAvailability()
        #expect(model.availability.contains("Connected"))
    }
    @Test func cancellationAndLateFinalNeverEditADraft() async throws {
        let (model, speech, capture, domain) = fixture()
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        let (a, view) = editor("Keep", id: "A", selection: NSRange(location: 4, length: 0))
        model.toggle(editor: a); try await settle { model.phase == .recording }
        model.cancel(); await speech.emit(.done("late text", duration: nil))
        try await Task.sleep(for: .milliseconds(10))
        #expect(capture.stopped); #expect(view.string == "Keep")
        #expect(model.retainedTranscript == nil)
        #expect(model.phase == .idle)
    }
    @Test func reusedEditorAndOverlappingTypingRetainTranscript() async throws {
        let (model, speech, _, domain) = fixture()
        defer { model.cancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        let (a, view) = editor("Keep", id: "A", selection: NSRange(location: 4, length: 0))
        model.toggle(editor: a); try await settle { model.phase == .recording }
        model.toggle(editor: a)
        a.identity = "B"; view.string = "Different conversation"
        await speech.emit(.done("retained words", duration: nil))
        try await settle { model.phase == .idle }
        #expect(view.string == "Different conversation")
        #expect(model.retainedTranscript == "retained words")
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        model.insertRetained(into: a)
        #expect(view.string == "Different conversationretained words")
    }
}
