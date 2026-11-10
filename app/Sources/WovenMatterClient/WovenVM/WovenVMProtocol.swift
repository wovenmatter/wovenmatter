// The Woven VM is macOS only (Virtualization framework); Linux library builds skip it.
#if os(macOS)
import CryptoKit
import Darwin
import Foundation

// Shared by the app and the VM helper (scripts/build-vm-helper.sh compiles this
// file into the helper too), so it depends on Foundation and CryptoKit only.

/// The VM's lifecycle as the helper reports it. `failed` always carries a reason.
public enum WovenVMPhase: String, Codable, Sendable {
    case stopped, downloading, preparing, booting, provisioning, ready, updating, failed
}

/// Requested limits. `nil` means no cap: all of the Mac's RAM, or a sparse disk
/// bounded only by the volume that holds it.
public struct WovenVMResources: Codable, Sendable, Equatable {
    public var memoryBytes: UInt64?
    public var diskBytes: UInt64?
    public init(memoryBytes: UInt64? = 8 << 30, diskBytes: UInt64? = 50 << 30) {
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }
    public static let minimumMemoryBytes: UInt64 = 1 << 30
    /// The guest OS and Docker Engine need room beyond what bots use.
    public static let minimumDiskBytes: UInt64 = 10 << 30
}

/// Totals and live usage for the Bots resource UI. All values are bytes.
public struct WovenVMResourceReport: Codable, Sendable, Equatable {
    public var hostMemoryBytes: UInt64
    public var hostDiskTotalBytes: UInt64
    public var hostDiskFreeBytes: UInt64
    /// Memory the running VM was booted with (the RAM pool).
    public var vmMemoryBytes: UInt64
    /// Physical memory the VM currently holds on the Mac.
    public var vmMemoryFootprintBytes: UInt64?
    public var guestMemoryUsedBytes: UInt64?
    public var balloonTargetBytes: UInt64?
    /// The disk cap in effect inside the guest.
    public var vmDiskCapBytes: UInt64
    /// Blocks the sparse disk image actually occupies on the Mac.
    public var vmDiskAllocatedBytes: UInt64
    public var guestDiskUsedBytes: UInt64?
    /// A memory change applies when the VM next restarts; the helper restarts it
    /// on its own once no container is running.
    public var restartPending: Bool
    public init(hostMemoryBytes: UInt64, hostDiskTotalBytes: UInt64, hostDiskFreeBytes: UInt64,
                vmMemoryBytes: UInt64, vmMemoryFootprintBytes: UInt64? = nil, guestMemoryUsedBytes: UInt64? = nil,
                balloonTargetBytes: UInt64? = nil, vmDiskCapBytes: UInt64, vmDiskAllocatedBytes: UInt64,
                guestDiskUsedBytes: UInt64? = nil, restartPending: Bool = false) {
        self.hostMemoryBytes = hostMemoryBytes
        self.hostDiskTotalBytes = hostDiskTotalBytes
        self.hostDiskFreeBytes = hostDiskFreeBytes
        self.vmMemoryBytes = vmMemoryBytes
        self.vmMemoryFootprintBytes = vmMemoryFootprintBytes
        self.guestMemoryUsedBytes = guestMemoryUsedBytes
        self.balloonTargetBytes = balloonTargetBytes
        self.vmDiskCapBytes = vmDiskCapBytes
        self.vmDiskAllocatedBytes = vmDiskAllocatedBytes
        self.guestDiskUsedBytes = guestDiskUsedBytes
        self.restartPending = restartPending
    }
}

public struct WovenVMGuestInfo: Codable, Sendable, Equatable {
    public var os: String?
    public var kernel: String?
    public var docker: String?
    public var provisionedVersion: Int?
}

/// A preview forward: `127.0.0.1:hostPort` on the Mac reaches `port` on a
/// container (resolved by name or ID at connect time, so it survives restarts)
/// or on a fixed guest address.
public struct WovenVMForward: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var container: String?
    public var address: String?
    public var port: Int
    public var hostPort: Int
    public init(id: String, container: String?, address: String?, port: Int, hostPort: Int) {
        self.id = id
        self.container = container
        self.address = address
        self.port = port
        self.hostPort = hostPort
    }
}

public struct WovenVMForwardRequest: Codable, Sendable, Equatable {
    public var container: String?
    public var address: String?
    public var port: Int
    /// 0 or nil picks a free loopback port.
    public var hostPort: Int?
    public init(container: String? = nil, address: String? = nil, port: Int, hostPort: Int? = nil) {
        self.container = container
        self.address = address
        self.port = port
        self.hostPort = hostPort
    }

    public func validated() throws -> Self {
        guard (1...65_535).contains(port), (0...65_535).contains(hostPort ?? 0) else {
            throw WovenVMError.invalid("The preview port is out of range.")
        }
        switch (container, address) {
        case let (container?, nil):
            // Docker names and IDs; this also keeps the guest's one-line request
            // header unambiguous.
            guard !container.isEmpty, container.count <= 128,
                  container.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) else {
                throw WovenVMError.invalid("The container name is not valid.")
            }
        case let (nil, address?):
            var v4 = in_addr(), v6 = in6_addr()
            guard inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1 else {
                throw WovenVMError.invalid("The guest address is not an IP address.")
            }
        default:
            throw WovenVMError.invalid("Name either a container or a guest address.")
        }
        return self
    }
}

public struct WovenVMStatus: Codable, Sendable, Equatable {
    public var phase: WovenVMPhase
    /// The current step, for example "Installing Docker Engine".
    public var detail: String?
    public var failure: String?
    /// 0...1 while downloading.
    public var progress: Double?
    public var engineSocket: String
    public var resources: WovenVMResourceReport?
    public var guest: WovenVMGuestInfo?
    public var forwards: [WovenVMForward]
    /// Set when the last Woven update failed and the VM was rolled back.
    public var updateFailure: String?
    /// The disks saved before the last update (one APFS clone is kept).
    public var snapshotAvailable: Bool
    public init(phase: WovenVMPhase, detail: String? = nil, failure: String? = nil, progress: Double? = nil,
                engineSocket: String, resources: WovenVMResourceReport? = nil, guest: WovenVMGuestInfo? = nil,
                forwards: [WovenVMForward] = [], snapshotAvailable: Bool = false) {
        self.phase = phase
        self.detail = detail
        self.failure = failure
        self.progress = progress
        self.engineSocket = engineSocket
        self.resources = resources
        self.guest = guest
        self.forwards = forwards
        self.snapshotAvailable = snapshotAvailable
    }
}

public enum WovenVMError: Error, LocalizedError, Equatable {
    case invalid(String)
    case unavailable(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message), .failed(let message): message
        }
    }
}

/// Every file the VM owns lives under `root`; uninstall removes that directory,
/// the socket directory and the launch agent.
public struct WovenVMPaths: Sendable, Equatable {
    public let root: URL
    public let socketDirectory: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
        socketDirectory = Self.socketDirectory(root: self.root)
    }

    public var config: URL { root.appending(path: "config.json") }
    public var state: URL { root.appending(path: "state.json") }
    public var disk: URL { root.appending(path: "disk.img") }
    public var efiVariables: URL { root.appending(path: "efi-vars.fd") }
    public var seed: URL { root.appending(path: "seed.iso") }
    public var console: URL { root.appending(path: "console.log") }
    public var log: URL { root.appending(path: "helper.log") }
    public var downloads: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }
    public var snapshot: URL { root.appending(path: "snapshot", directoryHint: .isDirectory) }
    public var engineSocket: URL { socketDirectory.appending(path: "docker.sock") }
    public var controlSocket: URL { socketDirectory.appending(path: "control.sock") }

    /// sun_path holds 104 bytes on macOS. Development support paths can be
    /// longer, so those use a private per-user directory keyed by the root.
    static func socketDirectory(root: URL) -> URL {
        if root.appending(path: "control.sock").path.utf8.count < 100 { return root }
        let digest = SHA256.hash(data: Data(root.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/private/tmp/wovenmatter-vm-\(getuid())-\(digest)", isDirectory: true)
    }

    /// Creates `directory` (mode 0700) when missing, then requires it to be a
    /// real directory owned by this user that nobody else can enter. The short
    /// socket path lives in the shared /private/tmp, where another local user
    /// could create it first and receive the engine and control connections.
    public static func preparePrivateDirectory(_ directory: URL, create: Bool = true) throws {
        let path = directory.path
        if create, mkdir(path, 0o700) != 0, errno != EEXIST {
            throw WovenVMError.unavailable("The Woven VM socket directory could not be created.")
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw WovenVMError.unavailable("The Woven VM socket directory is missing.") }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw WovenVMError.invalid("\(path) belongs to another user or is not a directory. Remove it, then start the Woven VM again.")
        }
        if info.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 {
            throw WovenVMError.invalid("\(path) could not be made private.")
        }
    }
}

/// launchd owns the helper: unexpected exits restart it, and a clean exit
/// (stop or uninstall) leaves it stopped. Tests read the plist only.
public enum WovenVMLaunchAgent {
    public static func label(bundleIdentifier: String) -> String { bundleIdentifier + ".vm" }

    public static func plistURL(label: String,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/LaunchAgents/" + label + ".plist")
    }

    public static func propertyList(label: String, helper: URL, root: URL) -> [String: Any] {
        ["Label": label,
         "ProgramArguments": [helper.path, "--root", root.path],
         "RunAtLoad": true,
         "KeepAlive": ["SuccessfulExit": false],
         "ThrottleInterval": 5,
         // Time for a guest shutdown before launchd sends SIGKILL.
         "ExitTimeOut": 40,
         "LimitLoadToSessionType": "Aqua",
         "ProcessType": "Interactive",
         "StandardErrorPath": root.appending(path: "helper.stderr.log").path,
         "WorkingDirectory": root.path]
    }
}

/// The ports the guest agent listens on. Containers cannot open AF_VSOCK
/// sockets under Docker's default seccomp profile.
public enum WovenVMGuestPort {
    public static let agent: UInt32 = 2000
    public static let forward: UInt32 = 2001
    public static let docker: UInt32 = 2375
}
#endif
