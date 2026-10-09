import SwiftUI
import CompanionClient

// Use asset-backed labels so native menus render the same Lucide glyph as rows.
extension Label where Title == Text, Icon == Image {
  init(_ title: String, glyph: DashboardLucideGlyph) {
    self.init { Text(title) } icon: { Image(glyph.rawValue) }
  }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
  init(_ title: String, glyph: DashboardLucideGlyph, action: @escaping () -> Void) {
    self.init(action: action) { SwiftUI.Label(title, glyph: glyph) }
  }
}

struct MobileAgentIcon: View {
  let runtimeKind: String?
  var size: CGFloat
  var body: some View {
    if let logo = runtimeKind.flatMap({ DashboardHarnessLogo.resolve(harnessIdentifier: $0) }) {
      if logo == .defaultAgent { DashboardLucideIcon(glyph: .bot, size: size) }
      else { DashboardHarnessLogoIcon(logo: logo, size: size) }
    } else { DashboardLucideIcon(glyph: .cpu, size: size) }
  }
}

// Matches DashboardNoteRow, including its intentional system document-kind icons.
struct MobileNoteIcon: View {
  let content: String
  var body: some View {
    switch RichDocumentEditing.document(content)?.kind {
    case .spreadsheet:
      Image(systemName: "tablecells").font(.system(size: 20, weight: .medium))
    case .html:
      Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 19, weight: .medium))
    default:
      DashboardLucideIcon(glyph: .fileText, size: 22)
    }
  }
}
