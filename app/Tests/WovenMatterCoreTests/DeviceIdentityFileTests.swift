import Foundation
import Testing
@testable import WovenMatterLibraryStore

@Suite("Device identity file")
struct DeviceIdentityFileTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "device-identity-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("a v0.4.2 dashboard-device-id moves to device-id and keeps its ID")
  func legacyFileMoves() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let saved = UUID()
    try saved.uuidString.lowercased().write(to: root.appending(path: "dashboard-device-id"), atomically: true, encoding: .utf8)
    try Data().write(to: root.appending(path: ".dashboard-device-id.lock"))
    try DeviceIdentityFile.moveLegacyFile(in: root)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "dashboard-device-id").path))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".dashboard-device-id.lock").path))
    let identity = DeviceIdentityFile(fileURL: root.appending(path: DeviceIdentityFile.fileName))
    #expect(try await identity.id() == saved)
  }

  @Test("an existing device-id wins and the legacy file is removed")
  func currentFileWins() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let current = UUID()
    try current.uuidString.lowercased().write(to: root.appending(path: "device-id"), atomically: true, encoding: .utf8)
    try UUID().uuidString.lowercased().write(to: root.appending(path: "dashboard-device-id"), atomically: true, encoding: .utf8)
    try DeviceIdentityFile.moveLegacyFile(in: root)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "dashboard-device-id").path))
    #expect(try await DeviceIdentityFile(fileURL: root.appending(path: "device-id")).id() == current)
  }
}
