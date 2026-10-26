import Testing
@testable import WovenMatterCore

struct ChatPanelLayoutTests {
  private let a = DashboardChatPanelID(rawValue: "a")
  private let b = DashboardChatPanelID(rawValue: "b")
  private let c = DashboardChatPanelID(rawValue: "c")
  private let d = DashboardChatPanelID(rawValue: "d")

  @Test("closing every three and four panel shape compacts rows")
  func closeCompaction() {
    var onlyAuxiliary = DashboardChatPanelState(primaryConversationID: "p")
    let addedOnlyAuxiliary = onlyAuxiliary.addPanel(from: .primary, newPanelID: a)
    let closedOnlyAuxiliary = onlyAuxiliary.closePanel(a)
    #expect(addedOnlyAuxiliary)
    #expect(closedOnlyAuxiliary)
    #expect(onlyAuxiliary.auxiliaryRows.isEmpty)
    #expect(onlyAuxiliary.activePanelID == .primary)
    #expect(onlyAuxiliary.canAddPanel(from: .primary))

    for (closed, survivor) in [(b, a), (a, b)] {
      var state = threePanelState()
      let didClose = state.closePanel(closed)
      #expect(didClose)
      #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[survivor]])
      #expect(state.normalizedFrames()[survivor]?.height == 1)
    }
    for (split, firstClose, remainder, survivor, rows) in [
      (b, b, c, a, [[c], [a]]), (a, c, a, b, [[b], [a]]),
    ] {
      var state = threePanelState()
      let didSplit = state.addPanel(from: split, newPanelID: c)
      let didCloseFirst = state.closePanel(firstClose)
      #expect(didSplit && didCloseFirst)
      #expect(state.auxiliaryRows.map { $0.map(\.id) } == rows)
      #expect(state.canAddPanel(from: remainder))
      let didCloseRemainder = state.closePanel(remainder)
      #expect(didCloseRemainder)
      #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[survivor]])
    }
  }

  @Test("spatial navigation follows geometry and focuses only successful destinations")
  func spatialNavigationAndFocus() {
    let cases: [(DashboardChatPanelState, [(DashboardChatPanelDirection, DashboardChatPanelID?)])] = [
      (fivePanelState(), [(.left, nil), (.up, nil), (.down, nil), (.right, b),
        (.right, d), (.right, nil), (.down, c), (.left, a), (.left, .primary),
        (.right, b), (.down, a), (.up, b), (.up, nil)]),
      (threePanelState(), [(.right, b), (.up, nil)]),
    ]
    for (initial, steps) in cases {
      var state = initial
      let activated = state.activatePanel(.primary)
      #expect(activated)
      for (direction, destination) in steps {
        let previous = state.focusRequest
        #expect(state.navigate(direction) == destination)
        let expected = destination.map {
          DashboardChatPanelFocusRequest(panelID: $0, generation: (previous?.generation ?? 0) + 1)
        } ?? previous
        #expect(state.focusRequest == expected)
      }
    }
  }

  private func threePanelState() -> DashboardChatPanelState {
    var state = DashboardChatPanelState(primaryConversationID: "primary")
    _ = state.addPanel(from: .primary, newPanelID: a)
    _ = state.addPanel(from: a, newPanelID: b)
    return state
  }

  private func fivePanelState() -> DashboardChatPanelState {
    var state = threePanelState()
    _ = state.addPanel(from: a, newPanelID: c)
    _ = state.addPanel(from: b, newPanelID: d)
    return state
  }

}
