import SwiftUI
#if os(iOS)
import UIKit
#endif

// Compiled by both apps. Keep icons, tokens and reusable controls here;
// desktop window/sidebar behavior remains in DashboardDesign.swift.

/// Lucide 1.61.0 template vectors. The suffix records the stroke width.
struct DashboardLucideGlyph: Hashable, Sendable {
    let rawValue: String

    private init(_ name: String, stroke: String = "s15") {
        rawValue = "lucide-\(name)-\(stroke)"
    }

    static let house = Self("house")
    static let squarePen = Self("square-pen")
    static let fileText = Self("file-text")
    static let calendarDays = Self("calendar-days")
    static let calendarClock = Self("calendar-clock")
    static let libraryBig = Self("library-big")
    static let database = Self("database")
    static let barChart = Self("bar-chart-3")
    static let settings = Self("settings")
    static let plug = Self("plug")
    static let plus = Self("plus")
    static let folderOpen = Self("folder-open")
    static let folder = Self("folder")
    static let trash = Self("trash-2")
    static let messageSquare = Self("message-square")
    static let keyRound = Self("key-round")
    static let brain = Self("brain")
    static let search = Self("search")
    static let monitor = Self("monitor")
    static let smartphone = Self("smartphone")
    static let tablet = Self("tablet")
    static let circleUser = Self("circle-user")
    static let userRound = Self("user-round")
    static let bot = Self("bot")
    static let cpu = Self("cpu")
    static let terminal = Self("terminal")
    static let briefcase = Self("briefcase")
    static let compass = Self("compass")
    static let panelTop = Self("panel-top")
    static let panelsTopLeft = Self("panels-top-left")
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
    case defaultAgent
    case codex
    case claude
    case grok
    case openClaw
    case hermes
    case pi
    case cursor
    case openCode

    static func resolve(
        harnessIdentifier: String
    ) -> DashboardHarnessLogo? {
        let identity = harnessIdentifier
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return switch identity {
        case "defaultagent", "wovendefaultagent": .defaultAgent
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
        case .defaultAgent: DashboardPiDurableLogoStyle.defaultStyle.assetName
        case .pi: "harness-pi"
        case .cursor: "harness-cursor"
        case .openCode: "harness-opencode"
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

enum DashboardPiDurableLogoStyle: String, CaseIterable, Sendable {
    case color
    case monochrome

    static let storageKey = "wovenmatter.piDurableLogoStyle"
    static let defaultStyle = DashboardPiDurableLogoStyle.color

    var assetName: String {
        switch self {
        case .color: "harness-pi-primary"
        case .monochrome: "harness-pi"
        }
    }

    var displayName: String {
        switch self {
        case .color: "Color"
        case .monochrome: "Black and White"
        }
    }

    var next: DashboardPiDurableLogoStyle {
        switch self {
        case .color: .monochrome
        case .monochrome: .color
        }
    }
}

struct DashboardHarnessLogoIcon: View {
    let logo: DashboardHarnessLogo
    var size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(DashboardCodexLogoStyle.storageKey) private var storedCodexLogoStyle =
        DashboardCodexLogoStyle.defaultStyle.rawValue

    private var codexLogoStyle: DashboardCodexLogoStyle {
        DashboardCodexLogoStyle(rawValue: storedCodexLogoStyle) ?? .defaultStyle
    }

    @AppStorage(DashboardPiDurableLogoStyle.storageKey) private var storedPiDurableLogoStyle =
        DashboardPiDurableLogoStyle.defaultStyle.rawValue

    private var piDurableLogoStyle: DashboardPiDurableLogoStyle {
        DashboardPiDurableLogoStyle(rawValue: storedPiDurableLogoStyle) ?? .defaultStyle
    }

    private var assetName: String {
        switch logo {
        case .codex: codexLogoStyle.assetName
        case .defaultAgent: piDurableLogoStyle.assetName
        default: logo.assetName
        }
    }

    private var usesTemplateRendering: Bool {
        // The original monochrome marks need a contrasting tint on dark surfaces.
        if colorScheme == .dark && [.grok, .hermes].contains(logo) { return true }
        return logo == .codex ? codexLogoStyle.usesTemplateRendering : logo.usesTemplateRendering
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
    case dark

    static let storageKey = "wovenmatter.dashboard.theme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .green: "Green"
        case .cognac: "Cognac"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }

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
                railReducedFill: .hex(0xFFFFFF),
                themeAccent: .hex(0x9A5A2A),
                themeWhisper: .hex(0x9A5A2A, opacity: 0.05),
                themeSoft: .hex(0x9A5A2A, opacity: 0.07),
                themeStrong: .hex(0x9A5A2A, opacity: 0.11),
                themeRing: .hex(0x9A5A2A, opacity: 0.35),
                border: .hex(0x9A5A2A, opacity: 0.10),
                input: .hex(0x9A5A2A, opacity: 0.08)
            )
        case .dark:
            DashboardPalette(
                workspace: .hex(DashboardColors.darkWorkspace),
                railFill: .hex(DashboardColors.darkRail),
                railRim: .hex(0x3B443B, opacity: 0.65),
                railInnerLight: .clear,
                railEdge: .clear,
                railHoverRim: .hex(0x526553, opacity: 0.75),
                railHoverInner: .clear,
                railReducedFill: .hex(DashboardColors.darkRail),
                themeAccent: .hex(DashboardColors.darkGreen),
                themeWhisper: .hex(DashboardColors.darkGreen, opacity: 0.05),
                themeSoft: .hex(DashboardColors.darkGreen, opacity: 0.10),
                themeStrong: .hex(DashboardColors.darkGreen, opacity: 0.18),
                themeRing: .hex(DashboardColors.darkGreen, opacity: 0.42),
                border: .hex(0x3B443B),
                input: .hex(DashboardColors.darkSurface)
            )
        }
    }
}

struct DashboardPalette {
    static let calendarEvent = Color(dashboardColor: DashboardColors.primary)
    static let calendarTask = Color(dashboardColor: DashboardColors.calendarTask)
    static let calendarRecurringEvent = Color(dashboardColor: DashboardColors.calendarRecurringEvent)
    static let calendarRecurringTask = Color(dashboardColor: DashboardColors.calendarRecurringTask)
    static let foreground = Color(dashboardColor: DashboardColors.foreground)
    static let mutedForeground = Color(dashboardColor: DashboardColors.mutedForeground)
    static let primary = Color(dashboardColor: DashboardColors.primary)
    static let primaryFill = Color(dashboardColor: DashboardColors.primaryFill)
    static let primaryForeground = Color(dashboardColor: DashboardColors.primaryForeground)
    static let background = Color(dashboardColor: DashboardColors.background)
    static let muted = primary.opacity(0.07)
    static let success = Color(dashboardColor: DashboardColors.success)
    static let warning = Color(dashboardColor: DashboardColors.warning)
    static let danger = Color(dashboardColor: DashboardColors.danger)
    static let usageBlue = Color.adaptiveHex(0x4D69D8, dark: 0x96A7EE)
    static let usageOrange = Color.adaptiveHex(0xC46B3C, dark: 0xE3A07A)
    static let usageGray = Color.adaptiveHex(0x535A63, dark: 0xA4ACB7)
    static let usagePurple = Color.adaptiveHex(0x8B5CF6, dark: 0xB69BF4)
    static let usagePink = Color.adaptiveHex(0xE05D8B, dark: 0xED98B6)
    static let usageYellow = Color.adaptiveHex(0xC28A20, dark: 0xE3B95A)
    static let usageUnknown = Color.adaptiveHex(0x8A8F98, dark: 0xB0B5BE)

    let workspace: Color
    let railFill: Color
    let railRim: Color
    let railInnerLight: Color
    let railEdge: Color
    let railHoverRim: Color
    let railHoverInner: Color
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
    static let assetToolbarControlWidth: CGFloat = 28
    static let assetToolbarControlHeight: CGFloat = 30
    static let assetToolbarVerticalPadding: CGFloat = 2
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

private struct DashboardSidebarForegroundKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

private struct DashboardThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = DashboardTheme.green
}

extension EnvironmentValues {
    var dashboardSidebarForeground: Color? {
        get { self[DashboardSidebarForegroundKey.self] }
        set { self[DashboardSidebarForegroundKey.self] = newValue }
    }

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

/// Quiet single-line inputs use the same surface as sidebar search. Keep native
/// editing/keyboard behavior without the platform's rounded-border focus ring.
struct DashboardInputModifier: ViewModifier {
    @Environment(\.dashboardTheme) private var theme
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(DashboardControlMetrics.inputFont)
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: DashboardControlMetrics.searchHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.themeWhisper)
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
    }
}

extension View {
    func dashboardInput() -> some View { modifier(DashboardInputModifier()) }
}

struct DashboardSearchField: View {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.dashboardSidebarForeground) private var sidebarForeground
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            DashboardLucideIcon(glyph: .searchControl, size: 14)
                .foregroundStyle(sidebarForeground ?? DashboardPalette.mutedForeground)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(sidebarForeground ?? Color.secondary))
                .textFieldStyle(.plain)
                .font(DashboardControlMetrics.inputFont)
                .foregroundStyle(DashboardPalette.foreground)
            if !text.isEmpty {
                Button("Clear") { text = "" }
                    .buttonStyle(.plain)
                    .font(DashboardControlMetrics.clearFont)
                    .frame(minHeight: DashboardControlMetrics.clearHeight)
                    .foregroundStyle(sidebarForeground ?? DashboardPalette.mutedForeground)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: DashboardControlMetrics.searchHeight)
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
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DashboardControlMetrics.buttonFont)
            .foregroundStyle(DashboardPalette.primaryForeground)
            .padding(.horizontal, 14)
            .frame(minHeight: DashboardControlMetrics.minimumHeight)
            .background(
                DashboardPalette.primaryFill.opacity(
                    configuration.isPressed ? 0.78 : (isEnabled && isHovering ? 0.9 : 1)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .overlay {
                if theme == .dark {
                    RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous)
                        .stroke(theme.palette.themeRing, lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}

struct DashboardQuietButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DashboardControlMetrics.buttonFont)
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: DashboardControlMetrics.minimumHeight)
            .background(
                theme.palette.themeSoft.opacity(
                    configuration.isPressed ? 1 : (isEnabled && isHovering ? 0.72 : 0.5)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}

struct DashboardSegmentedSelector<Option: Hashable>: View {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.dashboardSidebarForeground) private var sidebarForeground
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
                        .font(DashboardControlMetrics.segmentFont)
                        .foregroundStyle(
                            sidebarForeground ?? (isSelected
                                ? DashboardPalette.foreground
                                : DashboardPalette.mutedForeground)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DashboardControlMetrics.segmentHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DashboardSegmentButtonStyle(isSelected: isSelected))
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

private struct DashboardSegmentButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false

    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: DashboardMetrics.controlRadius - 4,
            style: .continuous
        )

        configuration.label
            .background {
                ZStack {
                    shape.fill(
                        isSelected
                            ? DashboardPalette.background.opacity(reduceTransparency ? 1 : 0.96)
                            : .clear
                    )
                    shape.fill(interactionColor(isPressed: configuration.isPressed))
                }
            }
            .shadow(
                color: isSelected && isEnabled
                    ? DashboardPalette.foreground.opacity(0.06)
                    : .clear,
                radius: 2,
                y: 1
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { isHovering = $0 }
    }

    private func interactionColor(isPressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        if isPressed {
            return theme.palette.themeSoft
        }
        return isHovering ? theme.palette.themeWhisper : .clear
    }
}

struct DashboardIconButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.dashboardSidebarForeground) private var sidebarForeground
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(sidebarForeground ?? DashboardPalette.mutedForeground)
            .background(
                isEnabled && (configuration.isPressed || hovered)
                    ? (configuration.isPressed ? theme.palette.themeSoft : theme.palette.themeWhisper)
                    : .clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}

private enum DashboardControlMetrics {
    #if os(iOS)
    static let buttonFont = Font.body.weight(.medium)
    static let inputFont = Font.body
    static let clearFont = Font.caption.weight(.medium)
    static let minimumHeight: CGFloat = 44
    static let segmentFont = Font.subheadline.weight(.medium)
    static let segmentHeight: CGFloat = 44
    static let searchHeight: CGFloat = 44
    static let clearHeight: CGFloat = 44
    #else
    static let buttonFont = Font.system(size: 12.5, weight: .medium)
    static let inputFont = Font.system(size: 13)
    static let clearFont = Font.system(size: 10, weight: .medium)
    static let minimumHeight: CGFloat = 36
    static let segmentFont = Font.system(size: 12, weight: .medium)
    static let segmentHeight: CGFloat = 27
    static let searchHeight: CGFloat = 34
    static let clearHeight: CGFloat = 0
    #endif
}

extension Color {
    init(dashboardColor: DashboardNativeColor) {
        #if os(macOS)
        self.init(nsColor: dashboardColor)
        #else
        self.init(uiColor: dashboardColor)
        #endif
    }

    static func adaptiveHex(_ light: UInt32, dark: UInt32) -> Color {
        Color(dashboardColor: DashboardColors.adaptive(light: light, dark: dark))
    }
}
