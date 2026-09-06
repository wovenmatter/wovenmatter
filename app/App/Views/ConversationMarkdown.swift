import AppKit
import SwiftUI

struct ConversationMarkdown: View {
    let document: ConversationMarkdownDocument
    let isStreaming: Bool
    @State private var pendingExternalURL: URL?

    var body: some View {
        ConversationMarkdownBlocks(blocks: document.blocks, isStreaming: isStreaming)
            .environment(\.openURL, OpenURLAction { url in
                guard ConversationMarkdownDocument.isSafeExternalLink(url) else {
                    return .discarded
                }
                pendingExternalURL = url
                return .handled
            })
            .alert(
                "Open external link?",
                isPresented: Binding(
                    get: { pendingExternalURL != nil },
                    set: { if !$0 { pendingExternalURL = nil } }
                ),
                presenting: pendingExternalURL
            ) { url in
                Button("Cancel", role: .cancel) { pendingExternalURL = nil }
                Button("Open") {
                    pendingExternalURL = nil
                    NSWorkspace.shared.open(url)
                }
            } message: { url in
                Text(url.absoluteString)
            }
    }
}

private struct ConversationMarkdownBlocks: View {
    let blocks: [ConversationMarkdownDocument.Block]
    let isStreaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index])
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(isStreaming
            ? DashboardPalette.foreground.opacity(0.76)
            : DashboardPalette.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ block: ConversationMarkdownDocument.Block) -> some View {
        switch block {
        case .paragraph(let content):
            ConversationMarkdownInline(content: content)
                .frame(maxWidth: 680, alignment: .leading)
        case .heading(let level, let content):
            ConversationMarkdownInline(content: content)
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 1)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: 680, alignment: .leading)
        case .list(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .top, spacing: 9) {
                        listMarker(item)
                            .frame(width: 22, alignment: .trailing)
                        ConversationMarkdownBlocks(blocks: item.blocks, isStreaming: isStreaming)
                    }
                    .padding(.leading, CGFloat(min(item.depth, 6)) * 17)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(DashboardPalette.foreground.opacity(0.16))
                    .frame(width: 2)
                ConversationMarkdownBlocks(blocks: blocks, isStreaming: isStreaming)
            }
            .frame(maxWidth: 680, alignment: .leading)
        case .code(let language, let content):
            ConversationCodeBlock(language: language, content: content)
        case .table(let table):
            ConversationMarkdownTable(table: table)
        case .divider:
            Divider().overlay(DashboardPalette.foreground.opacity(0.12))
        }
    }

    @ViewBuilder
    private func listMarker(_ item: ConversationMarkdownDocument.ListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(checked ? DashboardPalette.primary : DashboardPalette.mutedForeground)
        } else {
            Text(item.marker)
                .font(.system(size: 14))
                .foregroundStyle(DashboardPalette.mutedForeground)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 22
        case 2: 19
        case 3: 17
        default: 15.5
        }
    }
}

private struct ConversationMarkdownInline: View {
    let content: ConversationMarkdownDocument.InlineText

    var body: some View {
        Text(styled)
            .lineSpacing(5)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
    }

    private var styled: AttributedString {
        var value = content.rendered
        for run in value.runs {
            guard run.inlinePresentationIntent?.contains(.code) == true else { continue }
            value[run.range].font = .system(size: 13.5, design: .monospaced)
            value[run.range].foregroundColor = DashboardPalette.foreground.opacity(0.92)
            value[run.range].backgroundColor = DashboardPalette.primary.opacity(0.075)
        }
        return value
    }
}

private struct ConversationCodeBlock: View {
    let language: String?
    let content: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "Code")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.horizontal, 13)
            .frame(height: 34)

            ScrollView(.horizontal) {
                Text(content)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(14)
            }
            .scrollIndicators(.never)
            .background(DashboardPalette.background.opacity(0.64))
        }
        .background(DashboardPalette.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DashboardPalette.foreground.opacity(0.08), lineWidth: 1)
        }
        .onChange(of: content) { copied = false }
    }
}

private struct ConversationMarkdownTable: View {
    let table: ConversationMarkdownDocument.Table
    @State private var copied = false
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            tableScroll
            HStack(spacing: 12) {
                Spacer()
                Button {
                    copyTable()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    expanded = true
                } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .background(DashboardPalette.primary.opacity(0.032))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(DashboardPalette.foreground.opacity(0.09), lineWidth: 1)
        }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 0) {
                HStack {
                    Text("Table").font(.headline)
                    Spacer()
                    Button("Done") { expanded = false }.keyboardShortcut(.cancelAction)
                }
                .padding(16)
                Divider()
                tableScroll.padding(18)
            }
            .frame(minWidth: 760, idealWidth: 1050, minHeight: 440, idealHeight: 680)
        }
    }

    private var tableScroll: some View {
        let widths = columnWidths
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.header, header: true, widths: widths)
                ForEach(table.rows.indices, id: \.self) { index in
                    row(table.rows[index], header: false, widths: widths)
                }
            }
            .padding(.horizontal, 3)
        }
        .scrollIndicators(.never)
    }

    private func row(
        _ cells: [ConversationMarkdownDocument.InlineText],
        header: Bool,
        widths: [CGFloat]
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(table.header.indices, id: \.self) { index in
                ConversationMarkdownInline(content: cell(cells, index))
                    .font(.system(size: 13, weight: header ? .semibold : .regular))
                    .frame(width: widths[index], alignment: alignment(index))
                    .padding(.horizontal, 11)
                    .padding(.vertical, header ? 10 : 9)
            }
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(header ? 0.75 : 0.35)
        }
    }

    private var columnWidths: [CGFloat] {
        table.header.indices.map { index in
            let contents = [table.header[index].plainText] + table.rows.map { cell($0, index).plainText }
            let longest = contents.map(\.count).max() ?? 8
            return min(300, max(110, CGFloat(longest) * 7.2 + 24))
        }
    }

    private func alignment(_ index: Int) -> Alignment {
        guard table.alignments.indices.contains(index) else { return .leading }
        return switch table.alignments[index] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func cell(
        _ cells: [ConversationMarkdownDocument.InlineText],
        _ index: Int
    ) -> ConversationMarkdownDocument.InlineText {
        cells.indices.contains(index) ? cells[index] : .init("")
    }

    private func copyTable() {
        let rows = [table.header] + table.rows
        let text = rows.map { row in row.map(\.plainText).joined(separator: "\t") }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}
