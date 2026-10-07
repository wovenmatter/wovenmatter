import Testing
@testable import WovenMatterCore

struct ChatPanelLayoutTests {
  private let a = DashboardChatPanelID(rawValue: "a")
  private let b = DashboardChatPanelID(rawValue: "b")
  private let c = DashboardChatPanelID(rawValue: "c")
  private let d = DashboardChatPanelID(rawValue: "d")

  @Test("one through five panels preserve placement and control visibility")
  func layoutProgressionAndControls() {
    var state = DashboardChatPanelState(primaryConversationID: "primary-chat")

    #expect(state.panelCount == 1)
    #expect(state.canAddPanel(from: .primary))
    #expect(!state.canClosePanel(.primary))
    #expect(state.normalizedFrames()[.primary]?.width == 1)

    let addedA = state.addPanel(
      from: .primary,
      newPanelID: a,
      conversationID: "chat-a"
    )
    #expect(addedA)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[a]])
    #expect(!state.canAddPanel(from: .primary))
    #expect(state.canAddPanel(from: a))
    #expect(state.canClosePanel(a))
    #expect(state.panel(id: a)?.conversationID == "chat-a")
    #expect(state.primary.conversationID == "primary-chat")

    let addedB = state.addPanel(from: a, newPanelID: b)
    #expect(addedB)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[b], [a]])
    #expect(state.canAddPanel(from: a))
    #expect(state.canAddPanel(from: b))
    #expect(state.primary.conversationID == "primary-chat")
    #expect(state.normalizedFrames()[a] == DashboardChatPanelFrame(
      x: 0.5,
      y: 0.5,
      width: 0.5,
      height: 0.5
    ))
    #expect(state.normalizedFrames()[b] == DashboardChatPanelFrame(
      x: 0.5,
      y: 0,
      width: 0.5,
      height: 0.5
    ))

    let addedC = state.addPanel(from: a, newPanelID: c)
    #expect(addedC)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[b], [a, c]])
    #expect(!state.canAddPanel(from: a))
    #expect(!state.canAddPanel(from: c))
    #expect(state.canAddPanel(from: b))
    #expect(state.primary.conversationID == "primary-chat")
    #expect(state.normalizedFrames()[a] == DashboardChatPanelFrame(
      x: 0.5,
      y: 0.5,
      width: 0.25,
      height: 0.5
    ))
    #expect(state.normalizedFrames()[c] == DashboardChatPanelFrame(
      x: 0.75,
      y: 0.5,
      width: 0.25,
      height: 0.5
    ))

    let addedD = state.addPanel(from: b, newPanelID: d)
    #expect(addedD)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[b, d], [a, c]])
    #expect(state.panelCount == DashboardChatPanelMetrics.maximumPanelCount)
    #expect(state.primary.conversationID == "primary-chat")
    #expect(state.panels.allSatisfy { !state.canAddPanel(from: $0.id) })
    #expect(state.auxiliaryRows.flatMap { $0 }.allSatisfy {
      state.canClosePanel($0.id)
    })
  }

  @Test("invalid additions and a sixth panel are gated")
  func maximumAndInvalidAddGating() {
    var state = fivePanelState()

    let addedSixth = state.addPanel(
      from: a,
      newPanelID: DashboardChatPanelID(rawValue: "e")
    )
    let addedPrimary = state.addPanel(from: .primary, newPanelID: .primary)
    let addedDuplicate = state.addPanel(from: .primary, newPanelID: a)
    #expect(!addedSixth)
    #expect(!addedPrimary)
    #expect(!addedDuplicate)
    #expect(state.panelCount == 5)
  }

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

  @Test("activation projects one sidebar selection and replacement is active-only")
  func activationAndReplacement() {
    var state = threePanelState()
    let assignedA = state.setConversation("chat-a", in: a)
    let assignedB = state.setConversation("chat-b", in: b)
    #expect(assignedA && assignedB)

    let activatedA = state.activatePanel(a)
    #expect(activatedA)
    #expect(state.activeConversationID == "chat-a")
    let replacedA = state.replaceActiveConversation(with: "replacement")
    #expect(replacedA)
    #expect(state.panel(id: a)?.conversationID == "replacement")
    #expect(state.panel(id: b)?.conversationID == "chat-b")
    #expect(state.primary.conversationID == "primary")

    let activatedB = state.activatePanel(b)
    #expect(activatedB)
    #expect(state.activeConversationID == "chat-b")
    let activatedMissing = state.activatePanel(DashboardChatPanelID(rawValue: "missing"))
    #expect(!activatedMissing)
  }

  @Test("explicit panel assignments allow empty panels and manual duplicates")
  func explicitAssignmentAndManualDuplicates() {
    var state = DashboardChatPanelState(primaryConversationID: "primary")
    let addedEmpty = state.addPanel(from: .primary, newPanelID: a)
    #expect(addedEmpty)
    #expect(state.panel(id: a)?.conversationID == nil)

    let duplicated = state.replaceActiveConversation(with: "primary")
    #expect(duplicated)
    #expect(state.primary.conversationID == "primary")
    #expect(state.panel(id: a)?.conversationID == "primary")
  }

  @Test("assets and auxiliary panels are mutually exclusive in both directions")
  func assetExclusivity() {
    var state = threePanelState()
    state.presentAsset()

    #expect(state.assetPresented)
    #expect(state.panelCount == 1)
    #expect(state.activePanelID == .primary)
    #expect(state.primary.conversationID == "primary")
    #expect(state.canAddPanel(from: .primary))
    let focusBeforeAssetNavigation = state.focusRequest
    let assetNavigation = state.navigate(.right)
    #expect(assetNavigation == nil)
    #expect(state.focusRequest == focusBeforeAssetNavigation)
    let addedAfterAsset = state.addPanel(from: .primary, newPanelID: a)
    #expect(addedAfterAsset)
    #expect(!state.assetPresented)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[a]])

    state.presentAsset()
    #expect(state.panelCount == 1)
    state.dismissAsset()
    #expect(!state.assetPresented)
    #expect(state.normalizedFrames()[.primary] == DashboardChatPanelFrame(
      x: 0,
      y: 0,
      width: 1,
      height: 1
    ))

    var onePanel = DashboardChatPanelState(primaryConversationID: "primary")
    let onePanelNavigation = onePanel.navigate(.right)
    #expect(onePanelNavigation == nil)
    #expect(onePanel.focusRequest == nil)
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
