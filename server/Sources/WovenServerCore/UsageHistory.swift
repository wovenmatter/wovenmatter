import Foundation
import WovenLibrary
import WovenProtocol

/// Usage totals and dictation history, from the library alone.
package func registerUsageHistory(_ router: inout Router, library: Library) {
  router.on(ReadUsage.self) { request, _ in
    guard request.end > request.start else { throw ProtocolError(.badRequest, "The range ends before it starts.") }
    return try await library.usage(from: request.start, to: request.end, periodSeconds: request.periodSeconds)
  }
  router.on(SaveDictation.self) { request, _ in
    let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !request.id.isEmpty, !text.isEmpty else { throw ProtocolError(.badRequest, "A dictation needs an id and text.") }
    try await library.saveDictation(id: request.id, text: text, recordedAt: request.recordedAt)
    return Done()
  }
  router.on(ListDictations.self) { request, _ in
    try await library.dictations(limit: min(request.limit, 500), offset: request.offset)
  }
}
