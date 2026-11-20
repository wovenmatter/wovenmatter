#if os(macOS)
import Darwin
import Foundation

/// The server's handle on the VM helper: a per-user launchd job running
/// `Contents/Helpers/WovenMatterVMHelper --root <root>`, and its control socket.
///
/// The job file lives in the server's data folder, not in ~/Library/LaunchAgents,
/// so the VM never starts at login on its own: the server starts it when this
/// machine runs the bots. launchd restarts a crashed helper; a clean stop
/// stays stopped.
struct WovenVMController: Sendable {
  let paths: WovenVMPaths
  let label: String
  let helper: URL
  let jobFile: URL

  /// The label is the app's bundle identifier plus `.vm`, so a dev instance
  /// (its own bundle identifier) has its own VM and never touches another's.
  init(root: URL, bundleIdentifier: String, helper: URL, jobFile: URL) {
    paths = WovenVMPaths(root: root)
    label = bundleIdentifier + ".vm"
    self.helper = helper
    self.jobFile = jobFile
  }

  var engineSocket: String { paths.engineSocket.path }
  private var domain: String { "gui/\(getuid())" }
  private var service: String { domain + "/" + label }

  /// Writes the job and starts the helper; never restarts a running one.
  /// Returns once the helper answers. The first run then downloads and sets
  /// up the guest; follow `status()`.
  func start() async throws {
    try await Self.background { [self] in
      try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
      let job: [String: Any] = [
        "Label": label,
        "ProgramArguments": [helper.path, "--root", paths.root.path],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],
        "ThrottleInterval": 5,
        // Time for a guest shutdown before launchd sends SIGKILL.
        "ExitTimeOut": 40,
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive",
        "StandardErrorPath": paths.root.appending(path: "helper.stderr.log").path,
        "WorkingDirectory": paths.root.path,
      ]
      let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
      let changed = (try? Data(contentsOf: jobFile)) != data
      if changed {
        try data.write(to: jobFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jobFile.path)
      }
      let loaded = try launchctl(["print", service]) == 0
      // A moved or rebuilt app: load the job again so launchd runs the new helper.
      if loaded && changed { _ = try launchctl(["bootout", service]) }
      if !loaded || changed { try checked(launchctl(["bootstrap", domain, jobFile.path]), "bootstrap") }
      try checked(launchctl(["kickstart", service]), "kickstart")
    }
    let deadline = ContinuousClock.now + .seconds(30)
    while true {
      do {
        _ = try await status()
        return
      } catch {
        guard ContinuousClock.now < deadline else { throw error }
        try await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  func status() async throws -> WovenVMStatus {
    try await call("GET", "/status", as: WovenVMStatus.self)
  }

  /// Stores the pool and the disk cap. The disk cap applies at once; the pool
  /// applies through the balloon at once and exactly once the idle VM restarts.
  func apply(_ resources: WovenVMResources) async throws {
    _ = try await call("PUT", "/resources", body: JSONEncoder().encode(resources), as: WovenVMStatus.self)
  }

  /// Shuts the guest down and unloads the job. The disks stay.
  func stop() async {
    _ = try? await call("POST", "/stop", as: WovenVMStatus.self)
    try? await Self.background { [self] in
      let deadline = Date() + 60
      while FileManager.default.fileExists(atPath: paths.controlSocket.path), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.5)
      }
      if try launchctl(["print", service]) == 0 { _ = try launchctl(["bootout", service]) }
    }
  }

  // MARK: Transport

  private func call<Reply: Decodable>(_ method: String, _ path: String, body: Data? = nil,
                                      as type: Reply.Type) async throws -> Reply {
    // Only talk to a helper listening in this user's own private directory.
    try WovenVMPaths.preparePrivateDirectory(paths.socketDirectory, create: false)
    let reply: (status: Int, body: Data)
    do {
      reply = try await UnixHTTP.request(socket: paths.controlSocket.path, method: method, path: path, body: body)
    } catch {
      throw WovenVMError.unavailable("The VM helper is not running.")
    }
    guard (200..<300).contains(reply.status) else {
      let message = (try? JSONDecoder().decode(WovenVMControlHTTP.ErrorBody.self, from: reply.body))?.error
      throw WovenVMError.failed(message ?? "The VM helper returned \(reply.status).")
    }
    return try JSONDecoder().decode(Reply.self, from: reply.body)
  }

  private func checked(_ status: Int32, _ action: String) throws {
    guard status == 0 else { throw WovenVMError.failed("The VM helper could not be started (launchctl \(action) \(status)).") }
  }

  private func launchctl(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  private static func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try body() }) }
    }
  }
}
#endif
