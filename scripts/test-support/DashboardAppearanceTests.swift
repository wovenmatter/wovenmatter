import AppKit
import SwiftUI

@main @MainActor
struct DashboardAppearanceTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func resolve(_ color: NSColor, appearance: NSAppearance.Name) -> NSColor {
        var result: NSColor?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) }
        return result!
    }

    static func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func main() {
        for (color, hex) in [(DashboardColors.foreground, "#0A1F16"), (DashboardColors.mutedForeground, "#5C6F64"),
                             (DashboardColors.primary, "#004225"), (DashboardColors.success, "#0D8F5A"),
                             (DashboardColors.background, "#FFFFFF"), (DashboardColors.calendarRecurringTask, "#9A5A2A")] {
            require(DashboardColors.documentColorHex(color) == hex, "An existing light-theme semantic color changed")
        }
        let backgrounds = [DashboardColors.darkWorkspace, DashboardColors.darkRail, DashboardColors.darkSurface, 0x304637]
        for ink in [DashboardColors.foreground, DashboardColors.mutedForeground, DashboardColors.success, DashboardColors.calendarRecurringTask] {
            for background in backgrounds {
                require(contrast(resolve(ink, appearance: .darkAqua), DashboardColors.color(background)) >= 4.5,
                        "Dark text lacks contrast on a supported surface")
            }
        }
        require(contrast(resolve(DashboardColors.primaryForeground, appearance: .darkAqua), DashboardColors.primaryFill) >= 4.5,
                "Filled actions lost legible text")
        let color = Color(nsColor: DashboardColors.foreground)
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        let light = color.resolve(in: environment)
        environment.colorScheme = .dark
        let dark = color.resolve(in: environment)
        require(dark.red > light.red + 0.4, "SwiftUI did not resolve the shared color from its theme environment")
        for authoredInk in [UInt32(0x111827), 0x004225, 0x9A5A2A, 0xD23F3F] {
            let adapted = DashboardColors.noteForeground(DashboardColors.color(authoredInk))
            let highlight = DashboardColors.noteBackground(.white)
            require(contrast(resolve(adapted, appearance: .darkAqua), resolve(highlight, appearance: .darkAqua)) >= 4.5,
                    "Authored note ink is unreadable on a dark highlight or cell fill")
            require(DashboardColors.documentColorHex(adapted) == String(format: "#%06X", authoredInk),
                    "Note presentation changed the serialized ink")
        }
        let authoredHTML = "<style>body{background:#fff;color:#111}</style><article>Keep my colors</article>"
        let linkedData = "{\"text\":\"</script>&data\"}"
        let lightHTML = DashboardHTMLArtifactDocument.render(html: authoredHTML, linkedDataJSON: linkedData, emptyAppearance: .light)
        let darkHTML = DashboardHTMLArtifactDocument.render(html: authoredHTML, linkedDataJSON: linkedData, emptyAppearance: .dark)
        require(lightHTML == darkHTML && darkHTML.contains(authoredHTML), "Theme selection recolored authored HTML")
        require(!darkHTML.contains("</script>&data"), "HTML linked data escaped its script boundary")
        let emptyLight = DashboardHTMLArtifactDocument.render(html: "", linkedDataJSON: nil, emptyAppearance: .light)
        let emptyDark = DashboardHTMLArtifactDocument.render(html: "", linkedDataJSON: nil, emptyAppearance: .dark)
        require(emptyLight != emptyDark && emptyDark.contains("#1B1D1A"), "The app-owned empty artifact did not become dark")
        print("PASS: light palette preservation, native/SwiftUI dark resolution, text contrast, note color persistence and authored HTML isolation")
    }
}
