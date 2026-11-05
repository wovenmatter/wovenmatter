import SwiftUI

// Stub app chrome so the shared presentation files typecheck with the iOS SDK.
enum DashboardPalette {
    static let foreground = Color(red: 0.039, green: 0.122, blue: 0.086)
    static let primary = Color(red: 0, green: 0.259, blue: 0.145)
    static let mutedForeground = Color.gray
}

struct DashboardIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
