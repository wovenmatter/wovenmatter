import SwiftUI
import WovenProtocol

/// One line of a Folders list: an icon, a title with an optional line under
/// it, and what sits at the trailing edge.
struct FolderRowLabel<Icon: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var emphasized = false
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var trailing: () -> Trailing
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 26

    var body: some View {
        HStack(spacing: 12) {
            icon().frame(width: iconColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(emphasized ? .semibold : .regular)).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(WovenPalette.mutedForeground).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .foregroundStyle(WovenPalette.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension FolderRowLabel where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder icon: @escaping () -> Icon) {
        self.init(title: title, subtitle: subtitle, icon: icon) { EmptyView() }
    }
}

/// A Lucide glyph sized for a row's icon column.
struct FolderGlyph: View {
    let glyph: LucideGlyph
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View { LucideIcon(glyph: glyph, size: size) }
}

/// A row's press state: a restrained fill, as rail rows have.
struct FolderRowButtonStyle: ButtonStyle {
    @Environment(\.wovenTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? theme.palette.themeSoft : .clear,
                        in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
            .hoverEffect(.highlight)
    }
}

/// A heading that folds what is under it away; `level` 1 is a workspace,
/// 2 its Agents or Folders.
struct FolderHeading: View {
    let title: String
    var detail: String? = nil
    var level = 1
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(title)
                    .font(level == 1 ? .subheadline.weight(.semibold) : .footnote.weight(.semibold))
                    .lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
                }
                Spacer(minLength: 0)
                LucideIcon(glyph: .chevronDown, size: 12)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isHeader)
    }
}

/// A chat as lists show it: its agent's logo, title, a line under it, and
/// whether it is running, waiting, unread or pinned, with its time.
struct FolderChatRow: View {
    let conversation: WorkspaceConversationRecord
    let subtitle: String?
    let action: () -> Void
    @Environment(\.wovenTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var logo: CGFloat = 22

    var body: some View {
        Button(action: action) {
            FolderRowLabel(title: conversation.title, subtitle: subtitle, emphasized: conversation.unread) {
                AgentIcon(runtime: conversation.runtimeKind, size: logo)
            } trailing: {
                HStack(spacing: 6) {
                    if conversation.isPinned { LucideIcon(glyph: .pin, size: 12).foregroundStyle(WovenPalette.mutedForeground) }
                    switch conversation.activity {
                    case .working: ConversationRunningDots()
                    case .blocked: LucideIcon(glyph: .alertCircle, size: 13).foregroundStyle(theme.palette.themeAccent)
                    default: EmptyView()
                    }
                    if conversation.unread { Circle().fill(theme.palette.themeAccent).frame(width: 8, height: 8) }
                    Text(folderRowTime(conversation.lastMessageAt))
                        .font(.caption).monospacedDigit().foregroundStyle(WovenPalette.mutedForeground)
                }
            }
        }
        .buttonStyle(FolderRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("folders-chat-\(conversation.id)")
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if conversation.activity == .working { parts.append("Running") }
        if conversation.activity == .blocked { parts.append("Waiting for you") }
        if conversation.unread { parts.append("Unread") }
        if conversation.isPinned { parts.append("Pinned") }
        return parts.joined(separator: ", ")
    }
}

/// An artifact as lists show it: its kind, title, a line under it, and its time.
struct FolderArtifactRow: View {
    let note: WorkspaceNoteRecord
    let subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FolderRowLabel(title: note.title.isEmpty ? note.kind.untitledName : note.title,
                           subtitle: subtitle) {
                ArtifactKindIcon(kind: note.kind)
            } trailing: {
                HStack(spacing: 6) {
                    if note.isPinned { LucideIcon(glyph: .pin, size: 12).foregroundStyle(WovenPalette.mutedForeground) }
                    Text(folderRowTime(note.updatedAt ?? note.createdAt))
                        .font(.caption).monospacedDigit().foregroundStyle(WovenPalette.mutedForeground)
                }
            }
        }
        .buttonStyle(FolderRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(note.isPinned ? "\(note.kind.displayName), pinned" : note.kind.displayName)
        .accessibilityIdentifier("folders-artifact-\(note.id)")
    }
}

/// A quiet line in a list: an empty section, or what a Mac adds.
struct FolderCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

extension View {
    /// A Folders list row: the page's own colour, no separators, the rows'
    /// own padding. `indent` sets a workspace's contents in under its heading.
    func folderRow(indent: CGFloat = 0) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 8 + indent, bottom: 0, trailing: 8))
    }

    /// A Folders list: plain, on the page colour, at a readable width on iPad.
    func folderList() -> some View {
        listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 44)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
    }
}
