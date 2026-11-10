import Testing
import WovenMatterCore

struct WovenMatterKeychainServiceTests {
    @Test func productionKeepsItsRemoteWorkspaceServiceAndDevBuildsUseTheirOwn() {
        #expect(WovenMatterKeychainService.remoteWorkspaces(forBundleIdentifier: "wovenmatter.desktop") == "com.wovenmatter.remote-workspaces")
        #expect(WovenMatterKeychainService.remoteWorkspaces(forBundleIdentifier: nil) == "com.wovenmatter.remote-workspaces")
        let dev = WovenMatterKeychainService.remoteWorkspaces(forBundleIdentifier: "wovenmatter.desktop.dev.mini.snapshot")
        #expect(dev == "Woven Matter.desktop.dev.mini.snapshot.remote-workspaces")
        #expect(dev != "com.wovenmatter.remote-workspaces")
    }
}
