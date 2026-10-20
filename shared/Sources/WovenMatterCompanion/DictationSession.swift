#if os(macOS) || os(iOS)
import AVFoundation
import Foundation
import Observation

@available(macOS 26, iOS 26, *)
@MainActor public protocol DictationEngine: AnyObject {
  func prepare(languages: [Locale], progress: @escaping @MainActor (Double?) -> Void) async throws
  func start() async throws -> AsyncThrowingStream<DictationSegment, any Error>
  func stopCapture()
  func finish() async throws
  func cancel() async
}

/// One recording per interface process. No provider credentials, RPC, audio
/// files, or network transcription are involved, including remote workspaces.
@available(macOS 26, iOS 26, *)
@MainActor @Observable public final class DictationSession {
  public static let shared = DictationSession()
  public enum Phase { case idle, preparing, recording, finishing }
  public private(set) var phase = Phase.idle
  public private(set) var preview = ""
  public private(set) var retainedTranscript: String?
  public private(set) var downloadProgress: Double?
  public private(set) var availableLanguages: [String] = []
  public var error: String?
  public var enabled: Bool {
    didSet { preferences.set(enabled, forKey: "wovenmatter.dictation.enabled"); if !enabled { cancel() } }
  }
  public var languageIdentifier: String {
    didSet { preferences.set(languageIdentifier, forKey: "wovenmatter.dictation.language") }
  }
  public var isBusy: Bool { phase != .idle }
  public var isRecording: Bool { phase == .preparing || phase == .recording }
  public var availability: String { "Apple on-device speech · Works offline after language preparation." }
  @ObservationIgnored private let preferences: UserDefaults
  @ObservationIgnored private let permission: () async -> Bool
  @ObservationIgnored private let makeEngine: () -> any DictationEngine
  @ObservationIgnored private let finishingTimeout: Duration
  @ObservationIgnored private var engine: (any DictationEngine)?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var finishTask: Task<Void, any Error>?
  @ObservationIgnored private var timeout: Task<Void, Never>?
  @ObservationIgnored private var cleanupTask: Task<Void, Never>?
  @ObservationIgnored private var transcript = DictationTranscript()
  @ObservationIgnored private var insert: ((String) -> Bool)?

  public init(preferences: UserDefaults = .standard,
              permission: @escaping () async -> Bool = DictationSession.microphonePermission,
              makeEngine: @escaping () -> any DictationEngine = { AppleDictationEngine() },
              finishingTimeout: Duration = .seconds(20)) {
    self.preferences = preferences; self.permission = permission; self.makeEngine = makeEngine
    self.finishingTimeout = finishingTimeout
    enabled = preferences.object(forKey: "wovenmatter.dictation.enabled") as? Bool ?? true
    languageIdentifier = preferences.string(forKey: "wovenmatter.dictation.language") ?? ""
  }

  public static func microphonePermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
    }
  }

  public func loadLanguages() async {
    availableLanguages = await AppleDictationEngine.supportedLanguages()
  }

  public func start() {
    guard enabled, phase == .idle, retainedTranscript == nil else { return }
    generation = UUID()
    let id = generation
    let languages = languageIdentifier.isEmpty ? Locale.preferredLanguages.map { Locale(identifier: $0) } : [Locale(identifier: languageIdentifier)]
    phase = .preparing; error = nil; preview = ""; downloadProgress = nil
    transcript = .init(); insert = nil
    let previousCleanup = cleanupTask
    task = Task { [self] in
      do {
        await previousCleanup?.value
        guard generation == id, !Task.isCancelled else { return }
        guard await permission() else { throw DictationError.microphoneDenied }
        guard generation == id, !Task.isCancelled else { return }
        let engine = makeEngine()
        self.engine = engine
        try await engine.prepare(languages: languages.isEmpty ? [Locale.current] : languages) { [weak self] progress in
          guard self?.generation == id else { return }
          self?.downloadProgress = progress
        }
        guard generation == id, !Task.isCancelled else { return }
        let results = try await engine.start()
        guard generation == id, !Task.isCancelled else { return }
        phase = .recording; downloadProgress = nil
        for try await segment in results {
          guard generation == id, !Task.isCancelled else { return }
          transcript.update(segment)
          preview = transcript.preview
        }
        guard generation == id, !Task.isCancelled else { return }
        guard phase == .finishing else { throw DictationError.incomplete }
        try await finishTask?.value
        guard generation == id, !Task.isCancelled else { return }
        let text = transcript.finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.hasUnfinalizedText else { throw DictationError.incomplete }
        guard !text.isEmpty else { throw DictationError.noSpeech }
        if insert?(text) != true {
          retainedTranscript = text
          error = "The destination changed or closed. Your transcript is ready to insert in an editor."
        }
        endSession()
      } catch {
        guard generation == id, !Task.isCancelled else { return }
        fail(error)
      }
    }
  }

  public func stop(insert: @escaping (String) -> Bool) {
    if phase == .preparing { cancel(); return }
    guard phase == .recording, let engine else { return }
    self.insert = insert
    phase = .finishing
    engine.stopCapture()
    finishTask = Task { try await engine.finish() }
    let id = generation
    timeout = Task {
      do { try await Task.sleep(for: finishingTimeout) } catch { return }
      guard generation == id, phase == .finishing else { return }
      fail(DictationError.incomplete)
    }
  }

  public func insertRetained(using insert: (String) -> Bool) {
    guard let text = retainedTranscript, insert(text) else {
      error = "Place the cursor in an editable text input first."; return
    }
    retainedTranscript = nil; error = nil
  }

  public func cancel() { retainedTranscript = nil; error = nil; endSession() }

  private func fail(_ failure: any Error) {
    let completed = transcript.finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !completed.isEmpty { retainedTranscript = completed }
    error = failure.localizedDescription
    endSession()
  }

  private func endSession() {
    generation = UUID()
    engine?.stopCapture()
    let previous = engine
    engine = nil
    let running = task
    task?.cancel(); task = nil
    let finishing = finishTask
    finishTask?.cancel(); finishTask = nil
    timeout?.cancel(); timeout = nil
    if let previous {
      cleanupTask = Task {
        await previous.cancel()
        // Preparation and native finalization can outlive cancellation. Keep
        // ownership until they settle, then release any assets created late.
        await running?.value
        _ = try? await finishing?.value
        await previous.cancel()
      }
    }
    phase = .idle; preview = ""; downloadProgress = nil; insert = nil
  }
}
#endif
