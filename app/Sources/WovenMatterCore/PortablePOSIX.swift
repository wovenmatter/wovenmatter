#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// The few socket and descriptor details that differ between Darwin and Linux.
/// Darwin branches are the original Mac calls.
public enum PortablePOSIX {
  public static var streamSocket: Int32 {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
  }

  public static var shutdownBoth: Int32 { Int32(SHUT_RDWR) }

  /// Darwin suppresses SIGPIPE per socket. Linux has no such option, so Linux
  /// hosts ignore SIGPIPE process-wide (see `ignoreBrokenPipes`) and this is a no-op.
  public static func disableBrokenPipeSignal(_ fd: Int32) -> Bool {
    #if canImport(Darwin)
    var one: Int32 = 1
    return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    #else
    return true
    #endif
  }

  public static func ignoreBrokenPipes() {
    #if !canImport(Darwin)
    _ = signal(SIGPIPE, SIG_IGN)
    #endif
  }

  /// The connecting process's user, from the kernel rather than the peer.
  public static func peerUser(_ fd: Int32) -> uid_t? {
    #if canImport(Darwin)
    var uid: uid_t = 0; var gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    #else
    // struct ucred { pid_t pid; uid_t uid; gid_t gid; }, which Glibc hides behind _GNU_SOURCE.
    var credentials: (pid_t, uid_t, gid_t) = (0, 0, 0)
    var length = socklen_t(MemoryLayout<(pid_t, uid_t, gid_t)>.size)
    return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 ? credentials.1 : nil
    #endif
  }

  public static func unixAddress(path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    return address
  }

  public static func modificationTime(_ info: stat) -> timespec {
    #if canImport(Darwin)
    info.st_mtimespec
    #else
    info.st_mtim
    #endif
  }

  /// The path of an open descriptor, used to confirm a no-follow open reached
  /// the expected file.
  public static func path(of fd: Int32) -> String? {
    #if canImport(Darwin)
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
    return String(cString: buffer)
    #else
    return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(fd)")
    #endif
  }
}
