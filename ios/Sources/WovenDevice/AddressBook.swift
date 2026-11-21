import Foundation

/// Where each of the person's machines answered, kept on the device in the
/// data folder and never in the library or synced: what the device dials.
struct AddressBook: Sendable {
  struct Entry: Codable, Sendable, Hashable {
    var name: String
    var host: String
    var port: Int
    /// The release it last said it runs, once it has been reached.
    var appVersion: String?
  }

  let file: URL
  private(set) var entries: [String: Entry]

  init(file: URL) {
    self.file = file
    entries = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
  }

  /// Records where a machine answers; true when that changed anything.
  @discardableResult
  mutating func set(_ machineID: String, _ entry: Entry) -> Bool {
    guard entries[machineID] != entry else { return false }
    entries[machineID] = entry
    save()
    return true
  }

  mutating func remove(_ machineID: String) {
    guard entries.removeValue(forKey: machineID) != nil else { return }
    save()
  }

  mutating func removeAll() {
    entries.removeAll()
    try? FileManager.default.removeItem(at: file)
  }

  private func save() {
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
  }
}
