import Foundation
import WovenProtocol
#if canImport(Glibc)
import Glibc
#endif
@testable import WovenServerKit

extension WovenServer {
  /// For a test's `defer`, which cannot wait: removes this server's sockets
  /// now, since the test process may exit before a stop finishes, then stops it.
  func stopLater() {
    try? FileManager.default.removeItem(at: SocketFolder.directory(for: dataFolder))
    if let socketPath { unlink(socketPath) }
    Task { await stop() }
  }
}
