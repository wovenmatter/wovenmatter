import Darwin
import Foundation

enum LocalACPProcessLeaseAcquisition: Equatable {
    case acquired
    case retained
    case unavailable
}

protocol LocalACPProcessLeasing: AnyObject, Sendable {
    func acquire() throws -> LocalACPProcessLeaseAcquisition
    func release()
}

final class LocalACPProcessLease: LocalACPProcessLeasing, @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var holdCount = 0

    init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = fileURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let chmodError = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: chmodError) ?? .EIO)
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func acquire() throws -> LocalACPProcessLeaseAcquisition {
        try lock.withLock {
            if holdCount > 0 {
                holdCount += 1
                return .retained
            }
            guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
                if errno == EACCES || errno == EAGAIN {
                    return .unavailable
                }
                throw Self.currentPOSIXError()
            }
            holdCount = 1
            return .acquired
        }
    }

    func release() {
        lock.withLock {
            guard holdCount > 0 else { return }
            holdCount -= 1
            if holdCount == 0 {
                _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
