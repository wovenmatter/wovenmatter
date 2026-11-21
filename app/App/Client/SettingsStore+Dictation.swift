import Foundation
import WovenProtocol

/// Dictation history is append-only synced data: this Mac's server saves each
/// completed dictation once, and Settings → Dictation reads it back in pages.
/// The dictation language is a synced setting.
extension SettingsStore {
    private static let dictationLanguageKey = "dictation.language"

    /// Sends every completed dictation to the server, and syncs the language.
    func configureDictationHistory() {
        DictationSession.shared.saveHistory = { [weak self] record in
            guard let self else { throw CancellationError() }
            try await self.saveDictation(record)
        }
        DictationSession.shared.languageChanged = { [weak self] language in
            guard let self, self.values[Self.dictationLanguageKey] != .string(language) else { return }
            Task { try? await self.set(Self.dictationLanguageKey, to: .string(language)) }
        }
        DictationSession.shared.retrySavingHistory()
    }

    /// The synced language, once the server has answered.
    func applyDictationLanguage() {
        guard case .string(let language) = values[Self.dictationLanguageKey],
              DictationSession.shared.languageIdentifier != language, !DictationSession.shared.isBusy else { return }
        DictationSession.shared.languageIdentifier = language
    }

    func saveDictation(_ record: DictationRecord) async throws {
        guard let server, server.isConnected else { throw ClientError.notConnected }
        _ = try await server.call(SaveDictation(id: record.id, text: record.text, recordedAt: record.createdAt))
    }

    /// Newest first, from every machine.
    func dictationHistory(limit: Int, offset: Int) async throws -> [DictationRecord] {
        guard let server, server.isConnected else { throw ClientError.notConnected }
        return try await server.call(ListDictations(limit: limit, offset: offset)).map {
            DictationRecord(id: $0.id, text: $0.text, createdAt: $0.recordedAt)
        }
    }
}
