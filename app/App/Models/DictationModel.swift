import Foundation
import Observation
import WovenMatterCompanion

/// AppKit's caret/undo bridge around the same native session used on iPhone.
@MainActor @Observable final class DictationModel {
    static let shared = DictationModel()
    typealias Phase = DictationSession.Phase
    let session: DictationSession
    weak var activeEditor: DictationEditor?
    init(session: DictationSession = .shared) { self.session = session }
    var enabled: Bool { get { session.enabled } set { session.enabled = newValue } }
    var languageIdentifier: String { get { session.languageIdentifier } set { session.languageIdentifier = newValue } }
    var phase: Phase { session.phase }
    var preview: String { session.preview }
    var retainedTranscript: String? { session.retainedTranscript }
    var availability: String { session.availability }
    var error: String? { get { session.error } set { session.error = newValue } }
    var isRecording: Bool { session.isRecording }
    var isBusy: Bool { session.isBusy }
    func refreshAvailability() async { await session.loadLanguages() }
    func toggle(editor: DictationEditor) {
        activeEditor = editor
        if isRecording { stop(editor: editor); return }
        guard !isBusy else { return }
        guard enabled else { error = "Enable dictation in Settings → General."; return }
        guard retainedTranscript == nil else { error = "Insert or discard the previous transcript first."; return }
        guard editor.ticket() != nil else { error = "Place the cursor in an editable text input first."; return }
        session.start()
    }
    func toggleActiveEditor() {
        guard let activeEditor else { return }
        if retainedTranscript != nil { insertRetained(into: activeEditor) }
        else { toggle(editor: activeEditor) }
    }
    func stop(editor: DictationEditor) {
        if phase == .preparing { session.cancel(); return }
        guard let ticket = editor.ticket() else {
            error = "Place the cursor in the destination text input, then stop recording."; return
        }
        session.stop { ticket.insert($0) }
    }
    func leaveWorkspace() {
        let target = activeEditor
        activeEditor = nil
        guard isRecording else { return }
        if let target { stop(editor: target) }
        if isRecording { session.stop { _ in false } }
        if phase == .preparing { session.cancel() }
    }
    func insertRetained(into editor: DictationEditor) { session.insertRetained { editor.ticket()?.insert($0) == true } }
    func cancel() { session.cancel() }
}
