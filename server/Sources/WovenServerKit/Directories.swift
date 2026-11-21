import Foundation
import WovenProtocol

/// The directories of this machine, for choosing a folder's.
func registerDirectories(_ router: inout Router) {
  router.on(ListDirectories.self) { request, _ in
    try listDirectories(request.path)
  }
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
