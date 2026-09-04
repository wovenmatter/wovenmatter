import Foundation

public struct WovenMatterDownloadedRelease: Equatable, Sendable {
  public let manifest: WovenMatterReleaseManifest
  public let fileURL: URL

  public init(manifest: WovenMatterReleaseManifest, fileURL: URL) {
    self.manifest = manifest
    self.fileURL = fileURL
  }
}

public enum WovenMatterReleaseInstallationError: LocalizedError, Equatable, Sendable {
  case downloadFailed
  case invalidDownloadSize
  case checksumMismatch
  case productionAppRequired
  case applicationLocationNotWritable
  case invalidDiskImage
  case invalidApplication
  case installationPreparationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .downloadFailed:
      "Woven Matter could not download the update."
    case .invalidDownloadSize:
      "The downloaded update was empty or exceeded its size limit."
    case .checksumMismatch:
      "The downloaded update failed integrity verification."
    case .productionAppRequired:
      "Automatic updates are available from the installed production app."
    case .applicationLocationNotWritable:
      "Woven Matter cannot replace the app in its current location."
    case .invalidDiskImage:
      "The update disk image did not pass signature and notarization checks."
    case .invalidApplication:
      "The update does not contain the expected signed Woven Matter app."
    case .installationPreparationFailed(let detail):
      "Woven Matter could not prepare the update for installation: \(detail)"
    }
  }
}

public actor WovenMatterReleaseUpdateInstaller {
  public typealias DownloadFile = @Sendable (URL, URL, Int) async throws -> Int
  public typealias HashFile = @Sendable (URL) throws -> String

  public static let maximumReleaseBytes = 512 * 1_024 * 1_024
  private static let productionTeamIdentifier = "3M84Q9NAMN"

  public let rootDirectory: URL
  private let downloadFile: DownloadFile
  private let hashFile: HashFile

  public init(
    rootDirectory: URL = LocalACPManagedRuntimePaths.applicationSupportDirectory
      .appending(path: "Updates", directoryHint: .isDirectory),
    downloadFile: DownloadFile? = nil,
    hashFile: HashFile? = nil
  ) {
    self.rootDirectory = rootDirectory
    self.downloadFile = downloadFile ?? { source, destination, maximumBytes in
      try await LocalACPBoundedHTTPSDownloader.download(
        source,
        to: destination,
        maximumBytes: maximumBytes
      )
    }
    self.hashFile = hashFile ?? { url in
      try LocalACPManagedNodeRuntime.sha256Hex(fileAt: url)
    }
  }

  public func cachedRelease(
    for manifest: WovenMatterReleaseManifest
  ) throws -> WovenMatterDownloadedRelease? {
    let validated = try manifest.validated()
    let fileURL = releaseFileURL(for: validated)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    guard (try? verifiedChecksum(of: fileURL, for: validated)) == true else {
      try? FileManager.default.removeItem(at: fileURL)
      return nil
    }
    return WovenMatterDownloadedRelease(manifest: validated, fileURL: fileURL)
  }

  public func download(
    _ manifest: WovenMatterReleaseManifest
  ) async throws -> WovenMatterDownloadedRelease {
    let validated = try manifest.validated()
    if let cached = try cachedRelease(for: validated) {
      return cached
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: rootDirectory,
      withIntermediateDirectories: true
    )
    let destination = releaseFileURL(for: validated)
    let temporary = rootDirectory.appending(
      path: ".\(destination.lastPathComponent).\(UUID().uuidString).download"
    )
    defer { try? fileManager.removeItem(at: temporary) }

    let reportedBytes: Int
    do {
      reportedBytes = try await downloadFile(
        validated.downloadURL,
        temporary,
        Self.maximumReleaseBytes
      )
    } catch let error as LocalACPBoundedDownloadError {
      switch error {
      case .tooLarge:
        throw WovenMatterReleaseInstallationError.invalidDownloadSize
      case .unsafeURL, .invalidResponse, .transportFailed:
        throw WovenMatterReleaseInstallationError.downloadFailed
      }
    } catch {
      throw WovenMatterReleaseInstallationError.downloadFailed
    }

    let attributes = try fileManager.attributesOfItem(atPath: temporary.path)
    let actualBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard actualBytes > 0,
          actualBytes <= Self.maximumReleaseBytes,
          reportedBytes == actualBytes else {
      throw WovenMatterReleaseInstallationError.invalidDownloadSize
    }
    guard try verifiedChecksum(of: temporary, for: validated) else {
      throw WovenMatterReleaseInstallationError.checksumMismatch
    }

    try? fileManager.removeItem(at: destination)
    try fileManager.moveItem(at: temporary, to: destination)
    return WovenMatterDownloadedRelease(
      manifest: validated,
      fileURL: destination
    )
  }

  public func beginInstallation(
    of release: WovenMatterDownloadedRelease,
    replacing currentApplicationURL: URL = Bundle.main.bundleURL,
    currentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
  ) throws {
    let manifest = try release.manifest.validated()
    guard try verifiedChecksum(of: release.fileURL, for: manifest) else {
      throw WovenMatterReleaseInstallationError.checksumMismatch
    }
    guard let currentBundle = Bundle(url: currentApplicationURL),
          currentBundle.bundleIdentifier == "wovenmatter.desktop",
          currentApplicationURL.pathExtension == "app" else {
      throw WovenMatterReleaseInstallationError.productionAppRequired
    }

    let fileManager = FileManager.default
    let parent = currentApplicationURL.deletingLastPathComponent()
    guard fileManager.isWritableFile(atPath: parent.path) else {
      throw WovenMatterReleaseInstallationError.applicationLocationNotWritable
    }

    try validateDiskImage(at: release.fileURL)
    let token = UUID().uuidString
    let mountPoint = fileManager.temporaryDirectory.appending(
      path: "wovenmatter-update-mount-\(token)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(
      at: mountPoint,
      withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: mountPoint) }

    let attach = try Self.run(
      "/usr/sbin/diskutil",
      [
        "image", "attach", "--readOnly", "--nobrowse",
        "--mountPoint", mountPoint.path, release.fileURL.path,
      ]
    )
    guard attach.succeeded else {
      throw WovenMatterReleaseInstallationError.invalidDiskImage
    }
    defer {
      _ = try? Self.run("/usr/sbin/diskutil", ["eject", mountPoint.path])
    }

    let mountedApplication = mountPoint.appending(
      path: "Woven Matter.app",
      directoryHint: .isDirectory
    )
    try validateApplication(at: mountedApplication, for: manifest)

    let stagedApplication = parent.appending(
      path: ".Woven Matter.update-\(token).app",
      directoryHint: .isDirectory
    )
    let backupApplication = parent.appending(
      path: ".Woven Matter.rollback-\(token).app",
      directoryHint: .isDirectory
    )
    let readyMarker = rootDirectory.appending(path: ".ready-\(token)")
    guard !fileManager.fileExists(atPath: stagedApplication.path),
          !fileManager.fileExists(atPath: backupApplication.path) else {
      throw WovenMatterReleaseInstallationError.installationPreparationFailed(
        "A conflicting update transaction already exists."
      )
    }

    let copy = try Self.run(
      "/usr/bin/ditto",
      [mountedApplication.path, stagedApplication.path]
    )
    guard copy.succeeded else {
      throw WovenMatterReleaseInstallationError.installationPreparationFailed(
        copy.combinedOutput
      )
    }
    do {
      try validateApplication(at: stagedApplication, for: manifest)
      try launchReplacementHelper(
        currentProcessIdentifier: currentProcessIdentifier,
        currentApplication: currentApplicationURL,
        stagedApplication: stagedApplication,
        backupApplication: backupApplication,
        readyMarker: readyMarker,
        downloadedArtifact: release.fileURL
      )
    } catch {
      try? fileManager.removeItem(at: stagedApplication)
      throw error
    }
  }

  private func releaseFileURL(
    for manifest: WovenMatterReleaseManifest
  ) -> URL {
    rootDirectory.appending(path: manifest.downloadURL.lastPathComponent)
  }

  private func verifiedChecksum(
    of fileURL: URL,
    for manifest: WovenMatterReleaseManifest
  ) throws -> Bool {
    try hashFile(fileURL).lowercased() == manifest.sha256.lowercased()
  }

  private func validateDiskImage(at fileURL: URL) throws {
    let verification = try Self.run(
      "/usr/bin/codesign",
      ["--verify", "--verbose=2", fileURL.path]
    )
    let signature = try Self.run(
      "/usr/bin/codesign",
      ["-dvv", fileURL.path]
    )
    let policy = try Self.run(
      "/usr/sbin/spctl",
      [
        "--assess", "--type", "open",
        "--context", "context:primary-signature", "--verbose=2", fileURL.path,
      ]
    )
    guard verification.succeeded,
          signature.succeeded,
          signature.combinedOutput.contains("Authority=Developer ID Application:"),
          signature.combinedOutput.contains(
            "TeamIdentifier=\(Self.productionTeamIdentifier)"
          ),
          policy.succeeded else {
      throw WovenMatterReleaseInstallationError.invalidDiskImage
    }
  }

  private func validateApplication(
    at applicationURL: URL,
    for manifest: WovenMatterReleaseManifest
  ) throws {
    guard let bundle = Bundle(url: applicationURL),
          bundle.bundleIdentifier == "wovenmatter.desktop",
          bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            == manifest.version,
          let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
          Int(build) == manifest.build else {
      throw WovenMatterReleaseInstallationError.invalidApplication
    }
    let verification = try Self.run(
      "/usr/bin/codesign",
      ["--verify", "--deep", "--strict", "--verbose=2", applicationURL.path]
    )
    let signature = try Self.run(
      "/usr/bin/codesign",
      ["-dvv", applicationURL.path]
    )
    let policy = try Self.run(
      "/usr/sbin/spctl",
      ["--assess", "--type", "execute", "--verbose=2", applicationURL.path]
    )
    guard verification.succeeded,
          signature.succeeded,
          signature.combinedOutput.contains("Authority=Developer ID Application:"),
          signature.combinedOutput.contains(
            "TeamIdentifier=\(Self.productionTeamIdentifier)"
          ),
          policy.succeeded else {
      throw WovenMatterReleaseInstallationError.invalidApplication
    }
  }

  private func launchReplacementHelper(
    currentProcessIdentifier: Int32,
    currentApplication: URL,
    stagedApplication: URL,
    backupApplication: URL,
    readyMarker: URL,
    downloadedArtifact: URL
  ) throws {
    try? FileManager.default.removeItem(at: readyMarker)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", Self.replacementScript, "wovenmatter-updater",
      String(currentProcessIdentifier),
      currentApplication.path,
      stagedApplication.path,
      backupApplication.path,
      readyMarker.path,
      downloadedArtifact.path,
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw WovenMatterReleaseInstallationError.installationPreparationFailed(
        error.localizedDescription
      )
    }
  }

  private static func run(
    _ executable: String,
    _ arguments: [String]
  ) throws -> LocalACPProcessResult {
    try LocalACPProcessRunner.run(
      executableURL: URL(fileURLWithPath: executable),
      arguments: arguments
    )
  }

  nonisolated static let replacementScript = #"""
  set -u
  old_pid="$1"
  target="$2"
  staged="$3"
  backup="$4"
  ready="$5"
  artifact="$6"

  attempts=0
  while /bin/kill -0 "$old_pid" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 600 ]; then
      /bin/rm -rf "$staged"
      exit 70
    fi
    /bin/sleep 0.1
  done

  /bin/mv "$target" "$backup" || exit 71
  if ! /bin/mv "$staged" "$target"; then
    /bin/mv "$backup" "$target"
    exit 72
  fi
  if ! /usr/bin/open -n "$target" --args --woven-update-ready "$ready"; then
    /bin/rm -rf "$target"
    /bin/mv "$backup" "$target"
    /usr/bin/open -n "$target"
    exit 73
  fi

  attempts=0
  while [ ! -f "$ready" ]; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 300 ]; then
      exit 74
    fi
    /bin/sleep 0.1
  done
  /bin/rm -rf "$backup"
  /bin/rm -f "$artifact" "$ready"
  """#
}
