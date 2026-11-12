import CryptoKit
import Darwin
import Foundation

/// First-run preparation: the pinned cloud image becomes the root disk, an
/// empty sparse image becomes the bots' data disk, and a NoCloud seed carries
/// the guest files. Each step is idempotent; partial outputs never keep the
/// final name.
enum GuestSetup {
    /// Room for the OS, packages and logs; bots' data lives on the data disk.
    static let rootDiskBytes: UInt64 = 16 << 30

    static func dataDiskURL(_ paths: WovenVMPaths) -> URL { paths.root.appending(path: "data.img") }

    static func download(_ image: WovenVMGuestVersion.Image, into directory: URL,
                         progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: image.sha256 + ".qcow2")
        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? verify(destination, image: image)) != nil { return destination }
            try FileManager.default.removeItem(at: destination)
        }
        let done = DispatchSemaphore(value: 0)
        let outcome = DownloadOutcome()
        let task = URLSession.shared.downloadTask(with: image.url) { location, response, error in
            defer { done.signal() }
            if let error { return outcome.set(.failure(error)) }
            guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                return outcome.set(.failure(WovenVMError.failed("The guest image download was refused.")))
            }
            do {
                try FileManager.default.moveItem(at: location, to: destination.appendingPathExtension("partial"))
                outcome.set(.success(()))
            } catch { outcome.set(.failure(error)) }
        }
        try? FileManager.default.removeItem(at: destination.appendingPathExtension("partial"))
        task.resume()
        while done.wait(timeout: .now() + 1) == .timedOut {
            let fraction = task.countOfBytesExpectedToReceive > 0
                ? Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive)
                : Double(task.countOfBytesReceived) / Double(image.size)
            progress(min(1, fraction))
        }
        try outcome.get()
        let partial = destination.appendingPathExtension("partial")
        do {
            try verify(partial, image: image)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    private final class DownloadOutcome: @unchecked Sendable {
        private var result: Result<Void, any Error> = .failure(WovenVMError.failed("The guest image download did not finish."))
        func set(_ value: Result<Void, any Error>) { result = value }
        func get() throws { try result.get() }
    }

    static func verify(_ file: URL, image: WovenVMGuestVersion.Image) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var size: UInt64 = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
            size += UInt64(chunk.count)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == image.size, digest == image.sha256.lowercased() else {
            throw WovenVMError.failed("The guest image failed checksum verification.")
        }
    }

    static func createRootDisk(from qcow2: URL, at disk: URL, progress: (Double) -> Void) throws {
        let partial = disk.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try QCOW2Image.convert(qcow2, to: partial, progress: progress)
        try resize(partial, to: rootDiskBytes, growOnly: true)
        try FileManager.default.moveItem(at: partial, to: disk)
    }

    /// The data disk is as large as the Mac's volume and sparse; the disk cap is
    /// enforced inside the guest so it can move both ways while running.
    static func ensureDataDisk(at disk: URL, bytes: UInt64) throws {
        if FileManager.default.fileExists(atPath: disk.path) {
            try resize(disk, to: bytes, growOnly: true)
            return
        }
        let partial = disk.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WovenVMError.failed("The bot disk could not be created.")
        }
        try resize(partial, to: bytes, growOnly: false)
        try FileManager.default.moveItem(at: partial, to: disk)
    }

    static func resize(_ url: URL, to bytes: UInt64, growOnly: Bool) throws {
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw Sockets.posixError("open \(url.lastPathComponent)") }
        defer { close(fd) }
        var info = stat()
        fstat(fd, &info)
        if growOnly && UInt64(info.st_size) >= bytes { return }
        guard ftruncate(fd, off_t(bytes)) == 0 else { throw Sockets.posixError("resize \(url.lastPathComponent)") }
    }

    /// An ISO 9660/Joliet volume labelled "cidata", which cloud-init's NoCloud
    /// datasource reads on first boot.
    static func createSeed(at seed: URL, userData: String, metaData: String, scratch: URL) throws {
        let folder = scratch.appending(path: "seed-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(userData.utf8).write(to: folder.appending(path: "user-data"))
        try Data(metaData.utf8).write(to: folder.appending(path: "meta-data"))
        let partial = seed.deletingPathExtension().appendingPathExtension("partial.iso")
        try? FileManager.default.removeItem(at: partial)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata",
                             "-o", partial.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WovenVMError.failed("The first-boot seed could not be created.") }
        try? FileManager.default.removeItem(at: seed)
        try FileManager.default.moveItem(at: partial, to: seed)
        chmod(seed.path, 0o600)
    }
}
