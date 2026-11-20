import SwiftUI

enum NewChatSource: String, CaseIterable, Identifiable {
    case acpDirect
    case remoteWorkspace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .acpDirect: "Local workspace agents"
        case .remoteWorkspace: "Remote workspace agents"
        }
    }
}

/// Left-rail agent groupings for Woven Matter's product terminology. The
/// agents passed in are already those of one machine's section.
enum AgentSidebarGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    case pinned
    case localWorkspace
    case remoteWorkspaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .localWorkspace: "Local workspace"
        case .remoteWorkspaces: "Remote workspaces"
        }
    }

    var orderKey: String { rawValue }

    static func agents(
        from agents: [WorkspaceAgent],
        in group: AgentSidebarGroup,
        pinnedIDs: Set<String>,
        customOrder: [String] = []
    ) -> [WorkspaceAgent] {
        switch group {
        case .pinned:
            return applyOrder(agents.filter { pinnedIDs.contains($0.id) }, preferred: customOrder)
        case .localWorkspace, .remoteWorkspaces:
            let defaultOrder = agents
                .filter { !pinnedIDs.contains($0.id) }
                .sorted { lhs, rhs in
                    if lhs.runtimeKind != rhs.runtimeKind {
                        return lhs.runtimeKind.presentationRank < rhs.runtimeKind.presentationRank
                    }
                    let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                    return lhs.id < rhs.id
                }
            return applyPreferredOrder(defaultOrder, preferred: customOrder)
        }
    }

    /// Stable display order: preferred IDs first (when present), then name-sorted remainder.
    static func applyOrder(
        _ agents: [WorkspaceAgent],
        preferred: [String]
    ) -> [WorkspaceAgent] {
        guard !agents.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        var seen = Set<String>()
        var ordered: [WorkspaceAgent] = []
        for id in preferred {
            guard let agent = byID[id], seen.insert(id).inserted else { continue }
            ordered.append(agent)
        }
        let remaining = agents
            .filter { seen.insert($0.id).inserted }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
        return ordered + remaining
    }

    /// Applies preferred IDs while retaining the caller's fallback ordering.
    static func applyPreferredOrder(
        _ agents: [WorkspaceAgent],
        preferred: [String]
    ) -> [WorkspaceAgent] {
        guard !agents.isEmpty, !preferred.isEmpty else { return agents }
        let byID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        var seen = Set<String>()
        let preferredAgents = preferred.compactMap { id -> WorkspaceAgent? in
            guard let agent = byID[id], seen.insert(id).inserted else { return nil }
            return agent
        }
        return preferredAgents + agents.filter { seen.insert($0.id).inserted }
    }
}

/// Presentation-only preferences, independent of runtime visibility and section expansion.
enum WorkspaceSidebarVisibility: String {
    case localWorkspace
    case remoteWorkspaces

    var storageKey: String {
        "wovenmatter.sidebar.show-\(rawValue)"
    }

    var title: String {
        switch self {
        case .localWorkspace: AgentSidebarGroup.localWorkspace.title
        case .remoteWorkspaces: AgentSidebarGroup.remoteWorkspaces.title
        }
    }
}

enum AgentDisclosureKey {
    static let localWorkspace = "section:local-workspace"
    static let remoteWorkspaces = "section:remote-workspaces"

    static func machine(_ id: String) -> String {
        "workspace:\(id)"
    }
}

enum AgentDisclosureStore {
    static let storageKey = "wovenmatter.sidebar.collapsed-agent-sections"

    static func decode(_ raw: String) -> Set<String> {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    static func encode(_ collapsed: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(collapsed.sorted()),
              let raw = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return raw
    }

    static func isExpanded(_ key: String, in raw: String) -> Bool {
        !decode(raw).contains(key)
    }

    static func toggle(_ key: String, in raw: inout String) {
        var collapsed = decode(raw)
        if !collapsed.insert(key).inserted {
            collapsed.remove(key)
        }
        raw = encode(collapsed)
    }
}

enum AgentListMoveDirection: Sendable {
    case up
    case down
}

/// Device-local order of agents within each sidebar group (`AppStorage` JSON map).
enum AgentOrderStore {
    static let storageKey = "wovenmatter.sidebar.agent-order-by-group"

    static func decode(_ raw: String) -> [String: [String]] {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return values.mapValues { ids in
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }
    }

    static func encode(_ map: [String: [String]]) -> String {
        guard let data = try? JSONEncoder().encode(map),
              let raw = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return raw
    }

    static func order(forKey key: String, in raw: String) -> [String] {
        decode(raw)[key] ?? []
    }

    /// Preferred IDs first when present, then remaining present IDs in their given order.
    static func mergePreferred(_ preferred: [String], present: [String]) -> [String] {
        let presentSet = Set(present)
        var seen = Set<String>()
        var result: [String] = []
        for id in preferred where presentSet.contains(id) && seen.insert(id).inserted {
            result.append(id)
        }
        for id in present where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    static func move(
        id: String,
        direction: AgentListMoveDirection,
        inKey key: String,
        presentIDs: [String],
        raw: inout String
    ) {
        var map = decode(raw)
        var ids = presentIDs
        guard let index = ids.firstIndex(of: id) else { return }
        let target: Int
        switch direction {
        case .up:
            guard index > 0 else { return }
            target = index - 1
        case .down:
            guard index < ids.count - 1 else { return }
            target = index + 1
        }
        ids.swapAt(index, target)
        map[key] = ids
        raw = encode(map)
    }

    static func canMove(
        id: String,
        direction: AgentListMoveDirection,
        presentIDs: [String]
    ) -> Bool {
        guard let index = presentIDs.firstIndex(of: id) else { return false }
        switch direction {
        case .up: return index > 0
        case .down: return index < presentIDs.count - 1
        }
    }
}

struct AgentPresentation: Equatable {
    let displayName: String
    let iconKey: String
}

extension HarnessLogo {
    init(runtimeKind: AgentRuntimeKind) {
        switch runtimeKind {
        case .codex: self = .codex
        case .claudeCode: self = .claude
        case .grokBuild: self = .grok
        case .defaultAgent: self = .defaultAgent
        case .opencode: self = .openCode
        }
    }
}

enum SidebarStyle: String, CaseIterable, Identifiable {
    case adaptive
    case single
    case split

    static let storageKey = "wovenmatter.layout.sidebar-style"
    static let defaultStyle = SidebarStyle.split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adaptive: "Adaptive Sidebar"
        case .single: "Single Sidebar"
        case .split: "Split Sidebar"
        }
    }

    var detail: String {
        switch self {
        case .adaptive: "Keep navigation visible and open folder contents beside it."
        case .single: "Open folder contents in place of the movable navigation sidebar."
        case .split: "Keep navigation and workspace sidebars visible on opposite sides."
        }
    }
}

enum SidebarSide: String, CaseIterable, Identifiable {
    case left
    case right

    static let storageKey = "wovenmatter.layout.single-sidebar-side"
    static let defaultSide = SidebarSide.left

    var id: String { rawValue }

    var opposite: SidebarSide {
        switch self {
        case .left: .right
        case .right: .left
        }
    }
}

enum SidebarPage: Hashable, Sendable {
    case navigation
    case workspace
}

struct SidebarNavigationState: Equatable, Sendable {
    private(set) var singlePage = SidebarPage.navigation
    private(set) var adaptiveWorkspaceVisible = false

    mutating func selectFolder() {
        singlePage = .workspace
        adaptiveWorkspaceVisible = true
    }

    mutating func showNavigation() {
        singlePage = .navigation
        adaptiveWorkspaceVisible = false
    }

    /// A compact window has room for one rail page, so Adaptive then shows the
    /// folder's contents alone, with a back button, as Single does.
    func pages(
        for side: SidebarSide,
        style: SidebarStyle,
        collapsesAdaptivePages: Bool = false
    ) -> [SidebarPage] {
        switch style {
        case .adaptive:
            guard adaptiveWorkspaceVisible else { return [.navigation] }
            if collapsesAdaptivePages { return [.workspace] }
            return side == .left
                ? [.navigation, .workspace]
                : [.workspace, .navigation]
        case .single:
            return [singlePage]
        case .split:
            return [side == .left ? .navigation : .workspace]
        }
    }
}

enum DesktopShapes {
    /// Keeps full-height inset surfaces optically aligned with the macOS window.
    /// The system supplies the window's container shape; the fixed value is only
    /// a minimum for corners that are too far from a window edge to resolve.
    static var windowAlignedSurface: ConcentricRectangle {
        ConcentricRectangle(
            corners: .concentric(
                minimum: .fixed(WovenMetrics.windowAlignedSurfaceMinimumRadius)
            ),
            isUniform: true
        )
    }

    static var card: RoundedRectangle {
        RoundedRectangle(cornerRadius: WovenMetrics.cardRadius, style: .continuous)
    }
}

struct WorkspaceLayoutState: Equatable {
    let compact: Bool
    let showsLeftRail: Bool
    let showsRightRail: Bool

    static func resolve(
        width: CGFloat,
        leftRailRequested: Bool,
        rightRailRequested: Bool,
        sidebarStyle: SidebarStyle = .defaultStyle,
        singleSidebarSide: SidebarSide = .defaultSide,
        singleRailRequested: Bool = true,
        compactRail: SidebarSide? = nil
    ) -> WorkspaceLayoutState {
        // Below the breakpoint the rails hide on their own. Revealing one docks
        // it beside the conversation exactly as at full width; the minimum
        // window always leaves one rail and the minimum workspace room.
        let compact = width < WovenMetrics.desktopBreakpoint
        let showsLeftRail: Bool
        let showsRightRail: Bool
        switch sidebarStyle {
        case .adaptive, .single:
            showsLeftRail = compact
                ? compactRail == .left && singleSidebarSide == .left
                : singleRailRequested && singleSidebarSide == .left
            showsRightRail = compact
                ? compactRail == .right && singleSidebarSide == .right
                : singleRailRequested && singleSidebarSide == .right
        case .split:
            showsLeftRail = compact ? compactRail == .left : leftRailRequested
            showsRightRail = compact ? compactRail == .right : rightRailRequested
        }
        return WorkspaceLayoutState(
            compact: compact,
            showsLeftRail: showsLeftRail,
            showsRightRail: showsRightRail
        )
    }
}

struct RailBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wovenTheme) private var theme
    @State private var hovered = false

    var body: some View {
        let palette = theme.palette
        DesktopShapes.windowAlignedSurface
            .fill(reduceTransparency ? palette.railReducedFill : palette.workspace)
            .overlay {
                if !reduceTransparency {
                    DesktopShapes.windowAlignedSurface
                        .fill(palette.railFill)
                }
            }
            .overlay {
                DesktopShapes.windowAlignedSurface
                    .stroke(hovered ? palette.railHoverRim : palette.railRim, lineWidth: 1)
            }
            .overlay {
                DesktopShapes.windowAlignedSurface
                    .stroke(hovered ? palette.railHoverInner : palette.railInnerLight, lineWidth: 1)
                    .padding(1)
            }
            .overlay {
                DesktopShapes.windowAlignedSurface
                    .stroke(palette.railEdge, lineWidth: 0.5)
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: hovered)
    }
}

struct ActiveConversationRowBackground: View {
    @Environment(\.wovenTheme) private var theme
    let presentation: ConversationActivityPresentation
    let selected: Bool
    let hovered: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(presentation.isActive ? theme.palette.themeWhisper : .clear)
            if presentation.allowsMotion {
                ActiveRowSweep(cornerRadius: cornerRadius)
            }
            shape.fill(
                selected
                    ? theme.palette.themeStrong
                    : hovered ? theme.palette.themeSoft : .clear
            )
        }
    }
}

/// The faint band that sweeps across a running chat's row every 4.2 s. Core
/// Animation moves it, so the rails are not evaluated or laid out again while
/// it runs. It stops while the window is not visible. Every row shares one
/// phase, so a chat's rows in both rails sweep together.
private struct ActiveRowSweep: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> ActiveRowSweepView { ActiveRowSweepView() }

    func updateNSView(_ view: ActiveRowSweepView, context: Context) {
        view.cornerRadius = cornerRadius
    }
}

private final class ActiveRowSweepView: NSView {
    private static let period: CFTimeInterval = 4.2
    /// The band is this many row widths wide.
    private static let bandWidth: CGFloat = 1.7
    private static let animationKey = "sweep"

    private let band = CAGradientLayer()

    var cornerRadius: CGFloat = 0 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    init() {
        super.init(frame: .zero)
        let root = CALayer()
        root.masksToBounds = true
        root.cornerCurve = .continuous
        layer = root
        wantsLayer = true
        clipsToBounds = true
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        root.addSublayer(band)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let size = bounds.size
        let width = size.width * Self.bandWidth
        guard band.bounds.size != CGSize(width: width, height: size.height) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.anchorPoint = .zero
        band.bounds = CGRect(x: 0, y: 0, width: width, height: size.height)
        band.position = .zero
        CATransaction.commit()
        band.removeAnimation(forKey: Self.animationKey)
        updateAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updateColor()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    @objc private func occlusionChanged() { updateAnimation() }

    private func updateColor() {
        var colors: [CGColor] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let primary = WovenColors.primary
            colors = [primary.withAlphaComponent(0), primary.withAlphaComponent(0.055), primary.withAlphaComponent(0)]
                .map(\.cgColor)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.colors = colors
        CATransaction.commit()
    }

    /// The band's left edge travels from 1.7 row widths before the row to its
    /// right edge, in step with the wall clock.
    private func updateAnimation() {
        let width = bounds.width
        guard width > 0, window?.occlusionState.contains(.visible) == true else {
            band.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard band.animation(forKey: Self.animationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.fromValue = -width * Self.bandWidth
        animation.toValue = width
        animation.duration = Self.period
        animation.timeOffset = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        band.add(animation, forKey: Self.animationKey)
    }
}

struct RoundedCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
    }
}

/// Compact native switches share the app's forest-green action color.
/// Keeping the native control preserves keyboard and accessibility behavior.
struct CompactSwitchToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: WovenPalette.primary))
                .controlSize(.mini)
                .fixedSize()
                .scaleEffect(0.8)
                .frame(width: 28, height: 16)
            configuration.label
                .contentShape(Rectangle())
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
