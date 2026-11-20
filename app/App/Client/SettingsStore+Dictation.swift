import Foundation

/// Dictation history is append-only synced data: this Mac's server saves each
/// completed dictation once, and Settings → Dictation reads it back in pages.
extension SettingsStore {
    /// Sends every completed dictation to the server.
    func configureDictationHistory() {
        DictationSession.shared.saveHistory = { [weak self] record in
            guard let self else { throw CancellationError() }
            try await self.saveDictation(record)
        }
        DictationSession.shared.retrySavingHistory()
    }

    func saveDictation(_ record: DictationRecord) async throws {
        throw ClientError.notConnected
    }

    /// Newest first.
    func dictationHistory(limit: Int, offset: Int) async throws -> [DictationRecord] {
        throw ClientError.notConnected
    }
}
