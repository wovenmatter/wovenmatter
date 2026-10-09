import SwiftUI
import WovenMatterClient
import WovenMatterCore

enum DashboardNewChatSource: String, CaseIterable, Identifiable {
    case acpDirect
    case remoteWorkspace
    case buzzWorkspace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .acpDirect: "Local workspace agents"
        case .remoteWorkspace: "Remote workspace agents"
        case .buzzWorkspace: "Buzz workspace agents"
        }
    }
}

/// Left-rail agent groupings for Woven Matter's product terminology.
/// Persistence still uses `AgentBucket` / governing-plane raw values.
enum DashboardAgentSidebarGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    case pinned
    case localWorkspace
    case remoteWorkspaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .localWorkspace: "Local agent workspace"
        case .remoteWorkspaces: "Remote agent workspaces"
        }
    }

    var orderKey: String { rawValue }

    static func contains(
        _ agent: WorkspaceAgent,
        in group: DashboardAgentSidebarGroup,
        pinnedIDs: Set<UUID>
    ) -> Bool {
        switch group {
        case .pinned:
            return pinnedIDs.contains(agent.id)
        case .localWorkspace:
            return agent.bucket == .localCLIAgents
                && !(agent.platformCodename?.hasPrefix("buzz-workspace:") ?? false)
                && !pinnedIDs.contains(agent.id)
        case .remoteWorkspaces:
            return agent.bucket == .remoteWorkspaceAgents
                && !pinnedIDs.contains(agent.id)
        }
    }

    static func agents(
        from agents: [WorkspaceAgent],
        in group: DashboardAgentSidebarGroup,
        pinnedIDs: Set<UUID>,
        pinOrder: [UUID] = [],
        customOrder: [UUID] = []
    ) -> [WorkspaceAgent] {
        switch group {
        case .pinned:
            return applyOrder(
                agents.filter { contains($0, in: .pinned, pinnedIDs: pinnedIDs) },
                preferred: pinOrder.isEmpty ? customOrder : pinOrder
            )
        case .localWorkspace:
            let defaultOrder = agents
                .filter { contains($0, in: group, pinnedIDs: pinnedIDs) }
                .sorted { lhs, rhs in
                    if lhs.runtimeKind != rhs.runtimeKind {
                        return lhs.runtimeKind.presentationRank
                            < rhs.runtimeKind.presentationRank
                    }
                    let comparison = lhs.displayName.localizedCaseInsensitiveCompare(
                        rhs.displayName
                    )
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            return applyPreferredOrder(defaultOrder, preferred: customOrder)
        case .remoteWorkspaces:
            let defaultOrder = agents
                .filter { contains($0, in: group, pinnedIDs: pinnedIDs) }
                .sorted { lhs, rhs in
                    if lhs.runtimeKind != rhs.runtimeKind {
                        return lhs.runtimeKind.presentationRank
                            < rhs.runtimeKind.presentationRank
                    }
                    if lhs.displayName != rhs.displayName {
                        return lhs.displayName.localizedCaseInsensitiveCompare(
                            rhs.displayName
                        ) == .orderedAscending
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            return applyPreferredOrder(defaultOrder, preferred: customOrder)
        }
    }

    /// Stable display order: preferred IDs first (when present), then name-sorted remainder.
    static func applyOrder(
        _ agents: [WorkspaceAgent],
        preferred: [UUID]
    ) -> [WorkspaceAgent] {
        guard !agents.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        var seen = Set<UUID>()
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
        preferred: [UUID]
    ) -> [WorkspaceAgent] {
        guard !agents.isEmpty, !preferred.isEmpty else { return agents }
        let byID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        var seen = Set<UUID>()
        let preferredAgents = preferred.compactMap { id -> WorkspaceAgent? in
            guard let agent = byID[id], seen.insert(id).inserted else { return nil }
            return agent
        }
        return preferredAgents + agents.filter { seen.insert($0.id).inserted }
    }
}

enum DashboardAgentSidebarHeading {
    static let buzzWorkspaces = "Buzz agent workspaces"
}

struct DashboardRemoteWorkspaceSidebarLink: Equatable, Identifiable {
    let configuration: RemoteWorkspaceConfiguration
    let readyTargets: [RemoteHarnessChatTarget]

    var id: UUID { configuration.id }
}

enum DashboardRemoteWorkspaceSidebarModel {
    static func links(
        workspaces: [RemoteWorkspaceConfiguration],
        readyTargets: [RemoteHarnessChatTarget]
    ) -> [DashboardRemoteWorkspaceSidebarLink] {
        let targetsByWorkspaceID = Dictionary(
            grouping: readyTargets,
            by: { $0.configuration.id }
        )
        return workspaces
            .sorted { lhs, rhs in
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { configuration in
                DashboardRemoteWorkspaceSidebarLink(
                    configuration: configuration,
                    readyTargets: (targetsByWorkspaceID[configuration.id] ?? [])
                        .sorted { lhs, rhs in
                            lhs.harness.id.presentationRank
                                < rhs.harness.id.presentationRank
                        }
                )
            }
    }
}

struct DashboardBuzzWorkspaceSidebarLink: Equatable, Identifiable {
    let link: BuzzWorkspaceLink
    let agents: [WorkspaceAgent]
    let enrollmentCount: Int

    var id: UUID { link.id }
}

enum DashboardBuzzWorkspaceSidebarModel {
    static func links(
        snapshot: BuzzWorkspaceSnapshot,
        agents: [WorkspaceAgent],
        pinnedIDs: Set<UUID>,
        customOrderByWorkspaceID: [UUID: [UUID]] = [:]
    ) -> [DashboardBuzzWorkspaceSidebarLink] {
        let buzzAgentsByID: [UUID: WorkspaceAgent] = Dictionary(
            uniqueKeysWithValues: agents.compactMap { agent -> (UUID, WorkspaceAgent)? in
                guard agent.platformCodename?.hasPrefix("buzz-workspace:") == true else {
                    return nil
                }
                return (agent.id, agent)
            }
        )
        let enrollmentsByLink = Dictionary(
            grouping: snapshot.enrollments,
            by: \.workspaceLinkID
        )
        return snapshot.links.sorted(by: linkSort).map { link in
            let enrollments = enrollmentsByLink[link.id] ?? []
            let linkAgents = enrollments.compactMap { enrollment in
                buzzAgentsByID[enrollment.id]
            }
            .filter { !pinnedIDs.contains($0.id) }
            .sorted(by: agentSort)
            let orderedAgents = DashboardAgentSidebarGroup.applyPreferredOrder(
                linkAgents,
                preferred: customOrderByWorkspaceID[link.id] ?? []
            )
            return DashboardBuzzWorkspaceSidebarLink(
                link: link,
                agents: orderedAgents,
                enrollmentCount: enrollments.count
            )
        }
    }

    private static func linkSort(
        _ lhs: BuzzWorkspaceLink,
        _ rhs: BuzzWorkspaceLink
    ) -> Bool {
        let result = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if result == .orderedSame {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return result == .orderedAscending
    }

    private static func agentSort(_ lhs: WorkspaceAgent, _ rhs: WorkspaceAgent) -> Bool {
        if lhs.runtimeKind != rhs.runtimeKind {
            return lhs.runtimeKind.presentationRank < rhs.runtimeKind.presentationRank
        }
        let result = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if result == .orderedSame {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return result == .orderedAscending
    }
}

/// Presentation-only preferences, independent of runtime visibility and section expansion.
enum DashboardWorkspaceSidebarVisibility: String {
    case localWorkspace
    case remoteWorkspaces
    case buzzWorkspaces

    var storageKey: String {
        "wovenmatter.dashboard.show-\(rawValue)"
    }

    var title: String {
        switch self {
        case .localWorkspace: DashboardAgentSidebarGroup.localWorkspace.title
        case .remoteWorkspaces: DashboardAgentSidebarGroup.remoteWorkspaces.title
        case .buzzWorkspaces: DashboardAgentSidebarHeading.buzzWorkspaces
        }
    }
}

enum DashboardAgentDisclosureKey {
    static let localWorkspace = "section:local-workspace"
    static let remoteWorkspaces = "section:remote-workspaces"
    static let buzzWorkspaces = "section:buzz-workspaces"

    static func workspace(_ id: UUID) -> String {
        "workspace:\(id.uuidString.lowercased())"
    }
}

enum DashboardAgentDisclosureStore {
    static let storageKey = "wovenmatter.dashboard.collapsed-agent-sections"

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

enum DashboardAgentListMoveDirection: Sendable {
    case up
    case down
}

/// Device-local order of agents within each sidebar group (`AppStorage` JSON map).
enum DashboardAgentOrderStore {
    static let storageKey = "wovenmatter.dashboard.agent-order-by-group"

    static func decode(_ raw: String) -> [String: [UUID]] {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        var result: [String: [UUID]] = [:]
        for (key, ids) in values {
            var seen = Set<UUID>()
            result[key] = ids.compactMap { UUID(uuidString: $0) }.filter { seen.insert($0).inserted }
        }
        return result
    }

    static func encode(_ map: [String: [UUID]]) -> String {
        let values = map.mapValues { $0.map { $0.uuidString.lowercased() } }
        guard let data = try? JSONEncoder().encode(values),
              let raw = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return raw
    }

    static func order(for group: DashboardAgentSidebarGroup, in raw: String) -> [UUID] {
        order(forKey: group.orderKey, in: raw)
    }

    static func order(forKey key: String, in raw: String) -> [UUID] {
        decode(raw)[key] ?? []
    }

    static func buzzWorkspaceKey(_ id: UUID) -> String {
        "buzzWorkspace:\(id.uuidString.lowercased())"
    }

    /// Preferred IDs first when present, then remaining present IDs in their given order.
    static func mergePreferred(_ preferred: [UUID], present: [UUID]) -> [UUID] {
        let presentSet = Set(present)
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in preferred where presentSet.contains(id) && seen.insert(id).inserted {
            result.append(id)
        }
        for id in present where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    /// `presentIDs` must be the current on-screen order for the group.
    static func move(
        id: UUID,
        direction: DashboardAgentListMoveDirection,
        in group: DashboardAgentSidebarGroup,
        presentIDs: [UUID],
        raw: inout String
    ) {
        move(
            id: id,
            direction: direction,
            inKey: group.orderKey,
            presentIDs: presentIDs,
            raw: &raw
        )
    }

    static func move(
        id: UUID,
        direction: DashboardAgentListMoveDirection,
        inKey key: String,
        presentIDs: [UUID],
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

    /// Reorders a dragged item at the target using the current on-screen order.
    @discardableResult
    static func move(
        sourceID: UUID,
        targetID: UUID,
        in group: DashboardAgentSidebarGroup,
        presentIDs: [UUID],
        raw: inout String
    ) -> Bool {
        guard sourceID != targetID,
              let sourceIndex = presentIDs.firstIndex(of: sourceID),
              let targetIndex = presentIDs.firstIndex(of: targetID) else { return false }
        var map = decode(raw)
        var ids = presentIDs
        ids.remove(at: sourceIndex)
        ids.insert(sourceID, at: min(targetIndex, ids.count))
        map[group.orderKey] = ids
        raw = encode(map)
        return true
    }

    static func canMove(
        id: UUID,
        direction: DashboardAgentListMoveDirection,
        presentIDs: [UUID]
    ) -> Bool {
        guard let index = presentIDs.firstIndex(of: id) else { return false }
        switch direction {
        case .up: return index > 0
        case .down: return index < presentIDs.count - 1
        }
    }
}

struct DashboardAgentPresentation: Equatable {
    let displayName: String
    let iconKey: String
}

extension DashboardHarnessLogo {
    static var displayCases: [DashboardHarnessLogo] {
        AgentRuntimeKind.presentationOrder.map(Self.init(runtimeKind:))
    }

    init(runtimeKind: AgentRuntimeKind) {
        switch runtimeKind {
        case .codex: self = .codex
        case .claudeCode: self = .claude
        case .grokBuild: self = .grok
        case .openclaw: self = .openClaw
        case .hermes: self = .hermes
        case .defaultAgent: self = .defaultAgent
        case .pi: self = .pi
        case .cursor: self = .cursor
        case .opencode: self = .openCode
        }
    }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .grok: "Grok Build"
        case .openClaw: "OpenClaw"
        case .hermes: "Hermes"
        case .defaultAgent: AgentRuntimeKind.defaultAgent.displayName
        case .pi: "Pi"
        case .cursor: "Cursor"
        case .openCode: "OpenCode"
        }
    }

    static func resolve(harnessIdentifier: String, runtimeKind: AgentRuntimeKind?) -> Self? {
        if let runtimeKind { return Self(runtimeKind: runtimeKind) }
        return resolve(harnessIdentifier: harnessIdentifier)
    }
}

enum DashboardSidebarStyle: String, CaseIterable, Identifiable {
    case adaptive
    case single
    case split

    static let storageKey = "wovenmatter.dashboard.sidebar-style"
    static let defaultStyle = DashboardSidebarStyle.split

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

enum DashboardSidebarSide: String, CaseIterable, Identifiable {
    case left
    case right

    static let storageKey = "wovenmatter.dashboard.single-sidebar-side"
    static let defaultSide = DashboardSidebarSide.left

    var id: String { rawValue }

    var opposite: DashboardSidebarSide {
        switch self {
        case .left: .right
        case .right: .left
        }
    }
}

enum DashboardSidebarPage: Hashable, Sendable {
    case navigation
    case workspace
}

struct DashboardSidebarNavigationState: Equatable, Sendable {
    private(set) var singlePage = DashboardSidebarPage.navigation
    private(set) var adaptiveWorkspaceVisible = false

    mutating func selectFolder() {
        singlePage = .workspace
        adaptiveWorkspaceVisible = true
    }

    mutating func showNavigation() {
        singlePage = .navigation
        adaptiveWorkspaceVisible = false
    }

    func pages(
        for side: DashboardSidebarSide,
        style: DashboardSidebarStyle
    ) -> [DashboardSidebarPage] {
        switch style {
        case .adaptive:
            guard adaptiveWorkspaceVisible else { return [.navigation] }
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

enum DashboardShapes {
    /// Keeps full-height inset surfaces optically aligned with the macOS window.
    /// The system supplies the window's container shape; the fixed value is only
    /// a minimum for corners that are too far from a window edge to resolve.
    static var windowAlignedSurface: ConcentricRectangle {
        ConcentricRectangle(
            corners: .concentric(
                minimum: .fixed(DashboardMetrics.windowAlignedSurfaceMinimumRadius)
            ),
            isUniform: true
        )
    }

    static var card: RoundedRectangle {
        RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous)
    }
}

struct DashboardLayoutState: Equatable {
    let compact: Bool
    let showsLeftRail: Bool
    let showsRightRail: Bool

    static func resolve(
        width: CGFloat,
        leftRailRequested: Bool,
        rightRailRequested: Bool,
        sidebarStyle: DashboardSidebarStyle = .defaultStyle,
        singleSidebarSide: DashboardSidebarSide = .defaultSide,
        singleRailRequested: Bool = true
    ) -> DashboardLayoutState {
        let compact = width < DashboardMetrics.desktopBreakpoint
        let showsLeftRail: Bool
        let showsRightRail: Bool
        switch sidebarStyle {
        case .adaptive, .single:
            showsLeftRail = !compact && singleRailRequested && singleSidebarSide == .left
            showsRightRail = !compact && singleRailRequested && singleSidebarSide == .right
        case .split:
            showsLeftRail = !compact && leftRailRequested
            showsRightRail = !compact && rightRailRequested
        }
        return DashboardLayoutState(
            compact: compact,
            showsLeftRail: showsLeftRail,
            showsRightRail: showsRightRail
        )
    }
}

struct DashboardRailBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dashboardTheme) private var theme
    @State private var hovered = false

    var body: some View {
        let palette = theme.palette
        DashboardShapes.windowAlignedSurface
            .fill(reduceTransparency ? palette.railReducedFill : palette.workspace)
            .overlay {
                if !reduceTransparency {
                    DashboardShapes.windowAlignedSurface
                        .fill(palette.railFill)
                }
            }
            .overlay {
                DashboardShapes.windowAlignedSurface
                    .stroke(hovered ? palette.railHoverRim : palette.railRim, lineWidth: 1)
            }
            .overlay {
                DashboardShapes.windowAlignedSurface
                    .stroke(hovered ? palette.railHoverInner : palette.railInnerLight, lineWidth: 1)
                    .padding(1)
            }
            .overlay {
                DashboardShapes.windowAlignedSurface
                    .stroke(palette.railEdge, lineWidth: 0.5)
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: hovered)
    }
}

struct DashboardSectionHeading: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.8)
            .foregroundStyle(DashboardPalette.mutedForeground)
    }
}

struct DashboardActiveConversationRowBackground: View {
    @Environment(\.dashboardTheme) private var theme
    let presentation: ConversationActivityPresentation
    let selected: Bool
    let hovered: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(presentation.isActive ? theme.palette.themeWhisper : .clear)
            if presentation.allowsMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    // Animate drawing, rather than a child's frame and offset.
                    // Active rows appear in both rails; relaying their sweep
                    // through layout repeatedly invalidates the whole window.
                    Canvas(rendersAsynchronously: true) { canvas, size in
                        let progress = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 4.2) / 4.2
                        let start = size.width * (-1.7 + 2.7 * progress)
                        canvas.fill(
                            Path(CGRect(x: start, y: 0, width: size.width * 1.7, height: size.height)),
                            with: .linearGradient(
                                Gradient(colors: [.clear, DashboardPalette.primary.opacity(0.055), .clear]),
                                startPoint: CGPoint(x: start, y: 0),
                                endPoint: CGPoint(x: start + size.width * 1.7, y: 0)
                            )
                        )
                    }
                    .clipShape(shape)
                }
            }
            shape.fill(
                selected
                    ? theme.palette.themeStrong
                    : hovered ? theme.palette.themeSoft : .clear
            )
        }
    }
}

struct DashboardCard<Content: View>: View {
    @Environment(\.dashboardTheme) private var theme
    let showsBorder: Bool
    let showsBackground: Bool
    let content: Content

    init(
        showsBorder: Bool = true,
        showsBackground: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.showsBorder = showsBorder
        self.showsBackground = showsBackground
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(showsBackground ? DashboardPalette.background.opacity(0.72) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous)
                        .stroke(theme.palette.border, lineWidth: 1)
                }
            }
    }
}

/// Compact native switches share the app's forest-green action color.
/// Keeping the native control preserves keyboard and accessibility behavior.
struct DashboardSwitchToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: DashboardPalette.primary))
                .controlSize(.mini)
                .fixedSize()
                .scaleEffect(0.8)
                .frame(width: 28, height: 16)
            if showsLabel {
                configuration.label
                    .contentShape(Rectangle())
                    .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            }
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}
