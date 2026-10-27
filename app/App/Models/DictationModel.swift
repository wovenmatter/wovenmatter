import AppKit
import Observation
import WovenMatterCompanion

/// AppKit's caret/undo bridge around the same native session used on iPhone.
@MainActor @Observable final class DictationModel {
    static let shared = DictationModel()
    typealias Phase = DictationSession.Phase
    let session: DictationSession
    weak var activeEditor: DictationEditor?
    private(set) weak var shortcutEditor: DictationEditor?
    @ObservationIgnored private let focusedWindow: () -> NSWindow?
    init(session: DictationSession = .shared,
         focusedWindow: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }) {
        self.session = session; self.focusedWindow = focusedWindow
    }
    func refreshShortcutEditor() {
        let focused = DictationEditor.commandTarget(in: focusedWindow(), preferred: activeEditor)
        if shortcutEditor !== focused { shortcutEditor = focused }
    }
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
        guard retainedTranscript == nil else { error = "Insert or discard the previous transcript first."; return }
        guard editor.ticket() != nil else { error = "Place the cursor in an editable text input first."; return }
        session.start()
    }
    func toggleActiveEditor() {
        // Menu tracking can temporarily release key-window/editor focus. Resolve
        // against the workspace window and restore its caret before recording.
        guard let editor = DictationEditor.commandTarget(
            in: focusedWindow(), preferred: shortcutEditor ?? activeEditor
        ), editor.focusForCommand() else {
            error = "Choose an editable conversation or note for dictation."
            return
        }
        if retainedTranscript != nil { insertRetained(into: editor) }
        else { toggle(editor: editor) }
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

@MainActor extension ApplicationModel {
    func configureDictationHistory() {
        DictationSession.shared.saveHistory = { [weak self] record in
            guard let self else { throw CancellationError() }
            if self.isLibraryClient {
                guard let store = self.libraryClient.clientStore else { throw ApplicationModelError.dashboardStoreUnavailable }
                try await store.dictations.save(record)
            } else if self.isBackendFrontend {
                _ = try await self.sendBackendCommand(.saveDictation(record))
            } else {
                guard let database = self.dashboardStore?.database else { throw ApplicationModelError.dashboardStoreUnavailable }
                try await database.saveDictation(record)
            }
        }
        DictationSession.shared.retrySavingHistory()
    }
}
