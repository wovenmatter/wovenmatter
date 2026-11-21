import SwiftUI
import UIKit
import WovenProtocol

/// One paragraph in the Notes text editor, for a note or a Page flow.
/// `generation` is the session's, read with `block` in the same update, so a
/// paragraph never pairs a stale block with a newer generation.
struct ArtifactTextBlock: View {
  let session: ArtifactTextSession
  let block: NoteRichTextBlock
  let number: Int?
  let generation: Int
  let identity: String

  var body: some View {
    let id = block.id
    RichBlockTextView(block: block, listNumber: number, generation: generation, editable: session.editable,
                      controller: session.controller, dictationEditor: session.dictation, dictationIdentity: identity,
                      focused: { [session] in
                        session.selectedBlockID = id
                        MobileDictation.shared.activeEditor = session.dictation
                      },
                      paragraphBreak: { [session] in session.editParagraphs(id, range: $0, replacement: $1) },
                      deleteAtStart: { [session] in session.mergeBackward(id) },
                      edit: { [session] in session.edit(id, range: $0, replacement: $1) })
  }
}

/// A note: its paragraphs in one scrolling column, its tables beside them.
struct NoteArtifactBody: View {
  let session: ArtifactTextSession

  var body: some View {
    if let document = session.document {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if !session.editable {
            Text("Read only · original format preserved").font(.caption).foregroundStyle(WovenPalette.mutedForeground)
              .padding(.bottom, 8)
          }
          let numbers = RichDocumentEditing.listItemNumbers(document)
          let generation = session.generation
          ForEach(session.renderedBlocks(document), id: \.id) { block in
            switch block {
            case .richText(let text):
              ArtifactTextBlock(session: session, block: text, number: numbers[text.id], generation: generation,
                                identity: "note:\(session.id):\(text.id)")
                .accessibilityIdentifier("note-body-editor-\(text.id)")
            case .table(let table):
              NativeTablePreview(table: table).padding(.vertical, 6)
            }
          }
          // The rest of the note is part of its last line: tapping puts the cursor there.
          Color.clear.frame(maxWidth: .infinity, minHeight: 160).contentShape(Rectangle())
            .onTapGesture { session.focusEnd() }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: 768)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 4)
      }
      .scrollDismissesKeyboard(.interactively)
    } else {
      ArtifactSourceView(content: session.content)
    }
  }
}

/// A document this device cannot read as an artifact: its saved text, untouched.
struct ArtifactSourceView: View {
  let content: String

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("This document uses a format this device cannot edit. Its original data is preserved.")
          .font(.callout).foregroundStyle(WovenPalette.mutedForeground)
        Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)
    }
  }
}

/// Format note (or page): paragraph styles, character formatting, links and fonts.
struct NoteFormatMenuItems: View {
  let session: ArtifactTextSession
  let editLink: () -> Void

  var body: some View {
    Menu("Heading and style") {
      Button("Body") { session.setStyle(.paragraph) }
      ForEach(1...6, id: \.self) { level in
        Button("Heading \(level)") { session.setStyle(NoteParagraphStyle.allCases[level]) }
      }
    }
    Button("Bulleted list", systemImage: "list.bullet") { session.setStyle(.bulletedList) }
    Button("Numbered list", systemImage: "list.number") { session.setStyle(.numberedList) }
    Divider()
    Button("Bold", systemImage: "bold") { session.format(.bold) }
    Button("Italic", systemImage: "italic") { session.format(.italic) }
    Button("Underline", systemImage: "underline") { session.format(.underline) }
    NoteHighlightMenu(session: session)
    Button("Link", systemImage: "link", action: editLink)
    Button("Remove link") { session.format(.link(nil)) }
    Menu("Font") {
      ForEach(["System", "Helvetica Neue", "Avenir Next", "Georgia", "Menlo"], id: \.self) { family in
        Button(family) { session.format(.fontFamily(family == "System" ? nil : family)) }
      }
    }
    Menu("Font size") {
      ForEach([11, 12, 13, 14, 16, 18, 21, 24, 30, 36], id: \.self) { size in
        Button("\(size) pt") { session.format(.fontSize(Double(size))) }
      }
    }
  }
}

private struct NoteHighlightMenu: View {
  let session: ArtifactTextSession

  var body: some View {
    Menu {
      Button("Yellow") { session.format(.highlight("#FFF59D")) }
      Button("Green") { session.format(.highlight("#C8E6C9")) }
      Button("Pink") { session.format(.highlight("#F8BBD0")) }
      Button("Remove highlight") { session.format(.highlight(nil)) }
    } label: {
      Label("Highlight", systemImage: "highlighter")
    }
  }
}

/// The format bar above the keyboard while a note or page is being written.
struct NoteKeyboardBar: View {
  let session: ArtifactTextSession
  let editLink: () -> Void

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 2) {
        Menu {
          Button("Body") { session.setStyle(.paragraph) }
          ForEach(1...3, id: \.self) { level in
            Button("Heading \(level)") { session.setStyle(NoteParagraphStyle.allCases[level]) }
          }
        } label: {
          Image(systemName: "textformat.size").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Heading and style")
        button("bold", "Bold") { session.format(.bold) }
        button("italic", "Italic") { session.format(.italic) }
        button("underline", "Underline") { session.format(.underline) }
        button("list.bullet", "Bulleted list") { session.setStyle(.bulletedList) }
        button("list.number", "Numbered list") { session.setStyle(.numberedList) }
        Menu {
          Button("Yellow") { session.format(.highlight("#FFF59D")) }
          Button("Green") { session.format(.highlight("#C8E6C9")) }
          Button("Pink") { session.format(.highlight("#F8BBD0")) }
          Button("Remove highlight") { session.format(.highlight(nil)) }
        } label: {
          Image(systemName: "highlighter").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Highlight")
        button("link", "Link", action: editLink)
        Spacer(minLength: 8)
        button("keyboard.chevron.compact.down", "Hide keyboard") {
          UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
      }
      .font(.system(size: 17))
      .buttonStyle(WovenIconButtonStyle())
      .padding(.horizontal, 8)
    }
    .scrollIndicators(.never)
    .keepsKeyboard()
    .accessibilityIdentifier("note-keyboard-bar")
  }

  private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44) }
      .accessibilityLabel(label)
  }
}
