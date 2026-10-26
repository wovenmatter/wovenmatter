import Foundation
import Testing
@testable import WovenMatterCompanion

@Suite struct DictationTranscriptTests {
}

#if os(macOS) || os(iOS)
import AVFoundation
import Speech

@Suite struct DictationAudioTapTests {
  @MainActor @Test func microphoneCallbackRunsOnAnAudioQueue() async throws {
    let source = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let converter = try #require(AVAudioConverter(from: source, to: target))
    let (inputs, input) = AsyncThrowingStream<AnalyzerInput, any Error>.makeStream()
    let (_, output) = AsyncThrowingStream<DictationSegment, any Error>.makeStream()
    // Construct on MainActor, just as start() does, then invoke off MainActor.
    // The original inherited isolation traps here before converting any audio.
    let callback = DictationAudioTap.make(converter: converter, format: target, input: input, output: output)
    try await Task.detached {
      dispatchPrecondition(condition: .notOnQueue(.main))
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048))
      buffer.frameLength = 2_048
      buffer.floatChannelData?[0].update(repeating: 0.25, count: 2_048)
      callback(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
    }.value
    input.finish(); output.finish()
    var iterator = inputs.makeAsyncIterator()
    #expect(try await iterator.next() != nil, "The audio callback must deliver a converted buffer without an actor-isolation trap")
  }
}

@MainActor private final class NativeEngineFixture: DictationEngine {
  let stream: AsyncThrowingStream<DictationSegment, any Error>
  let continuation: AsyncThrowingStream<DictationSegment, any Error>.Continuation
  var preparedLanguages: [Locale] = []
  var captureStopped = false
  var cancelled = false
  var finalizes = true
  var prepareGate: CheckedContinuation<Void, Never>?
  var delayPreparation = false
  var delayFinalization = false
  var finishGate: CheckedContinuation<Void, Never>?
  init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
  func prepare(languages: [Locale], progress: @escaping @MainActor (Double?) -> Void) async {
    preparedLanguages = languages
    progress(0.5)
    if delayPreparation { await withCheckedContinuation { prepareGate = $0 } }
  }
  func start() async -> AsyncThrowingStream<DictationSegment, any Error> { stream }
  func stopCapture() { captureStopped = true }
  func finish() async {
    if delayFinalization { await withCheckedContinuation { finishGate = $0 } }
    if finalizes { continuation.finish() }
  }
  func cancel() async { cancelled = true; continuation.finish() }
  func emit(_ text: String, start: Double = 0, end: Double = 1, final: Bool = true) {
    continuation.yield(.init(start: start, end: end, text: text, isFinal: final))
  }
}

@MainActor @Suite(.serialized) struct NativeDictationSessionTests {
  private func settle(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Native dictation did not settle")
  }
  private func preferences() -> UserDefaults { UserDefaults(suiteName: "dictation-fixture-\(UUID())")! }

  @Test func failedHistorySaveDoesNotChangeInsertionAndRetriesSameIdentity() async throws {
    let engine = NativeEngineFixture()
    let session = DictationSession(preferences: preferences(), permission: { true }, makeEngine: { engine })
    var attempts: [DictationRecord] = [], inserted = ""
    session.saveHistory = { record in
      attempts.append(record)
      if attempts.count == 1 { throw CocoaError(.fileWriteOutOfSpace) }
    }
    session.start(); try await settle { session.phase == .recording }
    engine.emit("Keep the insertion")
    try await settle { !session.preview.isEmpty }
    session.stop { inserted = $0; return true }
    try await settle { session.phase == .idle && session.historyError != nil }
    #expect(inserted == "Keep the insertion")
    #expect(session.error == nil)
    session.retrySavingHistory()
    try await settle { session.historyRevision == 1 }
    #expect(attempts.count == 2 && attempts[0] == attempts[1])
    #expect(session.historyError == nil)
  }

  @Test func deniedMicrophoneNeverCreatesAnEngine() async throws {
    var creations = 0
    let session = DictationSession(preferences: preferences(), permission: { false }, makeEngine: { creations += 1; return NativeEngineFixture() })
    session.start()
    try await settle { session.phase == .idle }
    #expect(creations == 0)
    #expect(session.error == DictationError.microphoneDenied.localizedDescription)
  }

  @Test func changedDestinationRetainsTranscriptForExplicitInsertion() async throws {
    let engine = NativeEngineFixture()
    let session = DictationSession(preferences: preferences(), permission: { true }, makeEngine: { engine })
    session.start()
    try await settle { session.phase == .recording }
    engine.emit("Keep these words")
    try await settle { session.preview == "Keep these words" }
    session.stop { _ in false }
    try await settle { session.phase == .idle }
    #expect(session.retainedTranscript == "Keep these words")
    session.start()
    #expect(session.phase == .idle)
    var inserted = ""
    session.insertRetained { inserted = $0; return true }
    #expect(inserted == "Keep these words")
    #expect(session.retainedTranscript == nil)
    #expect(session.error == nil)
  }

  @Test func cancelledPreparationCannotAcquireANewerSessionOrInsertLateText() async throws {
    let old = NativeEngineFixture(), current = NativeEngineFixture()
    old.delayPreparation = true
    var creations = 0
    let session = DictationSession(preferences: preferences(), permission: { true }, makeEngine: {
      creations += 1; return creations == 1 ? old : current
    })
    session.start()
    try await settle { old.prepareGate != nil }
    session.cancel()
    session.start()
    for _ in 0..<10 { await Task.yield() }
    #expect(creations == 1, "The cancelled native operation still owns its resources")
    old.prepareGate?.resume(); old.prepareGate = nil
    try await settle { session.phase == .recording }
    #expect(old.cancelled)
    #expect(creations == 2)
    old.emit("obsolete")
    current.emit("Current")
    try await settle { session.preview == "Current" }
    var inserted = ""
    session.stop { inserted = $0; return true }
    try await settle { session.phase == .idle }
    #expect(inserted == "Current")
  }

  @Test func cancelledFinalizationMustSettleBeforeAnotherNativeRecording() async throws {
    let old = NativeEngineFixture(), current = NativeEngineFixture()
    old.delayFinalization = true
    var creations = 0
    let session = DictationSession(preferences: preferences(), permission: { true }, makeEngine: {
      creations += 1; return creations == 1 ? old : current
    })
    session.start()
    try await settle { session.phase == .recording }
    session.stop { _ in Issue.record("Cancelled result must not be inserted"); return true }
    try await settle { old.finishGate != nil }
    session.cancel()
    session.start()
    for _ in 0..<20 { await Task.yield() }
    #expect(creations == 1)
    old.finishGate?.resume(); old.finishGate = nil
    try await settle { session.phase == .recording }
    #expect(creations == 2)
    session.cancel()
    #expect(current.captureStopped)
    #expect(session.phase == .idle)
  }
}
#endif
