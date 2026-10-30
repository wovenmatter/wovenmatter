import Foundation
import XCTest
import WovenMatterCompanion
@testable import CompanionClient

final class WorkspaceCredentialPolicyTests: XCTestCase {
  private let device = UUID().uuidString.lowercased(), own = UUID().uuidString.lowercased(), foreign = UUID().uuidString.lowercased()
  private let endpoint = URL(string: "https://mini.fixture.ts.net/wovenmatter")!

  private func credential(library: String, workspace: String = "w", device: String? = nil, endpoint: URL? = nil) -> DirectWorkspaceCredential {
    .init(endpoint: endpoint ?? self.endpoint, libraryID: library, workspaceID: workspace, deviceID: device ?? self.device, token: String(repeating: "t", count: 43))
  }
  private func registered(library: String, endpoint: URL? = nil, deleted: Bool = false) -> CompanionExecutionWorkspace {
    var workspace = CompanionExecutionWorkspace(id: "w", libraryID: library, ownerDeviceID: UUID().uuidString.lowercased(), kind: .mac, name: "Mini",
      endpoint: endpoint ?? self.endpoint)
    workspace.deleted = deleted
    return workspace
  }

  func testOwnLibraryCredentialIsAccepted() {
    XCTAssertTrue(WorkspaceCredentialPolicy.accepts(credential(library: own), deviceID: device, libraryID: own, registered: nil))
  }

  func testAnotherMacsWorkspaceKeepsItsRegisteredNamespace() {
    // A workspace another paired Mac owns: the phone renews and reuses its grant.
    XCTAssertTrue(WorkspaceCredentialPolicy.accepts(credential(library: foreign), deviceID: device, libraryID: own, registered: registered(library: foreign)))
  }

  func testForeignCredentialsThatDoNotMatchTheRegistrationAreRejected() {
    XCTAssertFalse(WorkspaceCredentialPolicy.accepts(credential(library: foreign), deviceID: device, libraryID: own, registered: nil))
    XCTAssertFalse(WorkspaceCredentialPolicy.accepts(credential(library: foreign), deviceID: device, libraryID: own,
      registered: registered(library: UUID().uuidString.lowercased())))
    XCTAssertFalse(WorkspaceCredentialPolicy.accepts(credential(library: foreign), deviceID: device, libraryID: own,
      registered: registered(library: foreign, endpoint: URL(string: "https://elsewhere.fixture.ts.net/wovenmatter")!)))
    XCTAssertFalse(WorkspaceCredentialPolicy.accepts(credential(library: foreign), deviceID: device, libraryID: own, registered: registered(library: foreign, deleted: true)))
    XCTAssertFalse(WorkspaceCredentialPolicy.accepts(credential(library: own, device: UUID().uuidString.lowercased()), deviceID: device, libraryID: own, registered: nil))
  }
}
