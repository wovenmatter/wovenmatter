import Foundation
import Testing
@testable import WovenMatterAppFacade

struct WindowPreferenceUpgradeTests {
    @Test func savedSettingsMoveOnceAndNewerValuesWin() throws {
        let suite = "wovenmatter.tests.window-preferences." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: "wovenmatter.dashboard.theme")
        defaults.set(false, forKey: "wovenmatter.dashboard.left-rail")
        defaults.set("[\"a\"]", forKey: "wovenmatter.dashboard.pinned-agent-ids")
        defaults.set("single", forKey: "wovenmatter.dashboard.sidebar-style")
        defaults.set("split", forKey: SidebarStyle.storageKey)

        WindowPreferenceUpgrade.moveRenamedKeys(in: defaults)

        #expect(defaults.string(forKey: WovenTheme.storageKey) == "dark")
        #expect(defaults.object(forKey: "wovenmatter.layout.left-rail") as? Bool == false)
        #expect(defaults.string(forKey: PinnedAgentsStore.storageKey) == "[\"a\"]")
        #expect(defaults.string(forKey: SidebarStyle.storageKey) == "split")
        for legacy in WindowPreferenceUpgrade.renamedKeys.keys {
            #expect(defaults.object(forKey: legacy) == nil)
        }
        #expect(Set(WindowPreferenceUpgrade.renamedKeys.values).count == WindowPreferenceUpgrade.renamedKeys.count)
        #expect(WindowPreferenceUpgrade.renamedKeys.values.allSatisfy { !$0.contains("dashboard") })
    }
}
