import SwiftUI

/// The chat transcript's one spacing scale. Every gap, inset and width in a
/// conversation comes from here, in agent chats, bot chats and the Forum alike;
/// font sizes stay with their views.
enum ConversationMetrics {
    /// An assistant turn → the next user message.
    static let turnGap: CGFloat = 32
    /// A user message → the assistant turn that answers it.
    static let replyGap: CGFloat = 24
    /// Work → reply, reply → its files or changed-files card, around a visual reply.
    static let sectionGap: CGFloat = 16
    /// Between work-log entries; a turn's header → its reply.
    static let entryGap: CGFloat = 12
    /// Rows inside a group or a list, detail blocks; a turn's header → its divider.
    static let rowGap: CGFloat = 8
    /// A label → what it labels: Thinking → dots, a name → its message.
    static let labelGap: CGFloat = 6
    static let tight: CGFloat = 4
    static let hair: CGFloat = 2

    /// The transcript's top inset: the first message clears the workspace's
    /// floating header buttons (a 32-point button inset 12) by an entry gap.
    static let topInset: CGFloat = 56
    /// The transcript's side inset.
    static let sideInset: CGFloat = 32
    /// The transcript column.
    static let column: CGFloat = 768
    /// The widest anything in an assistant turn gets.
    static let measure: CGFloat = 680
    /// Work rows: icon column, then the gap to their text.
    static let iconColumn: CGFloat = 17
    static let iconGap: CGFloat = 9
    static let textInset = iconColumn + iconGap
    /// Code boxes, tables, visual-reply frames.
    static let blockRadius: CGFloat = 12
    /// Side inset inside code boxes, user bubbles and the changed-files card.
    static let blockInset: CGFloat = 14
    /// Inside a user message's bubble.
    static let bubbleInsets = EdgeInsets(top: 10, leading: blockInset, bottom: 10, trailing: blockInset)
    /// The row under a reply that holds Copy, or the dots while it runs.
    static let actionRowHeight: CGFloat = 24

    /// Reply typography, as visible gaps between text boxes and box edges.
    enum Prose {
        static let lineSpacing: CGFloat = 5
        static let paragraphGap: CGFloat = 14
        /// A paragraph → a list; items of a list whose items hold several blocks.
        static let looseListGap: CGFloat = 10
        /// Items of a list whose items are single paragraphs.
        static let tightListGap: CGFloat = 6
        static let majorHeadingGap: CGFloat = 24
        static let minorHeadingGap: CGFloat = 20
        /// A heading → what follows it.
        static let majorHeadingAttach: CGFloat = 8
        static let minorHeadingAttach: CGFloat = 6
        static let ruleGap: CGFloat = 16
        static let codeLineSpacing: CGFloat = 3
        static let codePadding: CGFloat = 12
        /// Code language label → the first code line.
        static let codeLabelGap: CGFloat = 6
        /// List markers end here, right-aligned; item text starts a gap later.
        static let markerColumn: CGFloat = 22
        static let markerGap: CGFloat = 8
        /// A nested list's markers end this far right of its parent's text.
        static let nestedListStep: CGFloat = 22
        static let quoteBar: CGFloat = 2
        static let quoteGap: CGFloat = 12
        static let cellLineSpacing: CGFloat = 3
        static let cellPaddingVertical: CGFloat = 8
        static let cellPaddingHorizontal: CGFloat = 10
        /// The least a table column takes, however long its longest word.
        static let tableColumnMinimumLimit: CGFloat = 200
        /// Inline code up to this many characters keeps together in a table cell.
        static let unbreakableCodeLength = 28
    }
}

/// A quiet text action inside the transcript, sized for caption text rather
/// than as a filled control.
struct ConversationTextButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, ConversationMetrics.labelGap)
                .frame(height: ConversationMetrics.actionRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(WovenIconButtonStyle())
    }
}

extension View {
    /// The bottom edge of a transcript under its composer stack, the same in
    /// agent chats, bot chats and the Forum. Rows fade out before the stack,
    /// so none shows beside or through it. While the reader is away from the
    /// end (`jumpLabel` set), a round button to the end sits centred just above
    /// the stack, and the clear band reaches up behind it, so it never covers
    /// legible text.
    func conversationBottomEdge(stackHeight: CGFloat, jumpLabel: String?, jump: @escaping () -> Void) -> some View {
        modifier(ConversationBottomEdge(stackHeight: stackHeight, jumpLabel: jumpLabel, jump: jump))
    }
}

private struct ConversationBottomEdge: ViewModifier {
    static let jumpSize: CGFloat = 30
    let stackHeight: CGFloat
    let jumpLabel: String?
    let jump: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.wovenTheme) private var theme

    func body(content: Content) -> some View {
        let stackTop = stackHeight + ConversationBottomOverlayLayout.bottomOffset
        let jumpBand = jumpLabel == nil ? 0 : ConversationMetrics.rowGap + Self.jumpSize
        content
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: reduceTransparency ? 0 : ConversationBottomOverlayLayout.breathingRoom)
                    Color.clear.frame(height: stackTop + jumpBand)
                }
            }
            .overlay(alignment: .bottom) {
                if let jumpLabel {
                    Button(action: jump) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(WovenPalette.foreground)
                            .frame(width: Self.jumpSize, height: Self.jumpSize)
                            .background(theme.palette.workspace, in: Circle())
                            .overlay { Circle().strokeBorder(WovenPalette.foreground.opacity(0.1), lineWidth: 1) }
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(jumpLabel)
                    .accessibilityLabel(jumpLabel)
                    .padding(.bottom, stackTop + ConversationMetrics.rowGap)
                }
            }
    }
}
