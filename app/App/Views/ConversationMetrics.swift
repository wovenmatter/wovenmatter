import SwiftUI

/// The chat transcript's one spacing scale. Every gap, inset and width in a
/// conversation comes from here, in agent chats, bot chats and the Forum alike;
/// font sizes stay with their views.
enum ConversationMetrics {
    /// Between turns, in both directions: a message → the reply, the reply's
    /// actions → the next message.
    static let turnGap: CGFloat = 24
    /// Expanded work → the reply under it.
    static let workEndGap: CGFloat = 24
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

    /// Where the workspace's floating header buttons end, from its top.
    static let floatingControls = WovenMetrics.floatingControlInset + WovenMetrics.floatingControlSize
    /// The transcript's top inset: the first message clears the floating
    /// buttons by an entry gap, the band its top edge fades over.
    static let topInset = floatingControls + entryGap
    /// The transcript's side inset.
    static let sideInset: CGFloat = 32
    /// The transcript column: user bubbles, everything in an assistant turn
    /// and the composer share its edges. Settings pages use the same width.
    static let column = SettingsMetrics.pageWidth
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
    /// The least space left of a user's message; in a column narrower than
    /// `narrowColumn`, the smaller lead.
    static let bubbleLead: CGFloat = 72
    static let narrowBubbleLead: CGFloat = 48
    static let narrowColumn: CGFloat = 520

    /// Reply typography, as visible gaps between text boxes and box edges.
    enum Prose {
        static let lineSpacing: CGFloat = 5
        static let paragraphGap: CGFloat = 14
        /// Between list items at every level, whether they wrap or not; a
        /// paragraph → a list; between the blocks of one item.
        static let listGap: CGFloat = 8
        static let majorHeadingGap: CGFloat = 24
        static let minorHeadingGap: CGFloat = 20
        /// A heading → what follows it.
        static let majorHeadingAttach: CGFloat = 8
        static let minorHeadingAttach: CGFloat = 6
        static let ruleGap: CGFloat = 16
        static let codeLineSpacing: CGFloat = 3
        static let codePadding: CGFloat = 12
        /// A code line that wraps continues this many monospace cells right
        /// of its own leading whitespace.
        static let codeContinuationCells: CGFloat = 2
        /// Code language label → the first code line.
        static let codeLabelGap: CGFloat = 6
        /// List markers end here, right-aligned; item text starts a gap later.
        static let markerColumn: CGFloat = 22
        static let markerGap: CGFloat = 8
        /// A nested list's markers end this far right of its parent's text.
        static let nestedListStep: CGFloat = 22
        static let quoteBar: CGFloat = 3
        static let quoteGap: CGFloat = 11
        static let cellLineSpacing: CGFloat = 3
        static let cellPaddingVertical: CGFloat = 8
        static let cellPaddingHorizontal: CGFloat = 10
        /// Text narrower than this gives its tables' cells the narrow padding.
        static let narrowTableWidth: CGFloat = 480
        static let narrowCellPaddingVertical: CGFloat = 6
        static let narrowCellPaddingHorizontal: CGFloat = 7
        /// Inline code: in prose (15pt), and in a table cell (13pt).
        static let inlineCodeSize: CGFloat = 13.5
        static let cellCodeSize: CGFloat = 12
        /// The least a table column takes, however long its longest word.
        static let tableColumnMinimumLimit: CGFloat = 200
        /// A table cell this short is kept on one line when its column can be.
        static let shortCellLength = 16
        /// A table at least this share of the text's width fills it.
        static let tableFillShare: CGFloat = 0.75
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
    /// The edges of a transcript, the same in agent chats, bot chats and the
    /// Forum. At the top, rows fade out before `topClearance` (what floats
    /// over the transcript there), so none passes legibly behind it. At the
    /// bottom, rows fade out before the composer stack, so none shows beside
    /// or through it. While the reader is away from the end (`jumpLabel` set),
    /// a round button to the end sits centred just above the stack, and the
    /// clear band reaches up behind it, so it never covers legible text.
    /// Under Reduce Transparency both edges are hard.
    func conversationEdges(topClearance: CGFloat, stackHeight: CGFloat, jumpLabel: String?,
                           jump: @escaping () -> Void) -> some View {
        modifier(ConversationEdges(topClearance: topClearance, stackHeight: stackHeight, jumpLabel: jumpLabel, jump: jump))
    }
}

/// Where a transcript's end is, the same rule on every surface.
enum ConversationEnd {
    /// The reader is at the live edge, and the transcript follows, only within this of the end.
    static let liveEdge: CGFloat = 2

    /// The newest content is obscured once the end is more than a turn gap
    /// below what shows: rows end that far above the clearance under them,
    /// whose top is where the composer's fade begins.
    static func isObscured(distance: CGFloat) -> Bool { distance > ConversationMetrics.turnGap }

    static func distance(_ geometry: ScrollGeometry) -> CGFloat {
        max(0, geometry.contentSize.height - geometry.visibleRect.maxY).rounded()
    }
}

extension ConversationGeometry {
    init(_ geometry: ScrollGeometry) {
        self.init(contentHeight: geometry.contentSize.height, viewportHeight: geometry.containerSize.height,
                  endDistance: ConversationEnd.distance(geometry))
    }

    var isAtLiveEdge: Bool { endDistance <= ConversationEnd.liveEdge }
    var isObscured: Bool { ConversationEnd.isObscured(distance: endDistance) }
}

#if DEBUG
/// Where each shown transcript's edges fade, in window coordinates from the
/// top, for debug snapshots: they draw web content in after the window, past
/// SwiftUI's mask, and fade each piece with the edges of the transcript it is in.
struct ConversationEdgeSnapshot: Equatable {
    @MainActor static var shown: [UUID: ConversationEdgeSnapshot] = [:]

    /// The transcript a piece of web content at `rect` sits in.
    @MainActor static func containing(_ rect: CGRect) -> ConversationEdgeSnapshot? {
        shown.values.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }

    let frame: CGRect
    let topClearance: CGFloat
    let topFade: CGFloat
    let bottomFade: CGFloat
    let bottomClearance: CGFloat
}
#endif

/// Debug builds: records a transcript's edges for debug snapshots. Release
/// builds record nothing.
private struct EdgeSnapshotRecorder: ViewModifier {
    let id: UUID?
    let topClearance: CGFloat
    let topFade: CGFloat
    let bottomFade: CGFloat
    let bottomClearance: CGFloat

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .onGeometryChange(for: ConversationEdgeSnapshot.self) { geometry in
                ConversationEdgeSnapshot(frame: geometry.frame(in: .global), topClearance: topClearance, topFade: topFade,
                                         bottomFade: bottomFade, bottomClearance: bottomClearance)
            } action: { snapshot in if let id { ConversationEdgeSnapshot.shown[id] = snapshot } }
            .onDisappear { if let id { ConversationEdgeSnapshot.shown[id] = nil } }
        #else
        content
        #endif
    }
}

private struct ConversationEdges: ViewModifier {
    static let jumpSize: CGFloat = 30
    let topClearance: CGFloat
    let stackHeight: CGFloat
    let jumpLabel: String?
    let jump: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.wovenTheme) private var theme
    #if DEBUG
    @State private var snapshotID = UUID()
    #endif

    private var debugSnapshotID: UUID? {
        #if DEBUG
        snapshotID
        #else
        nil
        #endif
    }

    func body(content: Content) -> some View {
        let stackTop = stackHeight + ConversationBottomOverlayLayout.bottomOffset
        let jumpBand = jumpLabel == nil ? 0 : ConversationMetrics.rowGap + Self.jumpSize
        let topFade = reduceTransparency ? 0 : ConversationMetrics.entryGap
        let bottomFade = reduceTransparency ? 0 : ConversationBottomOverlayLayout.breathingRoom
        content
            .mask {
                VStack(spacing: 0) {
                    Color.clear.frame(height: topClearance)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: topFade)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: bottomFade)
                    Color.clear.frame(height: stackTop + jumpBand)
                }
            }
            .modifier(EdgeSnapshotRecorder(id: debugSnapshotID, topClearance: topClearance, topFade: topFade,
                                           bottomFade: bottomFade, bottomClearance: stackTop + jumpBand))
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

/// A message row: a user's message hugs the right edge, keeping at least
/// `ConversationMetrics.bubbleLead` of space on its left (less in a narrow
/// column, so short lines do not wrap); anything else starts at the left.
struct ConversationMessageRowLayout: Layout {
    var trailing = true

    static func lead(for width: CGFloat) -> CGFloat {
        width < ConversationMetrics.narrowColumn ? ConversationMetrics.narrowBubbleLead : ConversationMetrics.bubbleLead
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width ?? child.sizeThatFits(.unspecified).width
        let room = trailing ? max(0, width - Self.lead(for: width)) : width
        let size = child.sizeThatFits(ProposedViewSize(width: room, height: nil))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let room = trailing ? max(0, bounds.width - Self.lead(for: bounds.width)) : bounds.width
        let size = child.sizeThatFits(ProposedViewSize(width: room, height: nil))
        let x = trailing ? bounds.maxX - min(size.width, room) : bounds.minX
        child.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: min(size.width, room), height: size.height))
    }
}
