import AVFoundation
import Foundation
import Observation
import WovenMatterClient

@MainActor @Observable
final class DictationModel {
    static let shared = DictationModel()
    enum Phase { case idle, connecting, recording, finishing }
    var enabled = false {
        didSet {
            preferences.set(enabled, forKey: "wovenmatter.dictation.enabled")
            if !enabled { cancel() }
        }
    }
    private(set) var phase = Phase.idle
    private(set) var preview = ""
    private(set) var retainedTranscript: String?
    private(set) var accountLabel = "Grok subscription"
    private(set) var availability = "Connect Grok in Connections to use dictation."
    var error: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, any Error>?
    @ObservationIgnored private var finishingTimeout: Task<Void, Never>?
    @ObservationIgnored private var audio: (any DictationCapturing)?
    @ObservationIgnored private var client: (any GrokSpeechTransport)?
    @ObservationIgnored private let permission: () async -> Bool
    @ObservationIgnored private let credential: () async throws -> DefaultAgentCredential
    @ObservationIgnored private let renewCredential: (DefaultAgentCredential) async throws -> DefaultAgentCredential?
    @ObservationIgnored private let makeAudio: () -> any DictationCapturing
    @ObservationIgnored private let makeClient: () -> any GrokSpeechTransport
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var destination: DictationEditorTicket?
    @ObservationIgnored weak var activeEditor: DictationEditor?

    init(preferences: UserDefaults = .standard,
         permission: @escaping () async -> Bool = DictationModel.microphonePermission,
         credential: @escaping () async throws -> DefaultAgentCredential = { try await ProviderAccountCoordinator.shared.grokDictationCredential() },
         renewCredential: @escaping (DefaultAgentCredential) async throws -> DefaultAgentCredential? = {
             guard let access = $0.access else { return nil }
             return try await ProviderAccountCoordinator.shared.renewRejectedAccess(provider: "xai", access: access)
         },
         makeAudio: @escaping () -> any DictationCapturing = { DictationAudioCapture() },
         makeClient: @escaping () -> any GrokSpeechTransport = { GrokSpeechClient() }) {
        self.permission = permission; self.credential = credential
        self.renewCredential = renewCredential
        self.makeAudio = makeAudio; self.makeClient = makeClient
        self.preferences = preferences
        self.enabled = preferences.bool(forKey: "wovenmatter.dictation.enabled")
    }
    static func microphonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    var isRecording: Bool { phase == .recording || phase == .connecting }
    var isBusy: Bool { phase != .idle }

    func refreshAvailability() async {
        do {
            let credential = try await credential()
            accountLabel = credential.accountLabel ?? "Grok subscription"
            availability = "Connected · Dictation access is checked when you record."
        } catch {
            accountLabel = "Grok subscription"
            availability = error.localizedDescription
        }
    }

    func toggle(editor: DictationEditor) {
        activeEditor = editor
        if isRecording { stop(editor: editor); return }
        guard phase == .idle else { return }
        guard enabled else { error = "Enable dictation in Settings → General."; return }
        guard retainedTranscript == nil else {
            error = "Insert or discard the previous transcript before starting another recording."; return
        }
        guard editor.ticket() != nil else { error = "Place the cursor in an editable text input first."; return }
        generation = UUID()
        let id = generation
        phase = .connecting; error = nil; preview = ""; destination = nil
        task = Task {
            do {
                let allowed = await permission()
                guard generation == id, !Task.isCancelled else { return }
                guard allowed else {
                    throw DictationError.message("Microphone access is disabled. Enable it for Woven Matter in macOS Settings → Privacy & Security → Microphone.")
                }
                let credential = try await credential()
                guard generation == id, !Task.isCancelled else { return }
                accountLabel = credential.accountLabel ?? "Grok subscription"
                var speech = makeClient(); client = speech
                do { try await speech.connect(credential: credential) }
                catch GrokSpeechError.signInRequired {
                    await speech.cancel()
                    guard let renewed = try await renewCredential(credential) else { throw GrokSpeechError.signInRequired }
                    guard generation == id, !Task.isCancelled else { return }
                    speech = makeClient(); client = speech
                    try await speech.connect(credential: renewed)
                }
                guard generation == id, !Task.isCancelled else { await speech.cancel(); return }
                let capture = makeAudio(); audio = capture
                let stream = try capture.start()
                phase = .recording
                writer = Task {
                    do {
                        for try await chunk in stream { try Task.checkCancellation(); try await speech.send(chunk) }
                        try Task.checkCancellation()
                        try await speech.finish()
                    } catch { await speech.cancel(); throw error }
                }
                while generation == id, !Task.isCancelled {
                    guard let event = try await speech.next(timeout: .seconds(60)) else { continue }
                    switch event {
                    case .ready: break
                    case .partial(let text): preview = text
                    case .failure(let error): throw error
                    case .done(let text, _):
                        guard phase == .finishing else { throw GrokSpeechError.incomplete }
                        try await writer?.value
                        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !transcript.isEmpty, destination?.insert(transcript) != true {
                            retainedTranscript = transcript
                            error = "The destination changed or closed. Your transcript is ready to insert when you return to an editor."
                        }
                        availability = "Dictation worked with \(accountLabel)."
                        finishSession(); return
                    }
                }
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                if let speechError = error as? GrokSpeechError { availability = speechError.localizedDescription }
                finishSession()
            }
        }
    }

    func stop(editor: DictationEditor) {
        if phase == .connecting { cancel(); return }
        guard phase == .recording else { return }
        guard let ticket = editor.ticket() else { error = "Place the cursor in the destination text input, then stop recording."; return }
        destination = ticket; phase = .finishing; audio?.stop()
        let id = generation
        finishingTimeout = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, generation == id, phase == .finishing else { return }
            error = GrokSpeechError.incomplete.localizedDescription
            finishSession()
        }
    }
    func leaveWorkspace() {
        guard isRecording else { return }
        if let editor = activeEditor { stop(editor: editor) }
        else { cancel() }
        // An editor may have closed or started IME composition while navigating.
        // Leaving the workspace must always stop microphone capture.
        if isRecording { cancel() }
    }
    func insertRetained(into editor: DictationEditor) {
        guard let transcript = retainedTranscript, editor.ticket()?.insert(transcript) == true else {
            error = "Place the cursor in an editable text input first."; return
        }
        retainedTranscript = nil; error = nil
    }
    func cancel() { retainedTranscript = nil; error = nil; finishSession() }
    private func finishSession() {
        generation = UUID()
        audio?.stop(); audio = nil
        writer?.cancel(); writer = nil
        finishingTimeout?.cancel(); finishingTimeout = nil
        task?.cancel(); task = nil
        if let client { Task { await client.cancel() } }; client = nil
        destination = nil; phase = .idle; preview = ""
    }
}

private enum DictationError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}
