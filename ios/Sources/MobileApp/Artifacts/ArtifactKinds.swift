import SwiftUI
import WovenProtocol

/// Each kind's icon, as the Mac's artifact rows draw it.
struct ArtifactKindIcon: View {
  let kind: NoteArtifactKind
  var size: CGFloat = 20

  var body: some View {
    switch kind {
    case .note: LucideIcon(glyph: .fileText, size: size)
    case .canvas: LucideIcon(glyph: .panelsTopLeft, size: size)
    case .spreadsheet: Image(systemName: "tablecells").font(.system(size: size * 0.82, weight: .medium))
    case .html: Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: size * 0.75, weight: .medium))
    }
  }
}

extension NoteArtifactKind {
  /// What New Artifact says each kind is, in the Mac's words.
  var newArtifactDetail: String {
    switch self {
    case .note: "A rich text note with lists, tables and links"
    case .canvas: "A fluid document for your work with agents"
    case .spreadsheet: "Rows and columns for data and calculations"
    case .html: "Interactive apps your agent builds on live data"
    }
  }

  /// The filter's name for every artifact of this kind.
  var pluralName: String { displayName + "s" }

  var untitledName: String { "Untitled \(displayName)" }
}

/// New Artifact: Note, Page, Sheet and App, each with what it is.
struct NewArtifactMenuItems: View {
  let create: (NoteArtifactKind) -> Void

  var body: some View {
    ForEach(NoteArtifactKind.allCases, id: \.self) { kind in
      Button { create(kind) } label: {
        Label {
          Text(kind.displayName)
          Text(kind.newArtifactDetail)
        } icon: {
          switch kind {
          case .note: Image(LucideGlyph.fileText.rawValue)
          case .canvas: Image(LucideGlyph.panelsTopLeft.rawValue)
          case .spreadsheet: Image(systemName: "tablecells")
          case .html: Image(systemName: "chevron.left.forwardslash.chevron.right")
          }
        }
      }
      .accessibilityIdentifier("new-artifact-\(kind.rawValue)")
    }
  }
}
