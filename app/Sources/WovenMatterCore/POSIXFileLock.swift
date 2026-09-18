import Darwin
import Foundation

public extension POSIXError {
    /// The error described by the current `errno`.
    static var current: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

public enum POSIXFileLock {
    /// Holds an exclusive advisory lock on `url` for the duration of
    /// `operation`, creating the file if needed and keeping it at mode 0600.
    public static func withExclusive<T>(
        at url: URL,
        _ operation: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw POSIXError.current }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw POSIXError.current
        }
        defer { Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try operation()
    }
}
