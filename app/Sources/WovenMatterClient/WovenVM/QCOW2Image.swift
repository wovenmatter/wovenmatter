import Compression
import Darwin
import Foundation

/// Converts the official Ubuntu cloud image (QCOW2 v2/v3, zlib clusters) to the
/// raw disk Virtualization.framework boots. The download is checksum-verified
/// first, so this only has to be correct, not defensive against hostile input
/// beyond bounds checks. Unallocated and zero clusters stay holes, which keeps
/// the output sparse on APFS.
public enum QCOW2Image {
    public struct Header: Equatable {
        public var clusterBits: Int
        public var virtualSize: UInt64
        public var l1Size: Int
        public var l1Offset: UInt64
    }

    public static func readHeader(_ fd: Int32) throws -> Header {
        var bytes = [UInt8](repeating: 0, count: 112)
        let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 112, 0) }
        guard count >= 72 else { throw WovenVMError.invalid("The guest image is too short to be QCOW2.") }
        func u32(_ at: Int) -> UInt32 { bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func u64(_ at: Int) -> UInt64 { bytes[at..<at + 8].reduce(0) { $0 << 8 | UInt64($1) } }
        guard u32(0) == 0x5146_49fb else { throw WovenVMError.invalid("The guest image is not QCOW2.") }
        let version = u32(4)
        guard version == 2 || version == 3 else { throw WovenVMError.invalid("QCOW2 version \(version) is not supported.") }
        guard u64(8) == 0 else { throw WovenVMError.invalid("QCOW2 backing files are not supported.") }
        guard u32(32) == 0 else { throw WovenVMError.invalid("Encrypted QCOW2 images are not supported.") }
        if version == 3 {
            guard count >= 104 else { throw WovenVMError.invalid("The QCOW2 header is truncated.") }
            let incompatible = u64(72), headerLength = Int(u32(100))
            // Only bit 3 (an explicit compression type) is understood, and only
            // when that type is zlib.
            guard incompatible & ~UInt64(1 << 3) == 0 else {
                throw WovenVMError.invalid("The QCOW2 image uses unsupported features.")
            }
            if incompatible & (1 << 3) != 0 {
                guard headerLength > 104, count > 104, bytes[104] == 0 else {
                    throw WovenVMError.invalid("Only zlib-compressed QCOW2 images are supported.")
                }
            }
        }
        let clusterBits = Int(u32(20))
        guard (9...21).contains(clusterBits) else { throw WovenVMError.invalid("The QCOW2 cluster size is not valid.") }
        return Header(clusterBits: clusterBits, virtualSize: u64(24), l1Size: Int(u32(36)), l1Offset: u64(40))
    }

    /// Writes the raw image to `output`, which must not exist. Progress is the
    /// fraction of guest clusters processed.
    public static func convert(_ input: URL, to output: URL, progress: (Double) -> Void = { _ in }) throws {
        let source = open(input.path, O_RDONLY | O_CLOEXEC)
        guard source >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(source) }
        let destination = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var completed = false
        defer {
            close(destination)
            if !completed { unlink(output.path) }
        }
        var info = stat()
        guard fstat(source, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let fileSize = UInt64(info.st_size)

        let header = try readHeader(source)
        let clusterSize = 1 << header.clusterBits
        let entriesPerTable = clusterSize / 8
        let totalClusters = Int((header.virtualSize + UInt64(clusterSize) - 1) / UInt64(clusterSize))
        guard header.l1Size >= (totalClusters + entriesPerTable - 1) / entriesPerTable,
              header.l1Offset + UInt64(header.l1Size) * 8 <= fileSize else {
            throw WovenVMError.invalid("The QCOW2 L1 table is not valid.")
        }
        let l1 = try readTable(source, offset: header.l1Offset, count: header.l1Size)
        let offsetMask: UInt64 = 0x00ff_ffff_ffff_fe00
        let compressedOffsetBits = 62 - (header.clusterBits - 8)
        var cluster = [UInt8](repeating: 0, count: clusterSize)
        var compressed = [UInt8](repeating: 0, count: clusterSize * 2 + 512)
        var processed = 0

        for (l1Index, l1Entry) in l1.enumerated() {
            let firstCluster = l1Index * entriesPerTable
            guard firstCluster < totalClusters else { break }
            let tableOffset = l1Entry & offsetMask
            if tableOffset == 0 {
                processed = min(totalClusters, firstCluster + entriesPerTable)
                continue
            }
            guard tableOffset + UInt64(clusterSize) <= fileSize else { throw WovenVMError.invalid("A QCOW2 L2 table is out of range.") }
            let l2 = try readTable(source, offset: tableOffset, count: entriesPerTable)
            for (l2Index, entry) in l2.enumerated() {
                let guestCluster = firstCluster + l2Index
                guard guestCluster < totalClusters else { break }
                processed = guestCluster + 1
                if processed % 4096 == 0 { progress(Double(processed) / Double(totalClusters)) }
                let guestOffset = off_t(guestCluster) * off_t(clusterSize)
                if entry & (1 << 62) != 0 {
                    let hostOffset = entry & ((1 << UInt64(compressedOffsetBits)) - 1)
                    let sectors = (entry >> UInt64(compressedOffsetBits)) & ((1 << UInt64(62 - compressedOffsetBits)) - 1)
                    var length = Int((sectors + 1) * 512 - (hostOffset & 511))
                    guard hostOffset < fileSize, length <= compressed.count else {
                        throw WovenVMError.invalid("A compressed QCOW2 cluster is out of range.")
                    }
                    length = min(length, Int(fileSize - hostOffset))
                    try readExactly(source, into: &compressed, count: length, offset: hostOffset)
                    let decoded = cluster.withUnsafeMutableBufferPointer { output in
                        compressed.withUnsafeBufferPointer { input in
                            compression_decode_buffer(output.baseAddress!, clusterSize, input.baseAddress!, length,
                                                      nil, COMPRESSION_ZLIB)
                        }
                    }
                    guard decoded == clusterSize else { throw WovenVMError.invalid("A compressed QCOW2 cluster did not decode.") }
                } else {
                    let hostOffset = entry & offsetMask
                    // Unallocated, or the v3 "reads as zeros" flag: leave a hole.
                    if hostOffset == 0 || entry & 1 != 0 { continue }
                    guard hostOffset + UInt64(clusterSize) <= fileSize else {
                        throw WovenVMError.invalid("A QCOW2 data cluster is out of range.")
                    }
                    try readExactly(source, into: &cluster, count: clusterSize, offset: hostOffset)
                }
                if isZero(cluster) { continue }
                let length = Int(min(UInt64(clusterSize), header.virtualSize - UInt64(guestOffset)))
                try cluster.withUnsafeBytes { buffer in
                    var written = 0
                    while written < length {
                        let result = pwrite(destination, buffer.baseAddress! + written, length - written,
                                            guestOffset + off_t(written))
                        guard result > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                        written += result
                    }
                }
            }
        }
        guard ftruncate(destination, off_t(header.virtualSize)) == 0, fsync(destination) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        progress(1)
        completed = true
    }

    private static func readTable(_ fd: Int32, offset: UInt64, count: Int) throws -> [UInt64] {
        var bytes = [UInt8](repeating: 0, count: count * 8)
        try readExactly(fd, into: &bytes, count: bytes.count, offset: offset)
        return (0..<count).map { index in bytes[index * 8..<index * 8 + 8].reduce(0) { $0 << 8 | UInt64($1) } }
    }

    private static func readExactly(_ fd: Int32, into buffer: inout [UInt8], count: Int, offset: UInt64) throws {
        var done = 0
        try buffer.withUnsafeMutableBytes { pointer in
            while done < count {
                let result = pread(fd, pointer.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                guard result > 0 else {
                    if result == 0 { throw WovenVMError.invalid("The QCOW2 image ended early.") }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                done += result
            }
        }
    }

    private static func isZero(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for word in words where word != 0 { return false }
            return true
        }
    }
}
