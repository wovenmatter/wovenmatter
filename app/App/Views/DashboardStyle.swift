import SwiftUI
#if os(iOS)
import UIKit
#endif

// Compiled by both apps. Keep icons, tokens and reusable controls here;
// desktop window/sidebar behavior remains in DashboardDesign.swift.

/// Lucide 0.563.0 template vectors. The suffix records the stroke width.
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
        case .defaultAgent: "lucide-bot-s15"
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

struct DashboardHarnessLogoIcon: View {
    let logo: DashboardHarnessLogo
    var size: CGFloat
    #if os(iOS)
    @Environment(\.colorScheme) private var colorScheme
    #endif
    @AppStorage(DashboardCodexLogoStyle.storageKey) private var storedCodexLogoStyle =
        DashboardCodexLogoStyle.defaultStyle.rawValue

    private var codexLogoStyle: DashboardCodexLogoStyle {
        DashboardCodexLogoStyle(rawValue: storedCodexLogoStyle) ?? .defaultStyle
    }

    private var assetName: String {
        logo == .codex ? codexLogoStyle.assetName : logo.assetName
    }

    private var usesTemplateRendering: Bool {
        #if os(iOS)
        // The original monochrome marks need a contrasting tint on dark surfaces.
        if colorScheme == .dark && [.defaultAgent, .grok, .hermes].contains(logo) { return true }
        #endif
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
                workspace: .dashboardAdaptive(0xFFFFFF, dark: 0x171C19),
                railFill: .hex(0x004225, opacity: 0.10),
                railRim: .hex(0xFFFFFF, opacity: 0.48),
                railInnerLight: .hex(0xFFFFFF, opacity: 0.10),
                railEdge: .hex(0x002A18, opacity: 0.06),
                railHoverRim: .hex(0xFFFFFF, opacity: 0.64),
                railHoverInner: .hex(0xFFFFFF, opacity: 0.14),
                railReducedFill: .hex(0xE4ECE8),
                themeAccent: .dashboardAdaptive(0x004225, dark: 0x6EC799),
                themeWhisper: .dashboardAdaptive(0x004225, dark: 0x6EC799, opacity: 0.05),
                themeSoft: .dashboardAdaptive(0x004225, dark: 0x6EC799, opacity: 0.10),
                themeStrong: .dashboardAdaptive(0x004225, dark: 0x6EC799, opacity: 0.30),
                themeRing: .dashboardAdaptive(0x004225, dark: 0x6EC799, opacity: 0.42),
                border: .dashboardAdaptive(0x004225, dark: 0x6EC799, opacity: 0.11),
                input: .dashboardAdaptive(0x004225, dark: 0x6EC799, opacity: 0.09)
            )
        case .cognac:
            DashboardPalette(
                workspace: .dashboardAdaptive(0xF7F6F3, dark: 0x211C18),
                railFill: .hex(0xFFFFFF, opacity: 0.88),
                railRim: .clear,
                railInnerLight: .hex(0xFFFFFF, opacity: 0.72),
                railEdge: .clear,
                railHoverRim: .clear,
                railHoverInner: .hex(0xFFFFFF, opacity: 0.88),
                railReducedFill: .hex(0xFFFFFF),
                themeAccent: .dashboardAdaptive(0x9A5A2A, dark: 0xDCAB83),
                themeWhisper: .dashboardAdaptive(0x9A5A2A, dark: 0xDCAB83, opacity: 0.05),
                themeSoft: .dashboardAdaptive(0x9A5A2A, dark: 0xDCAB83, opacity: 0.07),
                themeStrong: .dashboardAdaptive(0x9A5A2A, dark: 0xDCAB83, opacity: 0.11),
                themeRing: .dashboardAdaptive(0x9A5A2A, dark: 0xDCAB83, opacity: 0.35),
                border: .dashboardAdaptive(0x9A5A2A, dark: 0xDCAB83, opacity: 0.10),
                input: .dashboardAdaptive(0x9A5A2A, dark: 0xDCAB83, opacity: 0.08)
            )
        }
    }
}

struct DashboardPalette {
    static let calendarEvent = DashboardTheme.green.palette.themeAccent
    static let calendarTask = Color.hex(0x4169E1)
    static let calendarRecurringEvent = Color.hex(0x7462A6)
    static let calendarRecurringTask = DashboardTheme.cognac.palette.themeAccent
    static let foreground = Color.dashboardAdaptive(0x0A1F16, dark: 0xE6F2EB)
    static let mutedForeground = Color.dashboardAdaptive(0x5C6F64, dark: 0xA9B9AF)
    static let primary = Color.hex(0x004225)
    static let primaryForeground = Color.white
    static let background = Color.dashboardAdaptive(0xFFFFFF, dark: 0x252D28)
    static let muted = Color.hex(0x004225, opacity: 0.07)
    static let success = Color.dashboardAdaptive(0x0D8F5A, dark: 0x6EC799)
    static let warning = Color.hex(0xF59E0B)
    static let danger = Color.hex(0xEF4444)

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
                DashboardPalette.primary.opacity(
                    configuration.isPressed ? 0.78 : (isEnabled && isHovering ? 0.9 : 1)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
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
    /// Mobile supports system dark appearance; desktop retains its light palettes.
    static func dashboardAdaptive(_ light: UInt32, dark: UInt32, opacity: Double = 1) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: opacity)
        })
        #else
        .hex(light, opacity: opacity)
        #endif
    }
}
