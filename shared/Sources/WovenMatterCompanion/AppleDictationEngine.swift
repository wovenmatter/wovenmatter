#if os(macOS) || os(iOS)
import AVFoundation
import Foundation
import Speech

/// Native, streaming SpeechAnalyzer input. Assets are Apple-managed and only
/// prepared on an explicit recording action. Audio never leaves this device.
@available(macOS 26, iOS 26, *)
@MainActor public final class AppleDictationEngine: DictationEngine {
  private var analyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var dictation: DictationTranscriber?
  private var format: AVAudioFormat?
  private var audio: AVAudioEngine?
  private var input: AsyncThrowingStream<AnalyzerInput, any Error>.Continuation?
  private var output: AsyncThrowingStream<DictationSegment, any Error>.Continuation?
  private var reader: Task<Void, Never>?
  private var reservedLocale: Locale?
  private var ownsReservation = false
  private var download: Progress?
  private var observers: [NSObjectProtocol] = []
  private var tapInstalled = false
  #if os(iOS)
  private var audioSessionActive = false
  #endif
  public init() {}

  public static func supportedLanguages() async -> [String] {
    var locales = await DictationTranscriber.supportedLocales
    if SpeechTranscriber.isAvailable { locales += await SpeechTranscriber.supportedLocales }
    return Set(locales.map(\.identifier)).sorted {
      (Locale.current.localizedString(forIdentifier: $0) ?? $0) < (Locale.current.localizedString(forIdentifier: $1) ?? $1)
    }
  }

  public func prepare(languages: [Locale], progress: @escaping @MainActor (Double?) -> Void) async throws {
    var selected: Locale?
    for locale in languages {
      if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
        transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        selected = supported; break
      }
      if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
        dictation = DictationTranscriber(locale: supported, preset: .progressiveLongDictation)
        selected = supported; break
      }
    }
    guard let selected else { throw DictationError.unsupportedLanguage }
    try Task.checkCancellation()
    let modules: [any SpeechModule] = transcriber.map { [$0] } ?? dictation.map { [$0] } ?? []
    let previouslyReserved = await AssetInventory.reservedLocales.contains(selected)
    ownsReservation = try await AssetInventory.reserve(locale: selected) && !previouslyReserved
    reservedLocale = selected
    try Task.checkCancellation()
    if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
      download = request.progress
      let reporting = Task {
        while !Task.isCancelled {
          progress(request.progress.fractionCompleted)
          do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
      }
      defer { reporting.cancel(); download = nil }
      do {
        try await withTaskCancellationHandler {
          try await request.downloadAndInstall()
        } onCancel: { request.progress.cancel() }
      } catch {
        try Task.checkCancellation()
        throw DictationError.languagePreparation
      }
    }
    try Task.checkCancellation()
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { throw DictationError.unavailable }
    self.format = format
    analyzer = SpeechAnalyzer(modules: modules)
    try await analyzer?.prepareToAnalyze(in: format)
  }

  public func start() async throws -> AsyncThrowingStream<DictationSegment, any Error> {
    guard let analyzer, let format else { throw DictationError.unavailable }
    try Task.checkCancellation()
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
    try session.setActive(true)
    audioSessionActive = true
    #endif
    let (results, output) = AsyncThrowingStream<DictationSegment, any Error>.makeStream()
    self.output = output
    if let transcriber {
      reader = Task {
        do {
          for try await result in transcriber.results {
            output.yield(.init(start: result.range.start.seconds, end: result.range.end.seconds,
                               text: String(result.text.characters), isFinal: result.isFinal))
          }
          output.finish()
        } catch { output.finish(throwing: error) }
      }
    } else if let dictation {
      reader = Task {
        do {
          for try await result in dictation.results {
            output.yield(.init(start: result.range.start.seconds, end: result.range.end.seconds,
                               text: String(result.text.characters), isFinal: result.isFinal))
          }
          output.finish()
        } catch { output.finish(throwing: error) }
      }
    }
    let (inputs, input) = AsyncThrowingStream<AnalyzerInput, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
    self.input = input
    try await analyzer.start(inputSequence: inputs)
    try Task.checkCancellation()
    let audio = AVAudioEngine()
    self.audio = audio
    let node = audio.inputNode
    let source = node.outputFormat(forBus: 0)
    guard source.sampleRate > 0, source.channelCount > 0,
          let converter = AVAudioConverter(from: source, to: format) else { throw DictationError.unavailable }
    let conversion = DictationAudioConversion(converter: converter, format: format)
    node.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
      do {
        if let converted = try conversion.convert(buffer) {
          if case .dropped = input.yield(AnalyzerInput(buffer: converted)) {
            input.finish(throwing: DictationError.audioBacklog)
            output.finish(throwing: DictationError.audioBacklog)
          }
        }
      } catch { input.finish(throwing: error); output.finish(throwing: error) }
    }
    tapInstalled = true
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { _ in
      output.finish(throwing: DictationError.interrupted)
    })
    #if os(iOS)
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { notification in
      if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
        output.finish(throwing: DictationError.interrupted)
      }
    })
    #endif
    audio.prepare()
    try audio.start()
    return results
  }

  public func stopCapture() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    audio?.stop()
    if tapInstalled { audio?.inputNode.removeTap(onBus: 0); tapInstalled = false }
    audio = nil
    input?.finish(); input = nil
    #if os(iOS)
    if audioSessionActive {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      audioSessionActive = false
    }
    #endif
  }

  public func finish() async throws {
    stopCapture()
    try await analyzer?.finalizeAndFinishThroughEndOfInput()
    await reader?.value
  }

  public func cancel() async {
    stopCapture()
    download?.cancel()
    await analyzer?.cancelAndFinishNow()
    reader?.cancel(); await reader?.value; reader = nil
    output?.finish(); output = nil
    analyzer = nil; transcriber = nil; dictation = nil
    if ownsReservation, let locale = reservedLocale { await AssetInventory.release(reservedLocale: locale) }
    reservedLocale = nil; ownsReservation = false
  }
}

/// The tap is serialized by AVAudioEngine; its buffers are reused by the audio
/// system, so each AnalyzerInput must own a converted copy.
private final class DictationAudioConversion: @unchecked Sendable {
  let converter: AVAudioConverter
  let format: AVAudioFormat
  init(converter: AVAudioConverter, format: AVAudioFormat) { self.converter = converter; self.format = format }
  func convert(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
    let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate)) + 32
    guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw DictationError.unavailable }
    let input = DictationConversionInput(source)
    var error: NSError?
    let status = converter.convert(to: result, error: &error) { _, state in input.take(state) }
    if let error { throw error }
    guard status != .error else { throw DictationError.unavailable }
    return result.frameLength > 0 ? result : nil
  }
}
private final class DictationConversionInput: @unchecked Sendable {
  private let lock = NSLock()
  private var source: AVAudioPCMBuffer?
  init(_ source: AVAudioPCMBuffer) { self.source = source }
  func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.withLock {
      guard let source else { status.pointee = .noDataNow; return nil }
      self.source = nil; status.pointee = .haveData; return source
    }
  }
}
#endif
