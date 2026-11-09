// The Woven VM is macOS only (Virtualization framework); Linux library builds skip it.
#if os(macOS)
import CryptoKit
import Foundation

/// The pinned guest selection, `app/VMHelper/guest-version.json`, bundled at
/// `Contents/Resources/WovenVM/guest-version.json`. See docs/DEPENDENCIES.md.
public struct WovenVMGuestVersion: Codable, Sendable, Equatable {
    public struct Image: Codable, Sendable, Equatable {
        public var name: String
        public var serial: String
        public var url: URL
        public var sha256: String
        public var size: UInt64
    }
    public struct Docker: Codable, Sendable, Equatable {
        public var repository: URL
        public var suite: String
        public var keyFingerprint: String
        public var keySha256: String
        public var dockerCE: String
        public var containerd: String
        /// "5:29.9.3-1~ubuntu.26.04~resolute" reports itself as "29.9.3".
        public var engineVersion: String {
            let epochless = dockerCE.split(separator: ":", maxSplits: 1).last.map(String.init) ?? dockerCE
            return String(epochless.prefix { $0 != "-" })
        }
    }
    public var guestVersion: Int
    public var image: Image
    public var docker: Docker
}

/// Builds what the guest receives: the cloud-init NoCloud seed on first boot,
/// and the same files over the agent on every Woven update.
public enum WovenVMGuestFiles {
    /// Bundle file name, guest path and mode. Everything the guest runs is here.
    public static let layout: [(name: String, path: String, mode: String)] = [
        ("agent.py", "/usr/local/lib/woven/agent.py", "0755"),
        ("provision.sh", "/usr/local/lib/woven/provision.sh", "0755"),
        ("egress.sh", "/usr/local/lib/woven/egress.sh", "0755"),
        ("disk-cap.sh", "/usr/local/lib/woven/disk-cap.sh", "0755"),
        ("woven-agent.service", "/etc/systemd/system/woven-agent.service", "0644"),
        ("woven-provision.service", "/etc/systemd/system/woven-provision.service", "0644"),
        ("woven-update.service", "/etc/systemd/system/woven-update.service", "0644"),
        ("woven-egress.service", "/etc/systemd/system/woven-egress.service", "0644"),
        ("docker-archive-keyring.asc", "/etc/apt/keyrings/docker.asc", "0644")
    ]
    public static let versionsPath = "/etc/woven/versions.env"

    public static func loadVersion(resources: URL) throws -> WovenVMGuestVersion {
        try JSONDecoder().decode(WovenVMGuestVersion.self,
                                 from: Data(contentsOf: resources.appending(path: "guest-version.json")))
    }

    public static func versionsEnvironment(_ version: WovenVMGuestVersion) -> String {
        // Values are single-quoted for the shell; none of the pinned strings
        // contain quotes, and the record is reviewed in maintenance.
        """
        WOVEN_GUEST_VERSION='\(version.guestVersion)'
        DOCKER_REPOSITORY='\(version.docker.repository.absoluteString)'
        DOCKER_SUITE='\(version.docker.suite)'
        DOCKER_CE_VERSION='\(version.docker.dockerCE)'
        CONTAINERD_VERSION='\(version.docker.containerd)'

        """
    }

    /// Guest path to contents, verifying the Docker signing key against the record.
    public static func files(resources: URL, version: WovenVMGuestVersion) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for entry in layout {
            let data = try Data(contentsOf: resources.appending(path: entry.name))
            if entry.name == "docker-archive-keyring.asc" {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == version.docker.keySha256.lowercased() else {
                    throw WovenVMError.invalid("The bundled Docker signing key does not match its record.")
                }
            }
            files[entry.path] = data
        }
        files[versionsPath] = Data(versionsEnvironment(version).utf8)
        return files
    }

    public static func userData(files: [String: Data], diskCapBytes: UInt64) -> String {
        let modes = Dictionary(uniqueKeysWithValues: layout.map { ($0.path, $0.mode) })
        var entries = files.keys.sorted().map { path in
            """
              - path: \(path)
                permissions: "\(modes[path] ?? "0644")"
                encoding: b64
                content: \(files[path]!.base64EncodedString())
            """
        }
        entries.append("""
          - path: /etc/woven/disk-cap
            permissions: "0644"
            content: "\(diskCapBytes)"
        """)
        // No user, password or SSH key: the Mac reaches the guest over vsock only.
        return """
        #cloud-config
        hostname: woven-vm
        ssh_pwauth: false
        disable_root: true
        users: []
        package_update: false
        package_upgrade: false
        growpart:
          mode: auto
          devices: ["/"]
        resize_rootfs: true
        write_files:
        \(entries.joined(separator: "\n"))
        runcmd:
          - [systemctl, daemon-reload]
          - [systemctl, enable, --now, woven-agent.service]
          - [systemctl, enable, woven-provision.service, woven-egress.service]
          - [systemctl, start, --no-block, woven-provision.service]

        """
    }

    public static func metaData(instanceID: String) -> String {
        "instance-id: \(instanceID)\nlocal-hostname: woven-vm\n"
    }
}

/// Returns unused guest memory to the Mac. Virtualization's balloon offers no
/// free page reporting, and measurement shows it frees ballooned pages on the
/// Mac only while they stay in the balloon: deflating re-commits them. So the
/// balloon follows the guest's demand instead of pulsing: it holds everything
/// above what the guest uses (anonymous and unreclaimable memory; page cache
/// counts as free) plus headroom, grows back at once when the guest needs
/// more, and shrinks only after demand has stayed lower for a while.
public enum WovenVMBalloonPolicy {
    /// Lowering waits this long so a bot's bursts do not thrash the balloon.
    public static let lowerAfter: TimeInterval = 30
    public static let lowerStep: UInt64 = 256 << 20

    public static func headroom(ceiling: UInt64) -> UInt64 { max(1 << 30, ceiling / 4) }

    /// The guest memory target the demand calls for. `current` is the target
    /// in effect; with deflate-on-OOM, Linux counts ballooned pages as used in
    /// MemTotal - MemAvailable, so they are subtracted to get the demand.
    public static func desiredTarget(ceiling: UInt64, booted: UInt64, current: UInt64,
                                     guestTotal: UInt64, guestAvailable: UInt64) -> UInt64 {
        // Under pressure, give the whole pool back at once.
        if guestAvailable < headroom(ceiling: ceiling) / 2 { return ceiling / (1 << 20) * (1 << 20) }
        let ballooned = booted > current ? booted - current : 0
        let used = guestTotal > guestAvailable ? guestTotal - guestAvailable : 0
        let demand = used > ballooned ? used - ballooned : 0
        let floor = min(ceiling, 1536 << 20)
        return min(ceiling, max(floor, demand + headroom(ceiling: ceiling))) / (1 << 20) * (1 << 20)
    }

    /// Applies hysteresis: raise at once, lower only after `lowerAfter` of
    /// steadily lower demand. Returns the new target and the pending-lower start.
    public static func next(current: UInt64, desired: UInt64, lowerSince: Date?, now: Date) -> (target: UInt64, lowerSince: Date?) {
        if desired >= current { return (desired, nil) }
        guard current - desired >= lowerStep else { return (current, nil) }
        let since = lowerSince ?? now
        return now.timeIntervalSince(since) >= lowerAfter ? (desired, nil) : (current, since)
    }

    /// Memory the running VM may use: the boot size, or a lower pool applied
    /// live until the next restart.
    public static func ceiling(bootedBytes: UInt64, requestedBytes: UInt64) -> UInt64 {
        min(bootedBytes, max(requestedBytes, WovenVMResources.minimumMemoryBytes))
    }
}

/// Size limits shared by the helper and the app's settings validation.
public enum WovenVMSizing {
    /// VZ needs whole MiB.
    public static func memoryBytes(requested: UInt64?, physical: UInt64, maximumAllowed: UInt64) -> UInt64 {
        let wanted = min(requested ?? physical, physical, maximumAllowed)
        let clamped = max(wanted, WovenVMResources.minimumMemoryBytes)
        return clamped / (1 << 20) * (1 << 20)
    }

    public static func validate(_ resources: WovenVMResources, physicalMemory: UInt64, diskTotal: UInt64) throws {
        if let memory = resources.memoryBytes {
            guard memory >= WovenVMResources.minimumMemoryBytes, memory <= physicalMemory else {
                throw WovenVMError.invalid("The RAM pool must be between 1 GB and this Mac's memory.")
            }
        }
        if let disk = resources.diskBytes {
            guard disk >= WovenVMResources.minimumDiskBytes, disk <= diskTotal else {
                throw WovenVMError.invalid("The bot disk cap must be between 10 GB and the disk's size.")
            }
        }
    }
}
#endif
