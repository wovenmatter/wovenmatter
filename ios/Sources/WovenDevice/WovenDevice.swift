import Foundation
import MobileInference
import Synchronization
import WovenLibrary
import WovenProtocol
import WovenServerCore

/// The in-app host on an iPhone or iPad: the server's portable core over the
/// device's library, listening on nothing, with Quick Chat as its one
/// runtime. The UI talks to it over in-memory connections exactly as the Mac
/// UI talks to its own server, and to other machines' servers directly.
public final class WovenDevice: Sendable {
  public struct Options: Sendable {
    /// Holds the library, its content store and what only this device keeps:
    /// the machines' addresses, Quick Chat's conversation logs, the model catalogs.
    public var dataFolder: URL
    /// The device's name the first time its library is made; it can be renamed later.
    public var deviceName: String
    public var appVersion: String

    /// Where secrets live: the device Keychain unless a test gives another.
    var credentials: (any InferenceCredentialUpdating)?
    /// Where a turn's inference goes, in place of the providers, for a test.
    var inference: Providers.Inference?
    /// How provider catalogs are fetched, for a test.
    var catalogTransport: (any CatalogHTTPTransport)?
    /// How a server is reached, for a test.
    var dial: Machines.Dial?
    /// What the library says the device is; a test on a Mac says iPhone.
    var platform: MachinePlatform = .current

    public init(dataFolder: URL, deviceName: String, appVersion: String) {
      self.dataFolder = dataFolder
      self.deviceName = deviceName
      self.appVersion = appVersion
    }
  }

  /// One run of the core over one library. Removing this device from a Mac
  /// ends it, and the device starts again empty.
  private struct Running: Sendable {
    let library: Library
    let core: ServerCore
    let machines: Machines
  }

  private let options: Options
  private let running: Mutex<Running>
  /// The UI's connections to the core, closed when it starts again.
  private let connections = Mutex<[UUID: InMemoryTransport]>([:])

  private init(options: Options, running: Running) {
    self.options = options
    self.running = Mutex(running)
  }

  public static func start(_ options: Options) async throws -> WovenDevice {
    let device = WovenDevice(options: options, running: try await run(options))
    device.watchForRemoval()
    return device
  }

  /// A new in-memory connection to the in-app core: the UI's "local server".
  public func connect() -> any MessageTransport {
    let (ui, core) = InMemoryTransport.pair()
    let id = UUID()
    connections.withLock { $0[id] = core }
    let server = running.withLock { $0.core }
    Task {
      await server.serve(core, origin: .local)
      _ = self.connections.withLock { $0.removeValue(forKey: id) }
    }
    return ui
  }

  /// Dials the Mac a scanned or typed code names, learns every machine's
  /// address from it and remembers them. Throws `DeviceConnectionError`.
  public func add(_ code: ConnectionCode) async throws {
    try await running.withLock { $0.machines }.add(code)
  }

  /// Forgets every machine. The device keeps its library.
  public func disconnect() async {
    await running.withLock { $0.machines }.forgetAll()
  }

  /// Tells the device whether the app is in the foreground. In the
  /// background it leaves the machines' servers; back in front it dials them
  /// all again at once. Quick Chat and the UI's connections are unaffected.
  public func setActive(_ active: Bool) async {
    await running.withLock { $0.machines }.setActive(active)
  }

  /// Stops Quick Chat and every connection, and closes the library.
  public func stop() async {
    let current = running.withLock { $0 }
    await Self.end(current)
    closeConnections()
  }

  /// The library now, for tests.
  var library: Library { running.withLock { $0.library } }

  // MARK: Running

  private static func run(_ options: Options) async throws -> Running {
    let folder = options.dataFolder
    try excludeFromBackup(folder)
    let library = try await Library.open(folder: folder, machineName: options.deviceName, platform: options.platform)
    let providers = Providers(
      credentials: options.credentials ?? InferenceCredentialStore(),
      catalog: ProviderModelCatalog(directory: folder.appendingPathComponent("provider-models", isDirectory: true),
                                    transport: options.catalogTransport),
      servers: ModelServers(file: folder.appendingPathComponent("model-servers.json")),
      inference: options.inference)
    let quickChat = QuickChatRuntime(directory: folder.appendingPathComponent("pi-durable", isDirectory: true),
                                     library: library, providers: providers)
    await removeOrphanedConversations(in: quickChat.directory, library: library)
    let machines = Machines(library: library, appVersion: options.appVersion, folder: folder,
                            dial: options.dial ?? { host, port in try await SocketTransport.connect(.tcp(host: host, port: port)) })
    let core = try await ServerCore.start(library: library, appVersion: options.appVersion, runtimes: [quickChat],
                                          dataFolder: folder, peers: machines, titleRuntime: nil,
                                          routes: signInRoutes(providers, oauth: { InferenceOAuthSession() }))
    await machines.start()
    // The UI reads the machine list again when the core says it changed.
    let changes = machines.listChanged
    Task {
      for await _ in changes { core.announce(["machines"]) }
    }
    return Running(library: library, core: core, machines: machines)
  }

  private static func end(_ running: Running) async {
    await running.machines.stop()
    await running.core.stop()
    await running.library.close()
  }

  private func closeConnections() {
    let open = connections.withLock { open in
      defer { open.removeAll() }
      return Array(open.values)
    }
    for transport in open { transport.close() }
  }

  /// When another machine removes this device, its library starts again
  /// empty under a new identifier. What the device kept beside it goes too:
  /// the machines' addresses (so it does not join again by itself), how far
  /// content was handed over, Quick Chat's conversation logs and scratch
  /// folders. Its sign-ins stay. The UI's connections close, and it connects
  /// again to the new core.
  private func watchForRemoval() {
    let library = running.withLock { $0.library }
    let changes = library.changes()
    Task {
      for await _ in changes {}
      guard library.isRemoved else { return }
      let old = running.withLock { $0 }
      await Self.end(old)
      for name in ["machines.json", "content-handed.json", "pi-durable", "scratch"] {
        try? FileManager.default.removeItem(at: options.dataFolder.appendingPathComponent(name))
      }
      guard let fresh = try? await Self.run(options) else { return }
      running.withLock { $0 = fresh }
      closeConnections()
      watchForRemoval()
    }
  }

  /// Nothing in the data folder travels in a backup or to a new phone: the
  /// library's identity, its counter and the cursors and logs that go with it
  /// belong to this device alone. A restored phone starts as a new device and
  /// gets everything back by syncing. (Sign-ins are this-device-only Keychain
  /// items already.)
  private static func excludeFromBackup(_ folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var url = folder
    try url.setResourceValues(values)
  }

  /// A conversation log whose session is no longer in the library (deleted,
  /// or a throwaway one that named a chat) is removed at start.
  private static func removeOrphanedConversations(in directory: URL, library: Library) async {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
    for name in names {
      do {
        if try await library.session(name) != nil { continue }
      } catch {
        continue
      }
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }
}
