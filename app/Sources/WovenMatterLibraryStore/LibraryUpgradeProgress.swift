import Foundation

/// How far opening a library is in bringing an earlier release's library to
/// the current schema (`convertEarlierLibraryUnlocked`). An upgrade rewrites the whole
/// file once and takes minutes for a library of a few gigabytes, so whoever
/// waits on the open (the background service's readiness reply) can say what
/// is happening instead of timing out.
public struct LibraryUpgradeProgress: Sendable, Equatable, Codable {
  public enum Stage: String, Sendable, Codable {
    /// Copying the library before the conversion rewrites it.
    case backingUp
    /// Converting tables and recorded versions to the current schema.
    case converting
    /// Writing the converted library out compactly (VACUUM).
    case compacting
  }

  public var stage: Stage
  /// How far the whole upgrade is, from 0 to 1. It only increases.
  public var fraction: Double
  /// The size of the library file when the upgrade began.
  public var libraryBytes: Int64
  public var startedAt: Date

  public init(stage: Stage, fraction: Double, libraryBytes: Int64, startedAt: Date) {
    self.stage = stage
    self.fraction = fraction
    self.libraryBytes = libraryBytes
    self.startedAt = startedAt
  }
}

/// The upgrades running in this process, by library file.
public enum LibraryUpgradeMonitor {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var upgrades: [String: LibraryUpgradeProgress] = [:]

  /// The upgrade of the library at `file`, while one runs.
  public static func progress(for file: URL) -> LibraryUpgradeProgress? {
    lock.withLock { upgrades[key(file)] }
  }

  static func publish(_ progress: LibraryUpgradeProgress?, for file: URL) {
    let observer = lock.withLock {
      upgrades[key(file)] = progress
      return observers[key(file)]
    }
    observer?(progress)
  }

  nonisolated(unsafe) private static var observers: [String: @Sendable (LibraryUpgradeProgress?) -> Void] = [:]
  /// Tests see every change of one library's progress, as it is published.
  static func observe(_ file: URL, _ observer: (@Sendable (LibraryUpgradeProgress?) -> Void)?) {
    lock.withLock { observers[key(file)] = observer }
  }

  private static func key(_ file: URL) -> String { file.standardizedFileURL.resolvingSymlinksInPath().path }
}

/// Publishes one upgrade's progress while it runs on the writer's queue.
///
/// The steps report milestones (`reach`); between two, a timer moves the
/// fraction a little toward the next one so a long statement still shows
/// movement. While compacting, the fraction follows how much of the
/// expected output VACUUM has written. The timer runs on its own queue:
/// SQLite calls nothing back while VACUUM copies pages.
final class LibraryUpgradeReporter: @unchecked Sendable {
  /// Each stage's share of the whole, measured on a 2.1 GB library from
  /// v0.3.5: the copy is a clone, and converting and compacting took about
  /// as long as each other.
  static let spans: [LibraryUpgradeProgress.Stage: ClosedRange<Double>] = [
    .backingUp: 0...0.02, .converting: 0.02...0.52, .compacting: 0.52...1,
  ]

  let file: URL
  private let lock = NSLock()
  private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
  private var progress: LibraryUpgradeProgress
  /// The fraction the current milestone span ends at.
  private var target: Double
  private var stageStarted = ContinuousClock.now
  private var lastMilestone = ContinuousClock.now
  /// While compacting: the file whose growth measures VACUUM, and how large
  /// it becomes when VACUUM is done.
  private var compaction: (output: URL, expectedBytes: Int64)?

  init(file: URL) {
    self.file = file
    let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    progress = .init(stage: .backingUp, fraction: 0, libraryBytes: bytes, startedAt: Date())
    target = Self.spans[.backingUp]!.upperBound
    LibraryUpgradeMonitor.publish(progress, for: file)
    NSLog("Converting an earlier release's library (%lld bytes) to the current schema.", bytes)
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
    timer.resume()
  }

  /// A milestone: `stage` is `part` (0...1) done, and the next milestone
  /// is at `next`.
  /// `after` names the work that led to it, for the log.
  func reach(_ stage: LibraryUpgradeProgress.Stage, _ part: Double, next: Double? = nil, after work: String? = nil) {
    let span = Self.spans[stage]!
    let now = ContinuousClock.now
    lock.withLock {
      if let work {
        NSLog("Library upgrade: %@ took %@.", work, String(describing: now - lastMilestone))
      }
      lastMilestone = now
      if stage != progress.stage {
        NSLog("Library upgrade: %@ took %@.", progress.stage.rawValue, String(describing: now - stageStarted))
        stageStarted = now
      }
      progress.stage = stage
      progress.fraction = max(progress.fraction, span.lowerBound + (span.upperBound - span.lowerBound) * min(max(part, 0), 1))
      target = max(progress.fraction, span.lowerBound + (span.upperBound - span.lowerBound) * min(max(next ?? 1, 0), 1))
      LibraryUpgradeMonitor.publish(progress, for: file)
    }
  }

  /// Compaction writes the library into `output` until it is about
  /// `expectedBytes` long.
  func compacting(output: URL, expectedBytes: Int64) {
    reach(.compacting, 0)
    lock.withLock { compaction = (output, max(expectedBytes, 1)) }
  }

  func finish() {
    timer.cancel()
    let elapsed = Date().timeIntervalSince(progress.startedAt)
    NSLog("Library upgrade: %@ took %@; the upgrade took %.1f s.",
          progress.stage.rawValue, String(describing: ContinuousClock.now - stageStarted), elapsed)
    LibraryUpgradeMonitor.publish(nil, for: file)
  }

  private func tick() {
    lock.withLock {
      if let compaction {
        // VACUUM first copies the library into a temporary database, which
        // nothing outside SQLite sees, then writes that copy back through
        // the WAL: about half its time each. The first half creeps; the
        // second follows the WAL toward the expected size.
        let span = Self.spans[.compacting]!
        let written = (try? FileManager.default.attributesOfItem(atPath: compaction.output.path)[.size] as? NSNumber)?.int64Value ?? 0
        let creeping = progress.fraction + (span.lowerBound + (span.upperBound - span.lowerBound) * 0.45 - progress.fraction) * 0.03
        let writing = span.lowerBound + (span.upperBound - span.lowerBound) * (0.45 + 0.55 * min(Double(written) / Double(compaction.expectedBytes), 0.99))
        progress.fraction = max(progress.fraction, creeping, written > 1 << 20 ? writing : 0)
      } else {
        // A fifth of the way to the next milestone every couple of seconds:
        // it keeps moving and never passes the milestone before it is reached.
        progress.fraction += (target - progress.fraction) * 0.03
      }
      LibraryUpgradeMonitor.publish(progress, for: file)
    }
  }
}
