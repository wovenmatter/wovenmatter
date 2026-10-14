import SwiftUI
#if os(macOS)
import AppKit
typealias DashboardNativeColor = NSColor
#else
import UIKit
typealias DashboardNativeColor = UIColor
#endif

/// Shared semantic colors resolve against the appearance of each window.
/// Green and Cognac use Aqua; Dark uses Dark Aqua. Document colors retain their
/// light representation for serialization, independently of their dark display.
enum DashboardColors {
    static let darkWorkspace: UInt32 = 0x1B1D1A
    static let darkRail: UInt32 = 0x242A24
    static let darkSurface: UInt32 = 0x2A302A
    static let darkForeground: UInt32 = 0xE5E9E0
    static let darkMutedForeground: UInt32 = 0xAAB4A8
    static let darkGreen: UInt32 = 0x8BBC9E
    static let darkCognac: UInt32 = 0xD7A477

    static let foreground = adaptive(light: 0x0A1F16, dark: darkForeground)
    static let mutedForeground = adaptive(light: 0x5C6F64, dark: darkMutedForeground)
    static let primary = adaptive(light: 0x004225, dark: darkGreen)
    static let primaryFill = color(0x004225)
    static let primaryForeground = adaptive(light: 0xFFFFFF, dark: darkForeground)
    static let background = adaptive(light: 0xFFFFFF, dark: darkSurface)
    static let success = adaptive(light: 0x0D8F5A, dark: darkGreen)
    static let warning = adaptive(light: 0xF59E0B, dark: 0xF5B84D)
    static let danger = adaptive(light: 0xEF4444, dark: 0xFF8383)
    static let calendarTask = adaptive(light: 0x4169E1, dark: 0x91A7EF)
    static let calendarRecurringEvent = adaptive(light: 0x7462A6, dark: 0xB5A5DC)
    static let calendarRecurringTask = adaptive(light: 0x9A5A2A, dark: darkCognac)

    #if os(macOS)
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    #endif

    static func adaptive(light: UInt32, dark: UInt32) -> DashboardNativeColor {
        #if os(macOS)
        DashboardNativeColor(name: nil) { appearance in
            color(isDark(appearance) ? dark : light)
        }
        #else
        DashboardNativeColor { traits in
            color(traits.userInterfaceStyle == .dark ? dark : light)
        }
        #endif
    }

    static func color(_ hex: UInt32) -> DashboardNativeColor {
        Components(red: CGFloat((hex >> 16) & 0xFF) / 255,
                   green: CGFloat((hex >> 8) & 0xFF) / 255,
                   blue: CGFloat(hex & 0xFF) / 255, alpha: 1).color
    }

    /// Keeps authored ink recognizable without changing its saved value.
    static func noteForeground(_ original: DashboardNativeColor = defaultNoteForeground) -> DashboardNativeColor {
        let light = components(original, dark: false)
        let cream = components(color(darkForeground), dark: false)
        let backdrop = mix(components(color(darkWorkspace), dark: false),
                           components(.white, dark: false), fraction: 0.20)
        var dark = light
        if luminance(light) < 0.025 {
            dark = cream
        } else {
            // Enough headroom for the darker highlight and table fills too.
            for _ in 0..<32 where contrast(dark, backdrop) < 4.5 {
                dark = mix(dark, cream, fraction: 0.08)
            }
            dark.alpha = 1
        }
        return adaptive(light: light, dark: dark)
    }

    /// Highlights and explicit cell fills stay recognizable but lose their glare.
    static func noteBackground(_ original: DashboardNativeColor) -> DashboardNativeColor {
        let light = components(original, dark: false)
        let backdrop = components(color(darkWorkspace), dark: false)
        return adaptive(light: light, dark: mix(backdrop, light, fraction: 0.20))
    }

    /// Never serialize a window's dark rendering back into a note.
    static func documentColorHex(_ color: DashboardNativeColor?) -> String? {
        guard let color else { return nil }
        guard let rgb = resolvedComponents(color, dark: false) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(rgb.red * 255)),
                      Int(round(rgb.green * 255)), Int(round(rgb.blue * 255)))
    }

    static var defaultNoteForeground: DashboardNativeColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }

    private struct Components: Sendable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
        var alpha: CGFloat
        var color: DashboardNativeColor {
            #if os(macOS)
            DashboardNativeColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
            #else
            DashboardNativeColor(red: red, green: green, blue: blue, alpha: alpha)
            #endif
        }
    }

    private static func components(_ color: DashboardNativeColor, dark: Bool) -> Components {
        resolvedComponents(color, dark: dark) ?? Components(red: 0, green: 0, blue: 0, alpha: 1)
    }

    private static func resolvedComponents(_ color: DashboardNativeColor, dark: Bool) -> Components? {
        #if os(macOS)
        var resolved: DashboardNativeColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        guard let rgb = resolved else { return nil }
        return Components(red: rgb.redComponent, green: rgb.greenComponent,
                          blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        #else
        let rgb = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return Components(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }

    private static func adaptive(light: Components, dark: Components) -> DashboardNativeColor {
        #if os(macOS)
        DashboardNativeColor(name: nil) { appearance in (isDark(appearance) ? dark : light).color }
        #else
        DashboardNativeColor { traits in (traits.userInterfaceStyle == .dark ? dark : light).color }
        #endif
    }

    private static func mix(_ first: Components, _ second: Components, fraction: CGFloat) -> Components {
        Components(red: first.red + (second.red - first.red) * fraction,
                   green: first.green + (second.green - first.green) * fraction,
                   blue: first.blue + (second.blue - first.blue) * fraction, alpha: 1)
    }

    private static func luminance(_ value: Components) -> CGFloat {
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(value.red) + 0.7152 * linear(value.green) + 0.0722 * linear(value.blue)
    }

    private static func contrast(_ first: Components, _ second: Components) -> CGFloat {
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
