import AppKit
import SwiftUI
import Testing
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized) struct AppearanceTests {
    private func resolve(_ color: NSColor, appearance: NSAppearance.Name) -> NSColor {
        var result: NSColor?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) }
        return result!
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func lightPaletteDarkResolutionContrastNoteColorPersistenceAndAuthoredHTMLIsolation() {
        for (color, hex) in [(WovenColors.foreground, "#0A1F16"), (WovenColors.mutedForeground, "#5C6F64"),
                             (WovenColors.primary, "#004225"), (WovenColors.success, "#0D8F5A"),
                             (WovenColors.background, "#FFFFFF"), (WovenColors.calendarRecurringTask, "#9A5A2A")] {
            #expect(WovenColors.documentColorHex(color) == hex, "An existing light-theme semantic color changed")
        }
        let backgrounds = [WovenColors.darkWorkspace, WovenColors.darkRail, WovenColors.darkSurface, 0x304637]
        for ink in [WovenColors.foreground, WovenColors.mutedForeground, WovenColors.success, WovenColors.calendarRecurringTask] {
            for background in backgrounds {
                #expect(contrast(resolve(ink, appearance: .darkAqua), WovenColors.color(background)) >= 4.5,
                        "Dark text lacks contrast on a supported surface")
            }
        }
        #expect(contrast(resolve(WovenColors.primaryForeground, appearance: .darkAqua), WovenColors.primaryFill) >= 4.5,
                "Filled actions lost legible text")
        let color = Color(nsColor: WovenColors.foreground)
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        let light = color.resolve(in: environment)
        environment.colorScheme = .dark
        let dark = color.resolve(in: environment)
        #expect(dark.red > light.red + 0.4, "SwiftUI did not resolve the shared color from its theme environment")
        for authoredInk in [UInt32(0x111827), 0x004225, 0x9A5A2A, 0xD23F3F] {
            let adapted = WovenColors.noteForeground(WovenColors.color(authoredInk))
            let highlight = WovenColors.noteBackground(.white)
            #expect(contrast(resolve(adapted, appearance: .darkAqua), resolve(highlight, appearance: .darkAqua)) >= 4.5,
                    "Authored note ink is unreadable on a dark highlight or cell fill")
            #expect(WovenColors.documentColorHex(adapted) == String(format: "#%06X", authoredInk),
                    "Note presentation changed the serialized ink")
        }
        let authoredHTML = "<style>body{background:#fff;color:#111}</style><article>Keep my colors</article>"
        let linkedData = "{\"text\":\"</script>&data\"}"
        let lightHTML = HTMLArtifactDocument.render(html: authoredHTML, linkedDataJSON: linkedData, emptyAppearance: .light)
        let darkHTML = HTMLArtifactDocument.render(html: authoredHTML, linkedDataJSON: linkedData, emptyAppearance: .dark)
        #expect(lightHTML == darkHTML && darkHTML.contains(authoredHTML), "Theme selection recolored authored HTML")
        #expect(!darkHTML.contains("</script>&data"), "HTML linked data escaped its script boundary")
        let emptyLight = HTMLArtifactDocument.render(html: "", linkedDataJSON: nil, emptyAppearance: .light)
        let emptyDark = HTMLArtifactDocument.render(html: "", linkedDataJSON: nil, emptyAppearance: .dark)
        #expect(emptyLight != emptyDark && emptyDark.contains("#1B1D1A"), "The app-owned empty artifact did not become dark")
    }
}
