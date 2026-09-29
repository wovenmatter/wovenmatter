import Darwin
import Foundation
import IOKit.ps

/// The helper's only privileged operation. Arguments and journal location are
/// constants; neither an XPC client nor user preferences can supply a path.
enum ClosedLidSystemPower {
    static func source() -> WorkPowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let value = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return .unknown }
        switch value {
        case kIOPSACPowerValue: return .external
        case kIOPSBatteryPowerValue: return .battery
        default: return .unknown
        }
    }

    static func readDisabled() throws -> Bool { try parseDisabled(run(["-g"])) }

    static func parseDisabled(_ output: String) throws -> Bool {
        // An inaccessible power service can produce just the first header and
        // exit successfully. That must not be mistaken for a false baseline.
        guard output.contains("System-wide power settings:"), output.contains("Currently in use:") else {
            throw ClosedLidPowerError.unavailable("macOS power settings are unavailable.")
        }
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "SleepDisabled" else { continue }
            guard fields.count == 2, ["0", "1"].contains(fields[1]) else {
                throw ClosedLidPowerError.unavailable("macOS returned an unknown sleep setting.")
            }
            return fields[1] == "1"
        }
        // pmset omits SleepDisabled when it has never been explicitly set.
        return false
    }

    static func writeDisabled(_ disabled: Bool) throws {
        _ = try run(["-a", "disablesleep", disabled ? "1" : "0"])
        guard try readDisabled() == disabled else {
            throw ClosedLidPowerError.unavailable("macOS did not apply the sleep setting.")
        }
    }

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw ClosedLidPowerError.unavailable("The macOS power service timed out.")
        }
        guard process.terminationStatus == 0 else {
            throw ClosedLidPowerError.unavailable("The macOS power service rejected the change.")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count < 32_768, let text = String(data: data, encoding: .utf8) else {
            throw ClosedLidPowerError.unavailable("macOS returned invalid power settings.")
        }
        return text
    }
}

/// A root-owned, durable transaction marker survives app/helper crashes and
/// reboot. A marker means the previous baseline was false and must be restored.
final class ClosedLidRecoveryJournal {
    private let directory: Int32
    private let marker = "restore-sleep"
    private let owner: uid_t

    convenience init() throws {
        guard geteuid() == 0 else { throw Self.failure() }
        try self.init(path: "/private/var/db/wovenmatter-power-helper", owner: 0)
    }

    // Test fixtures use an isolated directory owned by the current test user.
    init(path: String, owner: uid_t) throws {
        self.owner = owner
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw Self.failure() }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_mode & 0o777 == 0o700,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw Self.failure()
        }
        directory = fd
    }

    deinit { close(directory) }

    func read() throws -> Bool {
        let fd = openat(directory, marker, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return false }
        guard fd >= 0 else { throw Self.failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1, info.st_size == 1 else { throw Self.failure() }
        var byte: UInt8 = 0
        guard Darwin.read(fd, &byte, 1) == 1, byte == 1 else { throw Self.failure() }
        return true
    }

    func write(_ pending: Bool) throws {
        if !pending {
            if unlinkat(directory, marker, 0) != 0 && errno != ENOENT { throw Self.failure() }
            guard fsync(directory) == 0 else { throw Self.failure() }
            return
        }
        let name = ".restore-" + UUID().uuidString
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure() }
        defer { close(fd); unlinkat(directory, name, 0) }
        var byte: UInt8 = 1
        guard Darwin.write(fd, &byte, 1) == 1, fsync(fd) == 0,
              renameat(directory, name, directory, marker) == 0,
              fsync(directory) == 0 else { throw Self.failure() }
    }

    private static func failure() -> ClosedLidPowerError {
        .unavailable("The power helper recovery journal is unavailable.")
    }
}
