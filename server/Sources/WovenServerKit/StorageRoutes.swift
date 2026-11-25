import Foundation
import WovenProtocol

/// The size and free space of the volume this server's data folder is on.
/// Each machine answers for itself.
func registerStorage(_ router: inout Router, dataFolder: URL) {
  router.on(ReadStorage.self) { _, _ in try machineStorage(dataFolder) }
}

func machineStorage(_ folder: URL) throws -> MachineStorage {
  let attributes: [FileAttributeKey: Any]
  do { attributes = try FileManager.default.attributesOfFileSystem(forPath: folder.path) } catch {
    throw ProtocolError(.failed, "The data folder's volume could not be read: \(error.localizedDescription)")
  }
  guard let size = (attributes[.systemSize] as? NSNumber)?.int64Value,
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
    throw ProtocolError(.failed, "The data folder's volume reports no size.")
  }
  return MachineStorage(capacityBytes: size, availableBytes: min(free, size))
}
