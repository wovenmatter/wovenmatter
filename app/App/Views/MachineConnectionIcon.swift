import SwiftUI

struct MachineConnectionIcon: View {
    let platform: Machine.Platform
    var size: CGFloat = 20
    var body: some View {
        Group {
            switch platform {
            case .mac: LucideIcon(glyph: .monitor, size: size)
            case .linux: LucideIcon(glyph: .container, size: size)
            }
        }.frame(width: size + 4, height: size + 4).foregroundStyle(WovenPalette.foreground)
    }
}
