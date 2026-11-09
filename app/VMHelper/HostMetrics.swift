import Darwin
import Foundation

enum HostMetrics {
    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    static func volume(containing url: URL) -> (total: UInt64, free: UInt64) {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (UInt64(values?.volumeTotalCapacity ?? 0), UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0)))
    }

    /// Blocks a sparse file really occupies.
    static func allocatedBytes(_ url: URL) -> UInt64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return UInt64(info.st_blocks) * 512
    }

    /// Virtualization.framework runs the guest in its own XPC process. The one
    /// holding this VM's disk image open is ours; its physical footprint is
    /// what the VM costs the Mac.
    static func virtualMachineProcess(holding disk: URL) -> pid_t? {
        // Compare by file identity: /tmp and /private/tmp spellings differ.
        var target = stat()
        guard stat(disk.path, &target) == 0 else { return nil }
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            // proc_name is truncated to 16 bytes; the full path is not.
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  text(path).hasSuffix("/com.apple.Virtualization.VirtualMachine") else { continue }
            if process(pid, holdsDevice: UInt64(target.st_dev), inode: UInt64(target.st_ino)) { return pid }
        }
        return nil
    }

    private static func process(_ pid: pid_t, holdsDevice device: UInt64, inode: UInt64) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return false }
        for descriptor in descriptors.prefix(Int(filled) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                      Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard read > 0 else { continue }
            let stat = info.pvip.vip_vi.vi_stat
            if UInt64(stat.vst_dev) == device && stat.vst_ino == inode { return true }
        }
        return false
    }

    private static func text(_ bytes: [CChar]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func footprint(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }

    /// Every address of this Mac, so the guest can refuse container traffic to
    /// the Mac even on a public or otherwise unlisted address.
    static func addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result = Set<String>()
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let text = text(host).split(separator: "%").first.map(String.init) ?? ""
            if text.isEmpty || text == "127.0.0.1" || text == "::1" || text.hasPrefix("fe80:") { continue }
            result.insert(text)
        }
        return result.sorted()
    }
}
