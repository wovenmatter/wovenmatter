import CoreGraphics
import Testing
@testable import WovenMatterAppFacade

/// Narrow windows reuse the full-width rail layout: one revealed rail docks
/// beside the conversation instead of covering or pushing it aside.
struct DashboardLayoutStateTests {
    private let compactWidth = DashboardMetrics.desktopBreakpoint - 74

    @Test func minimumWindowFitsOneRailBesideTheWorkspace() {
        let used = DashboardMetrics.railWidth
            + DashboardMetrics.shellGap
            + DashboardMetrics.shellInset * 2
        #expect(DashboardMetrics.windowMinimumWidth - used >= DashboardMetrics.workspaceMinimumWidth)
    }

    @Test func compactWindowHidesRailsUntilOneIsRevealed() {
        for style in DashboardSidebarStyle.allCases {
            let hidden = DashboardLayoutState.resolve(
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
        let left = DashboardLayoutState.resolve(
            width: compactWidth, leftRailRequested: true, rightRailRequested: true,
            sidebarStyle: .split, compactRail: .left
        )
        #expect(left.showsLeftRail && !left.showsRightRail)

        let right = DashboardLayoutState.resolve(
            width: compactWidth, leftRailRequested: false, rightRailRequested: false,
            sidebarStyle: .split, compactRail: .right
        )
        #expect(!right.showsLeftRail && right.showsRightRail)
    }

    @Test func compactSingleRailFollowsItsConfiguredSide() {
        for style in [DashboardSidebarStyle.single, .adaptive] {
            let right = DashboardLayoutState.resolve(
                width: compactWidth, leftRailRequested: true, rightRailRequested: true,
                sidebarStyle: style, singleSidebarSide: .right, compactRail: .right
            )
            #expect(!right.showsLeftRail && right.showsRightRail)

            let wrongSide = DashboardLayoutState.resolve(
                width: compactWidth, leftRailRequested: true, rightRailRequested: true,
                sidebarStyle: style, singleSidebarSide: .right, compactRail: .left
            )
            #expect(!wrongSide.showsLeftRail && !wrongSide.showsRightRail)
        }
    }

    @Test func fullWidthIgnoresCompactRevealAndKeepsRequestedRails() {
        let layout = DashboardLayoutState.resolve(
            width: DashboardMetrics.desktopBreakpoint, leftRailRequested: true, rightRailRequested: false,
            sidebarStyle: .split, compactRail: .right
        )
        #expect(!layout.compact)
        #expect(layout.showsLeftRail && !layout.showsRightRail)
    }

    @Test func compactAdaptiveShowsOneRailPage() {
        var navigation = DashboardSidebarNavigationState()
        #expect(navigation.pages(for: .left, style: .adaptive, collapsesAdaptivePages: true) == [.navigation])
        navigation.selectFolder()
        #expect(navigation.pages(for: .left, style: .adaptive) == [.navigation, .workspace])
        #expect(navigation.pages(for: .left, style: .adaptive, collapsesAdaptivePages: true) == [.workspace])
        #expect(navigation.pages(for: .right, style: .adaptive, collapsesAdaptivePages: true) == [.workspace])
    }
}
