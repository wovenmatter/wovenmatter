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

    let addedA = state.addPanel(from: .primary, newPanelID: a)
    #expect(addedA)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[a]])
    #expect(!state.canAddPanel(from: .primary))
    #expect(state.canAddPanel(from: a))
    #expect(state.canClosePanel(a))
    #expect(state.panel(id: a)?.conversationID == "primary-chat")

    let addedB = state.addPanel(from: a, newPanelID: b)
    #expect(addedB)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[a], [b]])
    #expect(state.canAddPanel(from: a))
    #expect(state.canAddPanel(from: b))
    #expect(state.normalizedFrames()[a] == DashboardChatPanelFrame(
      x: 0.5,
      y: 0,
      width: 0.5,
      height: 0.5
    ))
    #expect(state.normalizedFrames()[b] == DashboardChatPanelFrame(
      x: 0.5,
      y: 0.5,
      width: 0.5,
      height: 0.5
    ))

    let addedC = state.addPanel(from: a, newPanelID: c)
    #expect(addedC)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[a, c], [b]])
    #expect(!state.canAddPanel(from: a))
    #expect(!state.canAddPanel(from: c))
    #expect(state.canAddPanel(from: b))
    #expect(state.normalizedFrames()[a] == DashboardChatPanelFrame(
      x: 0.5,
      y: 0,
      width: 0.25,
      height: 0.5
    ))
    #expect(state.normalizedFrames()[c] == DashboardChatPanelFrame(
      x: 0.75,
      y: 0,
      width: 0.25,
      height: 0.5
    ))

    let addedD = state.addPanel(from: b, newPanelID: d)
    #expect(addedD)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[a, c], [b, d]])
    #expect(state.panelCount == DashboardChatPanelMetrics.maximumPanelCount)
    #expect(state.panels.allSatisfy { !state.canAddPanel(from: $0.id) })
    #expect(state.auxiliaryRows.flatMap { $0 }.allSatisfy {
      state.canClosePanel($0.id)
    })
  }

  @Test("lower row can be the first divided four-panel variant")
  func lowerRowFourPanelVariant() {
    var state = threePanelState()

    let addedC = state.addPanel(from: b, newPanelID: c)
    #expect(addedC)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[a], [b, c]])
    #expect(state.canAddPanel(from: a))
    #expect(!state.canAddPanel(from: b))
    #expect(!state.canAddPanel(from: c))
    #expect(state.normalizedFrames()[a] == DashboardChatPanelFrame(
      x: 0.5,
      y: 0,
      width: 0.5,
      height: 0.5
    ))
    #expect(state.normalizedFrames()[b] == DashboardChatPanelFrame(
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

    let addedD = state.addPanel(from: a, newPanelID: d)
    #expect(addedD)
    #expect(state.auxiliaryRows.map { $0.map(\.id) } == [[a, d], [b, c]])
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

    var closeUpper = threePanelState()
    let closedUpper = closeUpper.closePanel(a)
    #expect(closedUpper)
    #expect(closeUpper.auxiliaryRows.map { $0.map(\.id) } == [[b]])
    #expect(closeUpper.normalizedFrames()[b]?.height == 1)

    var closeLower = threePanelState()
    let closedLower = closeLower.closePanel(b)
    #expect(closedLower)
    #expect(closeLower.auxiliaryRows.map { $0.map(\.id) } == [[a]])
    #expect(closeLower.normalizedFrames()[a]?.height == 1)

    var upperDivided = threePanelState()
    let dividedUpper = upperDivided.addPanel(from: a, newPanelID: c)
    let closedUpperLeading = upperDivided.closePanel(a)
    #expect(dividedUpper)
    #expect(closedUpperLeading)
    #expect(upperDivided.auxiliaryRows.map { $0.map(\.id) } == [[c], [b]])
    #expect(upperDivided.canAddPanel(from: c))
    let closedUpperRemainder = upperDivided.closePanel(c)
    #expect(closedUpperRemainder)
    #expect(upperDivided.auxiliaryRows.map { $0.map(\.id) } == [[b]])

    var lowerDivided = threePanelState()
    let dividedLower = lowerDivided.addPanel(from: b, newPanelID: c)
    let closedLowerTrailing = lowerDivided.closePanel(c)
    #expect(dividedLower)
    #expect(closedLowerTrailing)
    #expect(lowerDivided.auxiliaryRows.map { $0.map(\.id) } == [[a], [b]])
    let closedLowerRemainder = lowerDivided.closePanel(b)
    #expect(closedLowerRemainder)
    #expect(lowerDivided.auxiliaryRows.map { $0.map(\.id) } == [[a]])
  }

  @Test("every five-panel close order returns to the unchanged primary")
  func allCloseOrders() {
    let auxiliaryIDs = [a, b, c, d]
    for order in permutations(of: auxiliaryIDs) {
      var state = fivePanelState()
      let chatLifecycle = Set(["primary", "chat-a", "chat-b", "chat-c", "chat-d"])
      let assignedA = state.setConversation("chat-a", in: a)
      let assignedB = state.setConversation("chat-b", in: b)
      let assignedC = state.setConversation("chat-c", in: c)
      let assignedD = state.setConversation("chat-d", in: d)
      #expect(assignedA && assignedB && assignedC && assignedD)

      for panelID in order {
        let closed = state.closePanel(panelID)
        #expect(closed)
        // Panel removal has no lifecycle collaborator and cannot mutate chats.
        #expect(chatLifecycle == Set(["primary", "chat-a", "chat-b", "chat-c", "chat-d"]))
      }
      #expect(state.panels == [DashboardChatPanel(
        id: .primary,
        conversationID: "primary"
      )])
      #expect(state.activePanelID == .primary)
      #expect(state.canAddPanel(from: .primary))
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

  @Test("spatial navigation follows actual geometry without wrapping")
  func spatialNavigation() {
    var state = fivePanelState()

    let activatedPrimary = state.activatePanel(.primary)
    #expect(activatedPrimary)
    let leftFromPrimary = state.navigate(.left)
    let upFromPrimary = state.navigate(.up)
    let downFromPrimary = state.navigate(.down)
    let rightFromPrimary = state.navigate(.right)
    #expect(leftFromPrimary == nil)
    #expect(upFromPrimary == nil)
    #expect(downFromPrimary == nil)
    #expect(rightFromPrimary == a)

    let rightFromA = state.navigate(.right)
    let rightFromC = state.navigate(.right)
    let downFromC = state.navigate(.down)
    let leftFromD = state.navigate(.left)
    let leftFromB = state.navigate(.left)
    #expect(rightFromA == c)
    #expect(rightFromC == nil)
    #expect(downFromC == d)
    #expect(leftFromD == b)
    #expect(leftFromB == .primary)

    let activatedB = state.activatePanel(b)
    let upFromB = state.navigate(.up)
    let upFromA = state.navigate(.up)
    #expect(activatedB)
    #expect(upFromB == a)
    #expect(upFromA == nil)
  }

  @Test("successful navigation emits destination composer focus generations")
  func navigationFocusRequests() {
    var state = threePanelState()
    let generationAfterAdds = state.focusRequest?.generation

    let activatedPrimary = state.activatePanel(.primary)
    let navigatedRight = state.navigate(.right)
    #expect(activatedPrimary)
    #expect(navigatedRight == a)
    #expect(state.focusRequest == DashboardChatPanelFocusRequest(
      panelID: a,
      generation: (generationAfterAdds ?? 0) + 1
    ))
    let request = state.focusRequest
    let navigatedUp = state.navigate(.up)
    #expect(navigatedUp == nil)
    #expect(state.focusRequest == request)
  }

  @Test("panel divider contract matches Adaptive Sidebar")
  func dividerContract() {
    #expect(DashboardChatPanelMetrics.dividerThickness == 0.5)
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

  private func permutations<T>(of values: [T]) -> [[T]] {
    guard let first = values.first else { return [[]] }
    return permutations(of: Array(values.dropFirst())).flatMap { suffix in
      (0...suffix.count).map { index in
        var next = suffix
        next.insert(first, at: index)
        return next
      }
    }
  }
}
