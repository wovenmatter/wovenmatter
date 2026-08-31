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
        case .localWorkspace: "Local Agent Workspace"
        case .remoteWorkspaces: "Remote Agent Workspaces"
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
                    let lhsHarness = DashboardHarnessLogo(runtimeKind: lhs.runtimeKind)
                    let rhsHarness = DashboardHarnessLogo(runtimeKind: rhs.runtimeKind)
                    if lhsHarness != rhsHarness {
                        return lhsHarness.sortsBefore(rhsHarness)
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
                .sorted {
                    if $0.displayName != $1.displayName {
                        return $0.displayName.localizedCaseInsensitiveCompare(
                            $1.displayName
                        ) == .orderedAscending
                    }
                    return $0.id.uuidString < $1.id.uuidString
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
    static let buzzWorkspaces = "Buzz Agent Workspaces"
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
                            let comparison = lhs.harness.displayName
                                .localizedCaseInsensitiveCompare(rhs.harness.displayName)
                            if comparison != .orderedSame {
                                return comparison == .orderedAscending
                            }
                            return lhs.harness.id.rawValue < rhs.harness.id.rawValue
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
        let result = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if result == .orderedSame {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return result == .orderedAscending
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

/// Lucide 0.563.0 template vectors. The suffix records the stroke width.
struct DashboardLucideGlyph: Hashable, Sendable {
    let rawValue: String

    private init(_ name: String, stroke: String = "s15") {
        rawValue = "lucide-\(name)-\(stroke)"
    }

    static let squarePen = Self("square-pen")
    static let fileText = Self("file-text")
    static let calendarDays = Self("calendar-days")
    static let calendarClock = Self("calendar-clock")
    static let libraryBig = Self("library-big")
    static let database = Self("database")
    static let barChart = Self("bar-chart-3")
    static let settings = Self("settings")
    static let plus = Self("plus")
    static let folderOpen = Self("folder-open")
    static let folder = Self("folder")
    static let trash = Self("trash-2")
    static let messageSquare = Self("message-square")
    static let keyRound = Self("key-round")
    static let brain = Self("brain")
    static let search = Self("search")
    static let monitor = Self("monitor")
    static let circleUser = Self("circle-user")
    static let userRound = Self("user-round")
    static let bot = Self("bot")
    static let cpu = Self("cpu")
    static let terminal = Self("terminal")
    static let briefcase = Self("briefcase")
    static let compass = Self("compass")
    static let panelTop = Self("panel-top")
    static let panelsTopLeft = Self("panels-top-left")
    static let radioTower = Self("radio-tower")
    static let container = Self("container")
    static let flame = Self("flame")
    static let rocket = Self("rocket")
    static let sparkles = Self("sparkles")
    static let pin = Self("pin")
    static let upload = Self("upload")
    static let mic = Self("mic")
    static let check = Self("check")

    static let close = Self("x", stroke: "s175")
    static let chevronDown = Self("chevron-down", stroke: "s175")
    static let arrowLeft = Self("arrow-left", stroke: "s175")
    static let arrowRight = Self("arrow-right", stroke: "s175")
    static let panelLeftOpen = Self("panel-left-open", stroke: "s175")
    static let panelRightOpen = Self("panel-right-open", stroke: "s175")
    static let panelLeftClose = Self("panel-left-close", stroke: "s175")
    static let panelRightClose = Self("panel-right-close", stroke: "s175")
    static let rotate = Self("rotate-ccw", stroke: "s175")
    static let calendarDaysControl = Self("calendar-days", stroke: "s175")
    static let calendarClockControl = Self("calendar-clock", stroke: "s175")
    static let libraryBigControl = Self("library-big", stroke: "s175")
    static let alertTriangle = Self("triangle-alert", stroke: "s175")

    static let listFilter = Self("list-filter", stroke: "s20")
    static let searchControl = Self("search", stroke: "s20")
    static let alertCircle = Self("circle-alert", stroke: "s20")
    static let arrowUp = Self("arrow-up", stroke: "s25")
    static let arrowDown = Self("arrow-down", stroke: "s25")

    static let leftCollapse = Self(rawValue: "dashboard-left-collapse-s15")
    static let rightCollapse = Self(rawValue: "dashboard-right-collapse-s15")

    private init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct DashboardLucideIcon: View {
    let glyph: DashboardLucideGlyph
    var size: CGFloat

    var body: some View {
        Image(glyph.rawValue)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum DashboardHarnessLogo: String, CaseIterable, Sendable {
    case codex
    case claude
    case grok
    case openClaw
    case hermes
    case pi
    case cursor
    case openCode

    static var displayCases: [DashboardHarnessLogo] {
        allCases.sorted(by: { $0.sortsBefore($1) })
    }

    func sortsBefore(_ other: DashboardHarnessLogo) -> Bool {
        if self == .codex { return other != .codex }
        if other == .codex { return false }
        let comparison = displayName.localizedCaseInsensitiveCompare(other.displayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return rawValue < other.rawValue
    }

    init(runtimeKind: AgentRuntimeKind) {
        switch runtimeKind {
        case .codex: self = .codex
        case .claudeCode: self = .claude
        case .grokBuild: self = .grok
        case .openclaw: self = .openClaw
        case .hermes: self = .hermes
        case .pi: self = .pi
        case .cursor: self = .cursor
        case .opencode: self = .openCode
        }
    }

    static func resolve(
        harnessIdentifier: String,
        runtimeKind: AgentRuntimeKind? = nil
    ) -> DashboardHarnessLogo? {
        if let runtimeKind {
            return DashboardHarnessLogo(runtimeKind: runtimeKind)
        }
        let identity = harnessIdentifier
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return switch identity {
        case "codex", "codexcli", "openaicodex": .codex
        case "claude", "claudecode", "claudeai": .claude
        case "grok", "grokbuild": .grok
        case "openclaw": .openClaw
        case "hermes", "hermesagent": .hermes
        case "pi", "piagent", "pimono", "picodingagent": .pi
        case "cursor", "cursoragent", "cursorcli": .cursor
        case "opencode", "opencodeai": .openCode
        default: nil
        }
    }

    var assetName: String {
        switch self {
        case .codex: "harness-codex"
        case .claude: "harness-claude"
        case .grok: "harness-grok"
        case .openClaw: "harness-openclaw"
        case .hermes: "harness-hermes"
        case .pi: "harness-pi"
        case .cursor: "harness-cursor"
        case .openCode: "harness-opencode"
        }
    }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .grok: "Grok Build"
        case .openClaw: "OpenClaw"
        case .hermes: "Hermes"
        case .pi: "Pi"
        case .cursor: "Cursor"
        case .openCode: "OpenCode"
        }
    }

    var usesTemplateRendering: Bool {
        false
    }
}

enum DashboardCodexLogoStyle: String, CaseIterable, Sendable {
    case cloud
    case openAIMark

    static let storageKey = "wovenmatter.codexHarnessLogoStyle"
    static let defaultStyle = DashboardCodexLogoStyle.cloud

    var assetName: String {
        switch self {
        case .cloud: "harness-codex"
        case .openAIMark: "harness-openai"
        }
    }

    var displayName: String {
        switch self {
        case .cloud: "Codex Cloud"
        case .openAIMark: "OpenAI"
        }
    }

    var usesTemplateRendering: Bool {
        self == .openAIMark
    }

    var next: DashboardCodexLogoStyle {
        switch self {
        case .cloud: .openAIMark
        case .openAIMark: .cloud
        }
    }
}

struct DashboardHarnessLogoIcon: View {
    let logo: DashboardHarnessLogo
    var size: CGFloat
    @AppStorage(DashboardCodexLogoStyle.storageKey) private var storedCodexLogoStyle =
        DashboardCodexLogoStyle.defaultStyle.rawValue

    private var codexLogoStyle: DashboardCodexLogoStyle {
        DashboardCodexLogoStyle(rawValue: storedCodexLogoStyle) ?? .defaultStyle
    }

    private var assetName: String {
        logo == .codex ? codexLogoStyle.assetName : logo.assetName
    }

    private var usesTemplateRendering: Bool {
        logo == .codex ? codexLogoStyle.usesTemplateRendering : logo.usesTemplateRendering
    }

    var body: some View {
        Image(assetName)
            .resizable()
            .renderingMode(usesTemplateRendering ? .template : .original)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum DashboardTheme: String, CaseIterable, Identifiable {
    case green
    case cognac

    static let storageKey = "wovenmatter.dashboard.theme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .green: "Green"
        case .cognac: "Cognac"
        }
    }

    var palette: DashboardPalette {
        switch self {
        case .green:
            DashboardPalette(
                workspace: .hex(0xFFFFFF),
                railFill: .hex(0x004225, opacity: 0.10),
                railRim: .hex(0xFFFFFF, opacity: 0.48),
                railInnerLight: .hex(0xFFFFFF, opacity: 0.10),
                railEdge: .hex(0x002A18, opacity: 0.06),
                railHoverRim: .hex(0xFFFFFF, opacity: 0.64),
                railHoverInner: .hex(0xFFFFFF, opacity: 0.14),
                railHoverShadow: .hex(0x002A18, opacity: 0.22),
                railReducedFill: .hex(0xE4ECE8),
                themeAccent: .hex(0x004225),
                themeWhisper: .hex(0x004225, opacity: 0.05),
                themeSoft: .hex(0x004225, opacity: 0.10),
                themeStrong: .hex(0x004225, opacity: 0.30),
                themeRing: .hex(0x004225, opacity: 0.42),
                border: .hex(0x004225, opacity: 0.11),
                input: .hex(0x004225, opacity: 0.09)
            )
        case .cognac:
            DashboardPalette(
                workspace: .hex(0xF7F6F3),
                railFill: .hex(0xFFFFFF, opacity: 0.88),
                railRim: .clear,
                railInnerLight: .hex(0xFFFFFF, opacity: 0.72),
                railEdge: .clear,
                railHoverRim: .clear,
                railHoverInner: .hex(0xFFFFFF, opacity: 0.88),
                railHoverShadow: .hex(0x4D2D15, opacity: 0.16),
                railReducedFill: .hex(0xFFFFFF),
                themeAccent: .hex(0x9A5A2A),
                themeWhisper: .hex(0x9A5A2A, opacity: 0.05),
                themeSoft: .hex(0x9A5A2A, opacity: 0.07),
                themeStrong: .hex(0x9A5A2A, opacity: 0.11),
                themeRing: .hex(0x9A5A2A, opacity: 0.35),
                border: .hex(0x9A5A2A, opacity: 0.10),
                input: .hex(0x9A5A2A, opacity: 0.08)
            )
        }
    }
}

enum DashboardSidebarStyle: String, CaseIterable, Identifiable {
    case single
    case split

    static let storageKey = "wovenmatter.dashboard.sidebar-style"
    static let defaultStyle = DashboardSidebarStyle.split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: "Single sidebar"
        case .split: "Split sidebars"
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

enum DashboardSidebarPage: Equatable, Sendable {
    case navigation
    case workspace
}

struct DashboardSidebarNavigationState: Equatable, Sendable {
    private(set) var singlePage = DashboardSidebarPage.navigation

    mutating func selectFolder() {
        singlePage = .workspace
    }

    mutating func showNavigation() {
        singlePage = .navigation
    }

    func page(
        for side: DashboardSidebarSide,
        style: DashboardSidebarStyle
    ) -> DashboardSidebarPage {
        switch style {
        case .single:
            singlePage
        case .split:
            side == .left ? .navigation : .workspace
        }
    }
}

struct DashboardPalette {
    static let foreground = Color.hex(0x0A1F16)
    static let mutedForeground = Color.hex(0x5C6F64)
    static let primary = Color.hex(0x004225)
    static let primaryForeground = Color.white
    static let background = Color.white
    static let muted = Color.hex(0x004225, opacity: 0.07)
    static let success = Color.hex(0x0D8F5A)
    static let warning = Color.hex(0xF59E0B)
    static let danger = Color.hex(0xEF4444)

    let workspace: Color
    let railFill: Color
    let railRim: Color
    let railInnerLight: Color
    let railEdge: Color
    let railHoverRim: Color
    let railHoverInner: Color
    let railHoverShadow: Color
    let railReducedFill: Color
    let themeAccent: Color
    let themeWhisper: Color
    let themeSoft: Color
    let themeStrong: Color
    let themeRing: Color
    let border: Color
    let input: Color
}

enum DashboardMetrics {
    static let desktopBreakpoint: CGFloat = 904
    static let splitBreakpoint: CGFloat = 800
    static let railWidth: CGFloat = 256
    static let workspaceMinimumWidth: CGFloat = 360
    static let chatMinimumWidth: CGFloat = 420
    static let companionMinimumWidth: CGFloat = 360
    static let separatorWidth: CGFloat = 12
    static let shellInset: CGFloat = 8
    static let shellGap: CGFloat = 8
    static let windowAlignedSurfaceMinimumRadius: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 10
    static let composerRadius: CGFloat = 18
    static let rowHeight: CGFloat = 28
    static let defaultChatWidthPercent: CGFloat = 58
    static let minimumChatWidthPercent: CGFloat = 20
    static let maximumChatWidthPercent: CGFloat = 80
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
        case .single:
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

private struct DashboardThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = DashboardTheme.green
}

extension EnvironmentValues {
    var dashboardTheme: DashboardTheme {
        get { self[DashboardThemeEnvironmentKey.self] }
        set { self[DashboardThemeEnvironmentKey.self] = newValue }
    }
}

extension Color {
    static func hex(_ value: UInt32, opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: opacity
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

struct DashboardCard<Content: View>: View {
    @Environment(\.dashboardTheme) private var theme
    let showsBorder: Bool
    let content: Content

    init(showsBorder: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsBorder = showsBorder
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(DashboardPalette.background.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous)
                        .stroke(theme.palette.border, lineWidth: 1)
                }
            }
    }
}

struct DashboardSegmentedSelector<Option: Hashable>: View {
    @Environment(\.dashboardTheme) private var theme
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            isSelected
                                ? DashboardPalette.foreground
                                : DashboardPalette.mutedForeground
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 27)
                        .contentShape(Rectangle())
                        .background(
                            isSelected
                                ? DashboardPalette.background
                                : Color.clear
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: DashboardMetrics.controlRadius - 4,
                                style: .continuous
                            )
                        )
                        .shadow(
                            color: isSelected
                                ? DashboardPalette.foreground.opacity(0.06)
                                : .clear,
                            radius: 2,
                            y: 1
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(theme.palette.themeWhisper)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DashboardMetrics.controlRadius,
                style: .continuous
            )
        )
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

struct DashboardSearchField: View {
    @Environment(\.dashboardTheme) private var theme
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            DashboardLucideIcon(glyph: .searchControl, size: 14)
                .foregroundStyle(DashboardPalette.mutedForeground)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DashboardPalette.foreground)
            if !text.isEmpty {
                Button("Clear") { text = "" }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(theme.palette.themeWhisper)
        .clipShape(
            RoundedRectangle(
                cornerRadius: DashboardMetrics.controlRadius,
                style: .continuous
            )
        )
    }
}

struct DashboardPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(DashboardPalette.primaryForeground)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(DashboardPalette.primary.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct DashboardQuietButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(theme.palette.themeSoft.opacity(configuration.isPressed ? 1 : 0.72))
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}
