import Darwin
import Foundation

/// The Mac app's handle on the Woven VM (docs/architecture/WOVEN_EVERYWHERE.md,
/// Bots → Engine → Mac). The VM itself lives in the launchd-supervised helper;
/// this type installs/starts that job and talks to its control socket. Every
/// call is safe from any thread and never blocks the caller's actor.
public struct WovenVMController: Sendable {
    public let paths: WovenVMPaths
    public let label: String
    public let helper: URL
    public let launchAgentPlist: URL
    private let launchctl: @Sendable ([String]) throws -> Int32

    public init(root: URL, label: String, helper: URL,
                launchAgentPlist: URL? = nil,
                launchctl: (@Sendable ([String]) throws -> Int32)? = nil) {
        paths = WovenVMPaths(root: root)
        self.label = label
        self.helper = helper
        self.launchAgentPlist = launchAgentPlist ?? WovenVMLaunchAgent.plistURL(label: label)
        self.launchctl = launchctl ?? Self.runLaunchctl
    }

    /// The controller for this app: the helper bundled at
    /// `Contents/Helpers/WovenMatterVMHelper`, label `<bundle id>.vm`, and VM
    /// files in `<support directory>/WovenVM`. Nil where the VM is unavailable
    /// (Intel Macs, or a build without the helper).
    public static func forApp(supportDirectory: URL, bundle: Bundle = .main) -> Self? {
        #if arch(arm64)
        guard let identifier = bundle.bundleIdentifier else { return nil }
        let helper = bundle.bundleURL.appending(path: "Contents/Helpers/WovenMatterVMHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return nil }
        return Self(root: supportDirectory.appending(path: "WovenVM", directoryHint: .isDirectory),
                    label: WovenVMLaunchAgent.label(bundleIdentifier: identifier), helper: helper)
        #else
        return nil
        #endif
    }

    /// The Docker Engine API socket for the bots runtime (0600, this user only).
    public var engineSocket: URL { paths.engineSocket }
    /// The helper's HTTP control API (see the architecture document).
    public var controlSocket: URL { paths.controlSocket }

    private var service: String { "gui/\(getuid())/\(label)" }

    // MARK: Lifecycle

    /// Installs or refreshes the launch agent and starts the helper. The first
    /// run downloads and provisions the guest; follow `status()` (or
    /// `waitUntilReady`) for progress. Safe to call repeatedly.
    @discardableResult
    public func ensureRunning() async throws -> WovenVMStatus {
        try await Self.background { [self] in
            let plist = WovenVMLaunchAgent.propertyList(label: label, helper: helper, root: paths.root)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let changed = (try? Data(contentsOf: launchAgentPlist)) != data
            if changed {
                try FileManager.default.createDirectory(at: launchAgentPlist.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let temporary = launchAgentPlist.deletingLastPathComponent()
                    .appending(path: "." + UUID().uuidString + ".plist")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try data.write(to: temporary, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                guard Darwin.rename(temporary.path, launchAgentPlist.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            let loaded = try launchctl(["print", service]) == 0
            if loaded && changed {
                // A moved or updated app: reload so launchd runs the new helper.
                _ = try launchctl(["bootout", service])
            }
            if !loaded || changed {
                try checked(launchctl(["bootstrap", "gui/\(getuid())", launchAgentPlist.path]), "started")
            }
            // No -k: never restart a running helper (and its VM).
            try checked(launchctl(["kickstart", service]), "started")
        }
        let deadline = Date() + 20
        while true {
            do { return try await status() } catch {
                guard Date() < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    public func status() async throws -> WovenVMStatus {
        try await call("GET", "/v1/status", as: WovenVMStatus.self)
    }

    /// Polls until the VM is ready; throws with the helper's reason if it fails.
    public func waitUntilReady(timeout: Duration = .seconds(3600),
                               progress: (@Sendable (WovenVMStatus) -> Void)? = nil) async throws -> WovenVMStatus {
        let clock = ContinuousClock(), deadline = clock.now + timeout
        while clock.now < deadline {
            let current = try await status()
            progress?(current)
            switch current.phase {
            case .ready: return current
            case .failed: throw WovenVMError.failed(current.failure ?? "The Woven VM failed.")
            case .stopped: throw WovenVMError.unavailable("The Woven VM is stopped.")
            default: try await Task.sleep(for: .seconds(1))
            }
        }
        throw WovenVMError.unavailable("The Woven VM did not become ready in time.")
    }

    /// Stores the RAM pool and disk cap. Disk changes take effect at once. A
    /// pool change is exact after the VM next restarts, which the helper does
    /// by itself once no container is running; until then a lower pool is
    /// applied through the balloon, which the guest may deflate under pressure.
    @discardableResult
    public func applyResources(_ resources: WovenVMResources) async throws -> WovenVMStatus {
        try await call("PUT", "/v1/resources", body: resources, as: WovenVMStatus.self)
    }

    /// Woven's Update action for the VM: snapshot, update, health check,
    /// rollback on failure. Returns at once; follow `status()`.
    @discardableResult
    public func update() async throws -> WovenVMStatus {
        try await call("POST", "/v1/update", as: WovenVMStatus.self)
    }

    public func restart() async throws {
        _ = try await call("POST", "/v1/restart", as: WovenVMStatus.self)
    }

    /// Shuts the guest down, stops the helper and removes the launch agent, so
    /// nothing starts at the next login. `ensureRunning()` brings it back.
    public func stop() async throws {
        _ = try? await call("POST", "/v1/stop", as: WovenVMStatus.self)
        try await Self.background { [self] in
            let deadline = Date() + 60
            while FileManager.default.fileExists(atPath: controlSocket.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
            if try launchctl(["print", service]) == 0 { _ = try launchctl(["bootout", service]) }
            try? FileManager.default.removeItem(at: launchAgentPlist)
        }
    }

    /// Stops everything and deletes every VM file: disks, snapshot, logs and sockets.
    public func uninstall() async throws {
        try await stop()
        try await Self.background { [self] in
            for directory in Set([paths.root, paths.socketDirectory]) where FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    // MARK: Previews

    /// Publishes a container port on `127.0.0.1:<hostPort>`. Idempotent for the
    /// same target. Forwards survive helper and VM restarts.
    public func forwardPreview(_ request: WovenVMForwardRequest) async throws -> WovenVMForward {
        try await call("POST", "/v1/forwards", body: try request.validated(), as: WovenVMForward.self)
    }

    public func unforwardPreview(id: String) async throws {
        guard id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw WovenVMError.invalid("Unknown forward.") }
        _ = try await raw("DELETE", "/v1/forwards/" + id, body: nil)
    }

    public func forwards() async throws -> [WovenVMForward] {
        try await call("GET", "/v1/forwards", as: [WovenVMForward].self)
    }

    // MARK: Transport

    private func call<Reply: Decodable>(_ method: String, _ path: String, body: (some Encodable)? = Optional<Int>.none,
                                        as type: Reply.Type) async throws -> Reply {
        let data = try body.map { try JSONEncoder().encode($0) }
        let reply = try await raw(method, path, body: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Reply.self, from: reply)
    }

    private func raw(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let socketPath = controlSocket.path
        return try await Self.background {
            let (status, reply) = try Self.exchange(socketPath: socketPath, method: method, path: path, body: body ?? Data())
            guard (200..<300).contains(status) else {
                let message = (try? JSONDecoder().decode(WovenVMControlHTTP.ErrorBody.self, from: reply))?.error
                throw status == 409 || status == 503
                    ? WovenVMError.unavailable(message ?? "The Woven VM is busy.")
                    : WovenVMError.failed(message ?? "The Woven VM helper returned \(status).")
            }
            return reply
        }
    }

    static func exchange(socketPath: String, method: String, path: String, body: Data,
                         timeout: Int = 30) throws -> (Int, Data) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WovenVMError.unavailable("No socket is available.") }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw WovenVMError.invalid("The socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw WovenVMError.unavailable("The Woven VM helper is not running.") }
        var request = Data("\(method) \(path) HTTP/1.1\r\nHost: woven-vm\r\nConnection: close\r\nContent-Length: \(body.count)\r\n".utf8)
        if !body.isEmpty { request += Data("Content-Type: application/json\r\n".utf8) }
        request += Data("\r\n".utf8) + body
        try request.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw WovenVMError.unavailable("The Woven VM helper closed the connection.") }
                offset += written
            }
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            reply.append(chunk, count: count)
        }
        let parsed = try WovenVMControlHTTP.parseResponse(reply)
        return (parsed.status, parsed.body)
    }

    private func checked(_ status: Int32, _ action: String) throws {
        guard status == 0 else {
            throw WovenVMError.failed("The Woven VM service could not be \(action) (launchctl \(status)).")
        }
    }

    private static func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private static func runLaunchctl(_ arguments: [String]) throws -> Int32 {
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
}
