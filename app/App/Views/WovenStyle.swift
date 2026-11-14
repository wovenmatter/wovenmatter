import SwiftUI
#if os(iOS)
import UIKit
#endif

// Compiled by both apps. Keep icons, tokens and reusable controls here;
// desktop window/sidebar behavior remains in DesktopDesign.swift.

/// Lucide 1.67.0 template vectors. The suffix records the stroke width.
struct LucideGlyph: Hashable, Sendable {
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
    static let shieldCheck = Self("shield-check")
    static let brain = Self("brain")
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
    static let chevronsLeft = Self("chevrons-left", stroke: "s175")
    static let arrowLeft = Self("arrow-left", stroke: "s175")
    static let arrowRight = Self("arrow-right", stroke: "s175")
    static let arrowLeftRight = Self("arrow-left-right", stroke: "s175")
    static let panelLeftOpen = Self("panel-left-open", stroke: "s175")
    static let panelRightOpen = Self("panel-right-open", stroke: "s175")
    static let panelLeftClose = Self("panel-left-close", stroke: "s175")
    static let rotate = Self("rotate-ccw", stroke: "s175")
    static let calendarDaysControl = Self("calendar-days", stroke: "s175")
    static let calendarClockControl = Self("calendar-clock", stroke: "s175")
    static let libraryBigControl = Self("library-big", stroke: "s175")
    static let alertTriangle = Self("triangle-alert", stroke: "s175")

    static let listFilter = Self("list-filter", stroke: "s20")
    static let searchControl = Self("search", stroke: "s20")
    static let alertCircle = Self("circle-alert", stroke: "s20")
    static let circleCheck = Self("circle-check", stroke: "s20")
    static let gitBranch = Self("git-branch")
    static let messageSquareReply = Self("message-square-reply")
    static let copy = Self("copy")
    static let columns = Self("columns-2", stroke: "s175")
    static let maximize = Self("maximize-2", stroke: "s175")
    static let externalLink = Self("external-link", stroke: "s175")
    static let arrowUp = Self("arrow-up", stroke: "s25")
    static let arrowDown = Self("arrow-down", stroke: "s25")

    static let leftCollapse = Self(rawValue: "sidebar-left-collapse-s15")
    static let rightCollapse = Self(rawValue: "sidebar-right-collapse-s15")

    private init(rawValue: String) {
        self.rawValue = rawValue
    }
}

struct LucideIcon: View {
    let glyph: LucideGlyph
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

enum HarnessLogo: String, CaseIterable, Sendable {
    case defaultAgent
    case codex
    case claude
    case grok
    case openCode

    static func resolve(
        harnessIdentifier: String
    ) -> HarnessLogo? {
        let identity = harnessIdentifier
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return switch identity {
        // An iPhone's on-device Pi Durable runtime reports itself as `pi`.
        case "defaultagent", "wovendefaultagent", "pidurable": .defaultAgent
        case "codex", "codexcli", "openaicodex": .codex
        case "claude", "claudecode", "claudeai": .claude
        case "grok", "grokbuild": .grok
        case "opencode", "opencodeai": .openCode
        default: nil
        }
    }

    var assetName: String {
        switch self {
        case .codex: "harness-codex"
        case .claude: "harness-claude"
        case .grok: "harness-grok"
        case .defaultAgent: PiDurableLogoStyle.defaultStyle.assetName
        case .openCode: "harness-opencode"
        }
    }

    var usesTemplateRendering: Bool {
        false
    }
}

enum CodexLogoStyle: String, CaseIterable, Sendable {
    case cloud
    case openAIMark

    static let storageKey = "wovenmatter.codexHarnessLogoStyle"
    static let defaultStyle = CodexLogoStyle.cloud

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

    var next: CodexLogoStyle {
        switch self {
        case .cloud: .openAIMark
        case .openAIMark: .cloud
        }
    }
}

enum PiDurableLogoStyle: String, CaseIterable, Sendable {
    case color
    case monochrome

    static let storageKey = "wovenmatter.piDurableLogoStyle"
    static let defaultStyle = PiDurableLogoStyle.color

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

    var next: PiDurableLogoStyle {
        switch self {
        case .color: .monochrome
        case .monochrome: .color
        }
    }
}

struct HarnessLogoIcon: View {
    let logo: HarnessLogo
    var size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CodexLogoStyle.storageKey) private var storedCodexLogoStyle =
        CodexLogoStyle.defaultStyle.rawValue

    private var codexLogoStyle: CodexLogoStyle {
        CodexLogoStyle(rawValue: storedCodexLogoStyle) ?? .defaultStyle
    }

    @AppStorage(PiDurableLogoStyle.storageKey) private var storedPiDurableLogoStyle =
        PiDurableLogoStyle.defaultStyle.rawValue

    private var piDurableLogoStyle: PiDurableLogoStyle {
        PiDurableLogoStyle(rawValue: storedPiDurableLogoStyle) ?? .defaultStyle
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
        if colorScheme == .dark && logo == .grok { return true }
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

enum WovenTheme: String, CaseIterable, Identifiable {
    case green
    case cognac
    case dark

    static let storageKey = "wovenmatter.theme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .green: "Green"
        case .cognac: "Cognac"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }

    var palette: WovenPalette {
        switch self {
        case .green:
            WovenPalette(
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
            WovenPalette(
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
            WovenPalette(
                workspace: .hex(WovenColors.darkWorkspace),
                railFill: .hex(WovenColors.darkRail),
                railRim: .hex(0x3B443B, opacity: 0.65),
                railInnerLight: .clear,
                railEdge: .clear,
                railHoverRim: .hex(0x526553, opacity: 0.75),
                railHoverInner: .clear,
                railReducedFill: .hex(WovenColors.darkRail),
                themeAccent: .hex(WovenColors.darkGreen),
                themeWhisper: .hex(WovenColors.darkGreen, opacity: 0.05),
                themeSoft: .hex(WovenColors.darkGreen, opacity: 0.10),
                themeStrong: .hex(WovenColors.darkGreen, opacity: 0.18),
                themeRing: .hex(WovenColors.darkGreen, opacity: 0.42),
                border: .hex(0x3B443B),
                input: .hex(WovenColors.darkSurface)
            )
        }
    }
}

struct WovenPalette {
    static let calendarTask = Color(wovenColor: WovenColors.calendarTask)
    static let calendarRecurringEvent = Color(wovenColor: WovenColors.calendarRecurringEvent)
    static let calendarRecurringTask = Color(wovenColor: WovenColors.calendarRecurringTask)
    static let foreground = Color(wovenColor: WovenColors.foreground)
    static let mutedForeground = Color(wovenColor: WovenColors.mutedForeground)
    static let primary = Color(wovenColor: WovenColors.primary)
    static let primaryFill = Color(wovenColor: WovenColors.primaryFill)
    static let primaryForeground = Color(wovenColor: WovenColors.primaryForeground)
    static let background = Color(wovenColor: WovenColors.background)
    static let muted = primary.opacity(0.07)
    static let success = Color(wovenColor: WovenColors.success)
    static let warning = Color(wovenColor: WovenColors.warning)
    static let danger = Color(wovenColor: WovenColors.danger)
    // Fixed provider series for Usage. These were checked for separation against each
    // theme's workspace surface; rows and tooltips also name each provider.
    static let usageGreen = Color.adaptiveHex(0x0D8F5A, dark: 0x45AB7F)
    static let usageOrange = Color.adaptiveHex(0xC46B3C, dark: 0xD98852)
    static let usageTeal = Color.adaptiveHex(0x0B93A8, dark: 0x36A9B4)
    static let usageBlue = Color.adaptiveHex(0x4D69D8, dark: 0x6F86E2)
    static let usagePurple = Color.adaptiveHex(0x8E2F9E, dark: 0xDDA0E4)
    static let usagePink = Color.adaptiveHex(0xE05D8B, dark: 0xE8789F)
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

enum WovenMetrics {
    static let windowMinimumWidth: CGFloat = 760
    static let desktopBreakpoint: CGFloat = 904
    static let splitBreakpoint: CGFloat = 800
    static let railWidth: CGFloat = 256
    static let workspaceMinimumWidth: CGFloat = 360
    static let chatMinimumWidth: CGFloat = 420
    static let assetPaneMinimumWidth: CGFloat = 360
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

private struct SidebarForegroundKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

private struct WovenThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = WovenTheme.green
}

extension EnvironmentValues {
    var sidebarForeground: Color? {
        get { self[SidebarForegroundKey.self] }
        set { self[SidebarForegroundKey.self] = newValue }
    }

    var wovenTheme: WovenTheme {
        get { self[WovenThemeEnvironmentKey.self] }
        set { self[WovenThemeEnvironmentKey.self] = newValue }
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
struct WovenInputModifier: ViewModifier {
    @Environment(\.wovenTheme) private var theme
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(WovenControlMetrics.inputFont)
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: WovenControlMetrics.searchHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.themeWhisper)
            .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
    }
}

extension View {
    func wovenInput() -> some View { modifier(WovenInputModifier()) }
}

struct WovenSearchField: View {
    @Environment(\.wovenTheme) private var theme
    @Environment(\.sidebarForeground) private var sidebarForeground
    @Binding var text: String
    let prompt: String
    /// A smaller field for dense filter columns.
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            LucideIcon(glyph: .searchControl, size: compact ? 12 : 14)
                .foregroundStyle(sidebarForeground ?? WovenPalette.mutedForeground)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(sidebarForeground ?? Color.secondary))
                .textFieldStyle(.plain)
                .font(compact ? .system(size: 12) : WovenControlMetrics.inputFont)
                .foregroundStyle(WovenPalette.foreground)
            if !text.isEmpty {
                Button("Clear") { text = "" }
                    .buttonStyle(.plain)
                    .font(WovenControlMetrics.clearFont)
                    .frame(minHeight: WovenControlMetrics.clearHeight)
                    .foregroundStyle(sidebarForeground ?? WovenPalette.mutedForeground)
            }
        }
        .padding(.horizontal, compact ? 8 : 12)
        .frame(minHeight: compact ? 28 : WovenControlMetrics.searchHeight)
        .frame(maxWidth: .infinity)
        .background(theme.palette.themeWhisper)
        .clipShape(
            RoundedRectangle(
                cornerRadius: WovenMetrics.controlRadius,
                style: .continuous
            )
        )
    }
}

struct WovenPrimaryButtonStyle: ButtonStyle {
    @Environment(\.wovenTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WovenControlMetrics.buttonFont)
            .foregroundStyle(WovenPalette.primaryForeground)
            .padding(.horizontal, 14)
            .frame(minHeight: WovenControlMetrics.minimumHeight)
            .background(
                WovenPalette.primaryFill.opacity(
                    configuration.isPressed ? 0.78 : (isEnabled && isHovering ? 0.9 : 1)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
            .overlay {
                if theme == .dark {
                    RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous)
                        .stroke(theme.palette.themeRing, lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}

struct WovenQuietButtonStyle: ButtonStyle {
    @Environment(\.wovenTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WovenControlMetrics.buttonFont)
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: WovenControlMetrics.minimumHeight)
            .background(
                theme.palette.themeSoft.opacity(
                    configuration.isPressed ? 1 : (isEnabled && isHovering ? 0.72 : 0.5)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}

struct WovenSegmentedSelector<Option: Hashable>: View {
    @Environment(\.wovenTheme) private var theme
    @Environment(\.sidebarForeground) private var sidebarForeground
    let options: [Option]
    @Binding var selection: Option
    var accentSelection = false
    /// A spoken name when the visible label is abbreviated.
    var accessibilityLabel: ((Option) -> String)?
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(WovenControlMetrics.segmentFont)
                        .foregroundStyle(
                            sidebarForeground ?? (isSelected
                                ? (accentSelection ? WovenPalette.primaryForeground : WovenPalette.foreground)
                                : WovenPalette.mutedForeground)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: WovenControlMetrics.segmentHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(WovenSegmentButtonStyle(isSelected: isSelected, accentSelection: accentSelection))
                .accessibilityLabel(accessibilityLabel?(option) ?? label(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(theme.palette.themeWhisper)
        .clipShape(
            RoundedRectangle(
                cornerRadius: WovenMetrics.controlRadius,
                style: .continuous
            )
        )
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct WovenSegmentButtonStyle: ButtonStyle {
    @Environment(\.wovenTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false

    let isSelected: Bool
    var accentSelection = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: WovenMetrics.controlRadius - 4,
            style: .continuous
        )

        configuration.label
            .background {
                ZStack {
                    shape.fill(
                        isSelected
                            ? (accentSelection ? WovenPalette.primary : WovenPalette.background.opacity(reduceTransparency ? 1 : 0.96))
                            : .clear
                    )
                    shape.fill(interactionColor(isPressed: configuration.isPressed))
                }
            }
            .shadow(
                color: isSelected && isEnabled
                    ? WovenPalette.foreground.opacity(0.06)
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

struct WovenIconButtonStyle: ButtonStyle {
    @Environment(\.wovenTheme) private var theme
    @Environment(\.sidebarForeground) private var sidebarForeground
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(sidebarForeground ?? WovenPalette.mutedForeground)
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

private enum WovenControlMetrics {
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
    init(wovenColor: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: wovenColor)
        #else
        self.init(uiColor: wovenColor)
        #endif
    }

    static func adaptiveHex(_ light: UInt32, dark: UInt32) -> Color {
        Color(wovenColor: WovenColors.adaptive(light: light, dark: dark))
    }
}
