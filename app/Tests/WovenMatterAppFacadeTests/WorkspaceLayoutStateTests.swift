import CoreGraphics
import Testing
@testable import WovenMatterAppFacade

/// Narrow windows reuse the full-width rail layout: one revealed rail docks
/// beside the conversation instead of covering or pushing it aside.
struct WorkspaceLayoutStateTests {
    private let compactWidth = WovenMetrics.desktopBreakpoint - 74

    @Test func minimumWindowFitsOneRailBesideTheWorkspace() {
        let used = WovenMetrics.railWidth
            + WovenMetrics.shellGap
            + WovenMetrics.shellInset * 2
        #expect(WovenMetrics.windowMinimumWidth - used >= WovenMetrics.workspaceMinimumWidth)
    }

    @Test func compactWindowHidesRailsUntilOneIsRevealed() {
        for style in SidebarStyle.allCases {
            let hidden = WorkspaceLayoutState.resolve(
                width: compactWidth,
                leftRailRequested: true,
                rightRailRequested: true,
                sidebarStyle: style
            )
            #expect(hidden.compact)
            #expect(!hidden.showsLeftRail && !hidden.showsRightRail)
        }
    }

    @Test func compactSplitDocksOnlyTheRevealedRail() {
        let left = WorkspaceLayoutState.resolve(
            width: compactWidth, leftRailRequested: true, rightRailRequested: true,
            sidebarStyle: .split, compactRail: .left
        )
        #expect(left.showsLeftRail && !left.showsRightRail)

        let right = WorkspaceLayoutState.resolve(
            width: compactWidth, leftRailRequested: false, rightRailRequested: false,
            sidebarStyle: .split, compactRail: .right
        )
        #expect(!right.showsLeftRail && right.showsRightRail)
    }

    @Test func compactSingleRailFollowsItsConfiguredSide() {
        for style in [SidebarStyle.single, .adaptive] {
            let right = WorkspaceLayoutState.resolve(
                width: compactWidth, leftRailRequested: true, rightRailRequested: true,
                sidebarStyle: style, singleSidebarSide: .right, compactRail: .right
            )
            #expect(!right.showsLeftRail && right.showsRightRail)

            let wrongSide = WorkspaceLayoutState.resolve(
                width: compactWidth, leftRailRequested: true, rightRailRequested: true,
                sidebarStyle: style, singleSidebarSide: .right, compactRail: .left
            )
            #expect(!wrongSide.showsLeftRail && !wrongSide.showsRightRail)
        }
    }

    @Test func fullWidthIgnoresCompactRevealAndKeepsRequestedRails() {
        let layout = WorkspaceLayoutState.resolve(
            width: WovenMetrics.desktopBreakpoint, leftRailRequested: true, rightRailRequested: false,
            sidebarStyle: .split, compactRail: .right
        )
        #expect(!layout.compact)
        #expect(layout.showsLeftRail && !layout.showsRightRail)
    }

    @Test func compactAdaptiveShowsOneRailPage() {
        var navigation = SidebarNavigationState()
        #expect(navigation.pages(for: .left, style: .adaptive, collapsesAdaptivePages: true) == [.navigation])
        navigation.selectFolder()
        #expect(navigation.pages(for: .left, style: .adaptive) == [.navigation, .workspace])
        #expect(navigation.pages(for: .left, style: .adaptive, collapsesAdaptivePages: true) == [.workspace])
        #expect(navigation.pages(for: .right, style: .adaptive, collapsesAdaptivePages: true) == [.workspace])
    }
}
