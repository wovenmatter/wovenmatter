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

struct ChatPanelBotTargetTests {
    @Test func aPanelHoldsEitherABotOrAConversationNeverBoth() {
        var state = DashboardChatPanelState(primaryConversationID: "chat")
        let target = DashboardBotTarget(machineID: "machine", botID: "bot", conversationID: 7)
        state.replaceActiveBot(with: target)
        #expect(state.activeBotTarget == target)
        #expect(state.activeConversationID == nil)
        state.replaceActiveConversation(with: "other")
        #expect(state.activeBotTarget == nil)
        #expect(state.activeConversationID == "other")
    }

    @Test func botSelectionFollowsTheActivePanel() throws {
        var state = DashboardChatPanelState(primaryConversationID: "chat")
        state.replaceActiveBot(with: DashboardBotTarget(machineID: "machine", botID: "bot"))
        let added = DashboardChatPanelID(rawValue: "added")
        let wasAdded = state.addPanel(from: .primary, newPanelID: added, conversationID: "second")
        #expect(wasAdded)
        #expect(state.activeBotTarget == nil)
        #expect(state.activeConversationID == "second")
        state.activatePanel(.primary)
        #expect(state.activeBotTarget?.botID == "bot")
    }

    @Test func routingAnAuxiliaryPanelLeavesThePrimaryAlone() {
        var state = DashboardChatPanelState(primaryConversationID: "chat")
        let added = DashboardChatPanelID(rawValue: "added")
        state.addPanel(from: .primary, newPanelID: added, conversationID: nil)
        state.setBot(DashboardBotTarget(machineID: "machine", botID: "bot", conversationID: 3, showsThreadBesideMain: true), in: added)
        #expect(state.panel(id: added)?.botTarget?.conversationID == 3)
        #expect(state.primary.conversationID == "chat")
        #expect(state.primary.botTarget == nil)
    }

    @Test func showingTheSideAreaKeepsThePrimaryBot() {
        var state = DashboardChatPanelState()
        state.replaceActiveBot(with: DashboardBotTarget(machineID: "machine", botID: "bot"))
        state.presentAsset()
        #expect(state.assetPresented)
        #expect(state.primary.botTarget?.botID == "bot")
    }
}
