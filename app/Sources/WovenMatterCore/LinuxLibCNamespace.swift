#if !canImport(Darwin)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Mac sources qualify system calls as `Darwin.read` to avoid colliding with
// methods of the same name. On Linux the same spellings forward to the C
// library, so shared library code needs no per-call platform branches.
private func libcClose(_ fd: Int32) -> Int32 { close(fd) }
private func libcRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { read(fd, buffer, count) }
private func libcWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { write(fd, buffer, count) }
private func libcConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 { connect(fd, address, length) }
private func libcBind(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 { bind(fd, address, length) }
private func libcPoll(_ fds: UnsafeMutablePointer<pollfd>?, _ count: nfds_t, _ timeout: Int32) -> Int32 { poll(fds, count, timeout) }
private func libcRename(_ old: UnsafePointer<CChar>, _ new: UnsafePointer<CChar>) -> Int32 { rename(old, new) }
private func libcOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 { open(path, flags, mode) }
private func libcKill(_ pid: pid_t, _ signal: Int32) -> Int32 { kill(pid, signal) }
private func libcFchmod(_ fd: Int32, _ mode: mode_t) -> Int32 { fchmod(fd, mode) }
private func libcLockf(_ fd: Int32, _ command: Int32, _ length: off_t) -> Int32 { lockf(fd, command, length) }
private func libcFsync(_ fd: Int32) -> Int32 { fsync(fd) }
private func libcMemchr(_ pointer: UnsafeRawPointer, _ value: Int32, _ count: Int) -> UnsafeMutableRawPointer? { memchr(pointer, value, count) }
private func libcSignal(_ number: Int32, _ handler: (@convention(c) (Int32) -> Void)?) -> (@convention(c) (Int32) -> Void)? {
  signal(number, handler)
}

public enum Darwin {
  @discardableResult public static func close(_ fd: Int32) -> Int32 { libcClose(fd) }
  public static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { libcRead(fd, buffer, count) }
  public static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { libcWrite(fd, buffer, count) }
  public static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 { libcConnect(fd, address, length) }
  public static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 { libcBind(fd, address, length) }
  public static func poll(_ fds: UnsafeMutablePointer<pollfd>?, _ count: nfds_t, _ timeout: Int32) -> Int32 { libcPoll(fds, count, timeout) }
  public static func rename(_ old: UnsafePointer<CChar>, _ new: UnsafePointer<CChar>) -> Int32 { libcRename(old, new) }
  public static func open(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t = 0) -> Int32 { libcOpen(path, flags, mode) }
  public static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 { libcKill(pid, signal) }
  public static func fchmod(_ fd: Int32, _ mode: mode_t) -> Int32 { libcFchmod(fd, mode) }
  @discardableResult public static func lockf(_ fd: Int32, _ command: Int32, _ length: off_t) -> Int32 { libcLockf(fd, command, length) }
  public static func fsync(_ fd: Int32) -> Int32 { libcFsync(fd) }
  public static func memchr(_ pointer: UnsafeRawPointer, _ value: Int32, _ count: Int) -> UnsafeMutableRawPointer? { libcMemchr(pointer, value, count) }
  public static func signal(_ number: Int32, _ handler: (@convention(c) (Int32) -> Void)?) -> (@convention(c) (Int32) -> Void)? {
    libcSignal(number, handler)
  }
}
#endif
