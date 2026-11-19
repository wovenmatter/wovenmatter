import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Mac access status record")
struct MacAccessTests {
  @Test("sessions name the Mac and the missing permission, on this and other devices")
  func sessionNotice() {
    let status = MacAccessStatus(items: [.fullDiskAccess: .needsAttention, .keychain: .ready, .accessibility: .needsAttention])
    #expect(status.sessionNotice(deviceName: "Mac Mini", isThisDevice: false)
      == "Mac Mini is missing Full Disk Access for Woven Matter. Open Settings → Permissions & Access on that Mac.")
    #expect(status.sessionNotice(deviceName: "Mac Mini", isThisDevice: true, computerUse: true)
      == "This Mac is missing Full Disk Access and Accessibility for Woven Matter. Open Settings → Permissions & Access to set it up.")
    #expect(MacAccessStatus(items: [.fullDiskAccess: .ready, .keychain: .unknown])
      .sessionNotice(deviceName: "Mac Mini", isThisDevice: false) == nil)
  }

  @Test("a blank app name never reaches the notice")
  func blankAppName() {
    #expect(MacAccessStatus.appName(displayName: "", bundleName: "Woven Matter e2e snapshot Dev") == "Woven Matter e2e snapshot Dev")
    #expect(MacAccessStatus.appName(displayName: " ", bundleName: nil) == "Woven Matter")
    #expect(MacAccessStatus.appName(displayName: "Woven Matter", bundleName: "Other") == "Woven Matter")
  }

  @Test("the record travels inside the workspace descriptor")
  func workspaceRoundTrip() throws {
    let status = MacAccessStatus(items: [.screenRecording: .ready, .automation: .needsAttention], appName: "Woven Matter Dev")
    let workspace = ExecutionWorkspace(id: "w", libraryID: "l", ownerDeviceID: "o", kind: .mac, name: "Mac Mini", macAccess: status)
    let decoded = try JSONDecoder().decode(ExecutionWorkspace.self, from: JSONEncoder().encode(workspace))
    #expect(decoded.macAccess == status)
    // An item the Mac did not report is not known to be missing.
    #expect(decoded.macAccess?.state(.accessibility) == .unknown)
    #expect(decoded.macAccess?.missing(computerUse: true) == [])
  }
}
