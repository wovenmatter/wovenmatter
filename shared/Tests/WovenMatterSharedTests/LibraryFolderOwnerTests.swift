import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Folder owner resolution")
struct LibraryFolderOwnerTests {
  // The central Mac's registry id and host device id are random and unrelated
  // to the `device:<dashboard device id>` owner its folders are bound to.
  let registryID = "3b7d3c64-6f0b-4f5b-9a55-1d1f0c3c2a10"
  let hostDeviceID = "8d1c2f5e-0a3b-4c6d-8e9f-112233445566"
  let dashboardDeviceID = "C0FFEE00-1234-4abc-8def-0123456789AB"

  func mac(folderOwnerID: String?) -> ExecutionWorkspace {
    .init(id: registryID, libraryID: "library", ownerDeviceID: hostDeviceID, kind: .mac, name: "Mac Mini",
          executionDeviceID: hostDeviceID, folderOwnerID: folderOwnerID)
  }

  @Test("a central Mac's folders resolve to its registry row through folderOwnerID")
  func centralMacFolders() {
    let owner = "device:" + dashboardDeviceID
    #expect(ExecutionWorkspace.displayOwner(of: owner, in: [mac(folderOwnerID: nil)]) == nil,
            "Without the published owner the folders cannot be placed")
    #expect(ExecutionWorkspace.displayOwner(of: owner, in: [mac(folderOwnerID: owner)]) == registryID)
  }

  @Test("prefixed and bare ids still match their own row; an own id beats another row's claim")
  func ownIDsWin() {
    let linuxID = UUID().uuidString.lowercased()
    let linux = ExecutionWorkspace(id: linuxID, libraryID: "library", ownerDeviceID: hostDeviceID, kind: .linux, name: "Linux")
    let claimant = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: hostDeviceID,
                                               kind: .mac, name: "Other", folderOwnerID: "device:" + linuxID)
    #expect(ExecutionWorkspace.displayOwner(of: "remote:" + linuxID.uppercased(), in: [claimant, linux]) == linuxID)
    #expect(ExecutionWorkspace.displayOwner(of: "device:" + registryID, in: [mac(folderOwnerID: nil)]) == registryID)
  }

  @Test("a live row wins over a retained snapshot copy and deleted rows never claim")
  func liveClaimWins() {
    let owner = "device:" + dashboardDeviceID
    var retained = mac(folderOwnerID: owner); retained.id = UUID().uuidString.lowercased(); retained.retainedHistory = true
    var deleted = mac(folderOwnerID: owner); deleted.id = UUID().uuidString.lowercased(); deleted.deleted = true
    #expect(ExecutionWorkspace.displayOwner(of: owner, in: [retained, deleted, mac(folderOwnerID: owner)]) == registryID)
    #expect(ExecutionWorkspace.displayOwner(of: owner, in: [deleted]) == nil)
  }

  @Test("the field round-trips and older records decode without it")
  func wire() throws {
    let workspace = mac(folderOwnerID: "device:" + dashboardDeviceID)
    let decoded = try JSONDecoder().decode(ExecutionWorkspace.self, from: JSONEncoder().encode(workspace))
    #expect(decoded.folderOwnerID == workspace.folderOwnerID)
    let legacy = try JSONDecoder().decode(ExecutionWorkspace.self, from: Data(#"{"id":"w","libraryID":"l","ownerDeviceID":"o","kind":"mac","name":"Mac","capabilities":[],"journalDeviceIDs":[],"revision":1,"deleted":false}"#.utf8))
    #expect(legacy.folderOwnerID == nil)
    #expect(ExecutionWorkspace.isValidFolderOwnerID("device:" + dashboardDeviceID))
    #expect(!ExecutionWorkspace.isValidFolderOwnerID("remote:" + dashboardDeviceID))
    #expect(!ExecutionWorkspace.isValidFolderOwnerID("device:unavailable"))
  }
}
