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
        /// Under a top-level list item of one line, and between the blocks of
        /// a top-level item.
        static let listGap: CGFloat = 8
        /// Under a top-level list item that wraps at the laid-out width.
        static let wrappedListGap: CGFloat = 10
        /// Under a nested item of one line (from a parent's text of one line
        /// to its first nested item too), and between a nested item's blocks.
        static let nestedListGap: CGFloat = 6
        /// Under a nested item, or a parent's text, that wraps.
        static let wrappedNestedListGap: CGFloat = 8
        /// How far a citation line after a nested list is raised into the gap
        /// above it, so it sits closer to what it cites than to the next item.
        static let citationRaise: CGFloat = 3
        /// A paragraph → the list after it.
        static let paragraphToListGap: CGFloat = 10
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
        /// The room under each table row for its rule, drawn one device pixel tall.
        static let tableRule: CGFloat = 0.5
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
        /// A narrow table that breaks code tries keeping this many of its
        /// shortest broken spans whole, so its search stays a few layouts.
        static let tableSpansTriedWhole = 4
        /// The points a narrow table tries moving between its two widest
        /// prose columns, each way, to save a line.
        static let tableColumnShifts: [CGFloat] = [24, 40]
        /// Inline code in prose up to this many characters moves to the next
        /// line whole rather than break, when it takes at most
        /// `proseCodeLineShare` of that line.
        static let proseCodeOnOneLine = 32
        static let proseCodeLineShare: CGFloat = 2.0 / 3
        /// A link whose text is up to this many characters moves to the next
        /// line whole, like short inline code.
        static let shortLinkLength = 32
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
    /// Forum. It uses the panel's whole height: rows scroll up to the top edge,
    /// fading out over its last `labelGap`, and down behind the glass composer
    /// stack, which shows them through it. While the reader is away from the end
    /// (`jumpLabel` set), a round button to the end sits centred just above the
    /// stack. Under Reduce Transparency the top edge is hard.
    func conversationEdges(stackHeight: CGFloat, jumpLabel: String?, jump: @escaping () -> Void) -> some View {
        modifier(ConversationEdges(stackHeight: stackHeight, jumpLabel: jumpLabel, jump: jump))
    }

    /// Debug builds: records where something opaque drawn over a transcript is
    /// (a notice, the jump button), so a debug still draws it again over web
    /// pictures.
    func conversationCoverSnapshot(radius: CGFloat = 0) -> some View {
        modifier(CoverSnapshotRecorder(coverRadius: radius))
    }

    /// Debug builds: records where a glass surface over a transcript is (the
    /// composer) and its corner radius, so a
    /// debug still draws it as glass: window captures draw the material clear.
    func conversationGlassSnapshot(radius: CGFloat) -> some View {
        modifier(CoverSnapshotRecorder(glassRadius: radius))
    }
}

/// Where a transcript's end is, the same rule on every surface.
enum ConversationEnd {
    /// The reader is at the live edge, and the transcript follows, only within this of the end.
    static let liveEdge: CGFloat = 2

    /// The newest content is obscured once the end is more than the
    /// clearance's breathing room below what shows: the last row then reaches
    /// behind the composer stack.
    static func isObscured(distance: CGFloat) -> Bool { distance > CGFloat(ConversationBottomOverlayLayout.breathingRoom) }

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
/// Where each shown transcript's top fade is, in window coordinates from the
/// top, and what is drawn over transcripts, for debug snapshots: they draw web
/// content in after the window, past SwiftUI's mask and over everything, so
/// each piece is faded like the transcript it is in and then covered again.
struct ConversationEdgeSnapshot: Equatable {
    @MainActor static var shown: [UUID: ConversationEdgeSnapshot] = [:]
    @MainActor static var covers: [UUID: ConversationGlassSurface] = [:]
    @MainActor static var glass: [UUID: ConversationGlassSurface] = [:]

    /// The transcript a piece of web content at `rect` sits in.
    @MainActor static func containing(_ rect: CGRect) -> ConversationEdgeSnapshot? {
        shown.values.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }
    }

    let frame: CGRect
    let topFade: CGFloat
}
#endif

/// Debug builds: records a transcript's edges for debug snapshots. Release
/// builds record nothing.
private struct EdgeSnapshotRecorder: ViewModifier {
    let id: UUID?
    let topFade: CGFloat

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .onGeometryChange(for: ConversationEdgeSnapshot.self) { geometry in
                ConversationEdgeSnapshot(frame: geometry.frame(in: .global), topFade: topFade)
            } action: { snapshot in if let id { ConversationEdgeSnapshot.shown[id] = snapshot } }
            .onDisappear { if let id { ConversationEdgeSnapshot.shown[id] = nil } }
        #else
        content
        #endif
    }
}

private struct CoverSnapshotRecorder: ViewModifier {
    /// An opaque cover's corner radius.
    var coverRadius: CGFloat = 0
    /// Set for a glass surface: its corner radius.
    var glassRadius: CGFloat?
    #if DEBUG
    @State private var id = UUID()
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                if let glassRadius { ConversationEdgeSnapshot.glass[id] = ConversationGlassSurface(frame: frame, radius: glassRadius) }
                else { ConversationEdgeSnapshot.covers[id] = ConversationGlassSurface(frame: frame, radius: coverRadius) }
            }
            .onDisappear {
                if glassRadius != nil { ConversationEdgeSnapshot.glass[id] = nil } else { ConversationEdgeSnapshot.covers[id] = nil }
            }
        #else
        content
        #endif
    }
}

#if DEBUG
/// A glass surface or an opaque cover in window coordinates from the top, and
/// its corner radius.
struct ConversationGlassSurface {
    let frame: CGRect
    let radius: CGFloat
}
#endif

private struct ConversationEdges: ViewModifier {
    static let jumpSize: CGFloat = 30
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
        let topFade = reduceTransparency ? 0 : ConversationMetrics.labelGap
        content
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: topFade)
                    Color.black
                }
            }
            .modifier(EdgeSnapshotRecorder(id: debugSnapshotID, topFade: topFade))
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
                    .conversationCoverSnapshot(radius: .greatestFiniteMagnitude)
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
