import Foundation
import WovenLibrary
import WovenProtocol

/// Folders: a name plus a directory on the machine that owns it. A folder is
/// created by the server of the machine that will own it, so a new blank
/// directory is made on that machine's own disk.
func registerFolders(_ router: inout Router, library: Library, root: URL) {
  router.on(ListFolders.self) { request, _ in
    try await library.folders(machineID: request.machineID)
  }
  router.on(CreateFolder.self) { request, _ in
    let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw ProtocolError(.badRequest, "A folder needs a name.") }
    let path: String
    if let given = request.path {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: given, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ProtocolError(.notFound, "There is no directory \(given) on this machine.")
      }
      path = given
    } else {
      path = try makeDirectory(named: name, in: root).path
    }
    return try await library.createFolder(name: name, path: path)
  }
  router.on(RenameFolder.self) { request, _ in
    try await library.renameFolder(request.folderID, to: request.name)
  }
  router.on(DeleteFolder.self) { request, _ in
    try await library.deleteFolder(request.folderID)
    return Done()
  }
}

/// A new empty directory in `root`, named after the folder; a number is
/// added when that name is taken.
private func makeDirectory(named name: String, in root: URL) throws -> URL {
  let base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  for attempt in 1...1000 {
    let url = root.appendingPathComponent(attempt == 1 ? base : "\(base) \(attempt)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      return url
    } catch CocoaError.fileWriteFileExists {
      continue
    }
  }
  throw ProtocolError(.failed, "Could not make a directory for \(name) in \(root.path).")
}
