// Isolates editor focus tests from microphone capture and provider transport.
@MainActor final class DictationModel {
    static let shared = DictationModel()
    weak var activeEditor: DictationEditor?
}
