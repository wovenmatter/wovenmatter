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
    if let given = request.path {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: given, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ProtocolError(.notFound, "There is no directory \(given) on this machine.")
      }
      return try await library.createFolder(name: name, path: given)
    }
    return try await library.createFolder(name: name, path: try makeDirectory(named: name, in: root).path, managed: true)
  }
  router.on(UpdateFolder.self) { request, _ in
    let name = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    if name?.isEmpty == true { throw ProtocolError(.badRequest, "A folder needs a name.") }
    let references = request.references?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if let references, references.contains(where: { !$0.hasPrefix("/") }) {
      throw ProtocolError(.badRequest, "Give each other directory as a full path.")
    }
    return try await library.updateFolder(request.folderID, name: name, pinned: request.pinned, position: request.position,
                                          references: references)
  }
  router.on(DeleteFolder.self) { request, _ in
    if request.deleteDirectory {
      guard let folder = try await library.folder(request.folderID) else {
        throw ProtocolError(.notFound, "No folder \(request.folderID).")
      }
      try removeManagedDirectory(of: folder, machineID: library.machineID, root: root)
    }
    try await library.deleteFolder(request.folderID)
    return Done()
  }
  router.on(ListDirectories.self) { request, _ in
    try listDirectories(request.path)
  }
}

/// Deletes the directory the server made for a folder of this machine. A
/// directory the person linked is never deleted.
private func removeManagedDirectory(of folder: Folder, machineID: String, root: URL) throws {
  guard folder.machineID == machineID else {
    throw ProtocolError(.notOwner, "Only the machine that owns \(folder.name) can delete its directory.",
                        machineID: folder.machineID)
  }
  guard folder.managed else {
    throw ProtocolError(.refused, "\(folder.name) links a directory of yours; Woven does not delete it.")
  }
  let directory = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL
  guard directory.deletingLastPathComponent().path == root.standardizedFileURL.path else {
    throw ProtocolError(.refused, "\(folder.path) is not in \(root.path), where Woven makes folders.")
  }
  guard FileManager.default.fileExists(atPath: directory.path) else { return }
  try FileManager.default.removeItem(at: directory)
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

/// At most this many directories are listed.
private let directoryLimit = 500

private func listDirectories(_ path: String?) throws -> DirectoryListing {
  let home = FileManager.default.homeDirectoryForCurrentUser
  let given = path?.trimmingCharacters(in: .whitespacesAndNewlines)
  guard given.map({ $0.isEmpty || $0.hasPrefix("/") }) ?? true else {
    throw ProtocolError(.badRequest, "\(given ?? "") is not an absolute path.")
  }
  let url = (given.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } ?? home).standardizedFileURL
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    throw ProtocolError(.notFound, "There is no directory \(url.path) on this machine.")
  }
  let contents = try FileManager.default.contentsOfDirectory(
    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
  let directories = contents
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .map { DirectoryListing.Entry(name: $0.lastPathComponent, path: $0.standardizedFileURL.path) }
    .sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
  let parent = url.path == "/" ? nil : url.deletingLastPathComponent().standardizedFileURL.path
  return DirectoryListing(path: url.path, parent: parent, directories: Array(directories.prefix(directoryLimit)),
                          truncated: directories.count > directoryLimit)
}
