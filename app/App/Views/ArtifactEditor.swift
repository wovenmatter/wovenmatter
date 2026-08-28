import SwiftUI
import WebKit
import WovenMatterCore

struct DashboardSpreadsheetEditor: View {
    @Binding var document: NoteDocument

    private var tableIndex: Int? {
        document.blocks.firstIndex {
            if case .table = $0 { true } else { false }
        }
    }

    private var table: NoteTableBlock {
        guard let tableIndex, case .table(let table) = document.blocks[tableIndex] else {
            return NoteTableBlock(rows: 20, columns: 8, headerRow: true)
        }
        return table
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Button { addRow() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Add Row")
                    .help("Add row")
                    Button { removeRow() } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Remove Row")
                    .help("Remove last row")
                    .disabled(table.rows.count <= 1)
                    Text("Rows")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Button { addColumn() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Add Column")
                    .help("Add column")
                    Button { removeColumn() } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Remove Column")
                    .help("Remove last column")
                    .disabled(table.columns.count <= 1)
                    Text("Columns")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(table.rows.count) rows × \(table.columns.count) columns")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .frame(height: 38)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        spreadsheetCorner
                        ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, _ in
                            Text(spreadsheetColumnName(index))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 140, height: 28)
                                .background(Color.secondary.opacity(0.06))
                                .overlay { Rectangle().stroke(Color.secondary.opacity(0.16), lineWidth: 0.5) }
                        }
                    }
                    ForEach(Array(table.rows.enumerated()), id: \.element.id) { rowIndex, row in
                        GridRow {
                            Text("\(rowIndex + 1)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, height: 30)
                                .background(Color.secondary.opacity(0.06))
                                .overlay { Rectangle().stroke(Color.secondary.opacity(0.16), lineWidth: 0.5) }
                            ForEach(Array(row.cells.enumerated()), id: \.element.id) { columnIndex, _ in
                                TextField("", text: cellBinding(row: rowIndex, column: columnIndex))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 7)
                                    .frame(width: 140, height: 30)
                                    .background(rowIndex < table.headerRowCount
                                        ? Color.accentColor.opacity(0.055)
                                        : Color.clear)
                                    .overlay { Rectangle().stroke(Color.secondary.opacity(0.16), lineWidth: 0.5) }
                            }
                        }
                    }
                }
                .padding(1)
            }
        }
        .onAppear { ensureTable() }
    }

    private var spreadsheetCorner: some View {
        Color.secondary.opacity(0.08)
            .frame(width: 42, height: 28)
            .overlay { Rectangle().stroke(Color.secondary.opacity(0.16), lineWidth: 0.5) }
    }

    private func cellBinding(row: Int, column: Int) -> Binding<String> {
        Binding(
            get: {
                guard table.rows.indices.contains(row),
                      table.rows[row].cells.indices.contains(column) else { return "" }
                return table.rows[row].cells[column].plainText
            },
            set: { value in
                mutateTable { table in
                    guard table.rows.indices.contains(row),
                          table.rows[row].cells.indices.contains(column) else { return }
                    table.rows[row].cells[column].runs = value.isEmpty
                        ? [] : [NoteTextRun(text: value)]
                }
            }
        )
    }

    private func ensureTable() {
        guard tableIndex == nil else { return }
        document.blocks = [.table(NoteTableBlock(rows: 20, columns: 8, headerRow: true))]
    }

    private func addRow() {
        mutateTable { $0.rows.append(NoteTableRow(cellCount: $0.columns.count)) }
    }

    private func removeRow() {
        mutateTable { table in
            guard table.rows.count > 1 else { return }
            table.rows.removeLast()
            table.headerRowCount = min(table.headerRowCount, table.rows.count)
        }
    }

    private func addColumn() {
        mutateTable { table in
            table.columns.append(NoteTableColumn())
            for index in table.rows.indices { table.rows[index].cells.append(NoteTableCell()) }
        }
    }

    private func removeColumn() {
        mutateTable { table in
            guard table.columns.count > 1 else { return }
            table.columns.removeLast()
            for index in table.rows.indices where !table.rows[index].cells.isEmpty {
                table.rows[index].cells.removeLast()
            }
        }
    }

    private func mutateTable(_ mutation: (inout NoteTableBlock) -> Void) {
        ensureTable()
        guard let index = document.blocks.firstIndex(where: {
            if case .table = $0 { true } else { false }
        }), case .table(var table) = document.blocks[index] else { return }
        mutation(&table)
        document.blocks[index] = .table(table.normalized())
    }

    private func spreadsheetColumnName(_ index: Int) -> String {
        var value = index
        var result = ""
        repeat {
            result.insert(Character(UnicodeScalar(65 + (value % 26))!), at: result.startIndex)
            value = value / 26 - 1
        } while value >= 0
        return result
    }
}

struct DashboardHTMLArtifactView: NSViewRepresentable {
    let html: String
    let linkedDataJSON: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let rendered = Self.renderedHTML(html: html, linkedDataJSON: linkedDataJSON)
        guard context.coordinator.renderedHTML != rendered else { return }
        context.coordinator.renderedHTML = rendered
        webView.loadHTMLString(rendered, baseURL: nil)
    }

    static func renderedHTML(html: String, linkedDataJSON: String?) -> String {
        let body = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? """
              <main class="woven-empty">
                <h2>HTML artifact</h2>
                <p>Ask your agent to build a visualization here.</p>
              </main>
              """
            : html
        let data = (linkedDataJSON ?? "null")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            html, body { min-height: 100%; margin: 0; }
            body { padding: 24px; box-sizing: border-box; }
            .woven-empty { min-height: calc(100vh - 48px); display: grid; place-content: center; text-align: center; color: #64706b; }
            .woven-empty h2 { margin: 0 0 6px; color: #15382d; font-size: 18px; }
            .woven-empty p { margin: 0; font-size: 13px; }
          </style>
          <script>window.wovenMatterData = \(data);</script>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var renderedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .other,
                  navigationAction.request.url?.scheme == "about" else {
                return .cancel
            }
            return .allow
        }
    }
}

struct DashboardDatabaseLinkControl: View {
    @Environment(\.dashboardTheme) private var theme
    @Binding var document: NoteDocument
    let snapshot: DashboardDatabasesSnapshot
    @State private var showsPopover = false

    private var links: [DatabaseArtifactLink] {
        var result = document.databaseLink.map { [$0] } ?? []
        for block in document.blocks {
            if case .table(let table) = block, let link = table.databaseLink {
                result.append(link)
            }
        }
        return result
    }

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            DashboardLucideIcon(glyph: .database, size: 14)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(DashboardIconButtonStyle())
        .help(links.isEmpty ? "Link to database" : "Edit database link")
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            DashboardDatabaseLinkPopover(
                document: $document,
                snapshot: snapshot,
                onClose: { showsPopover = false }
            )
            .environment(\.dashboardTheme, theme)
        }
    }
}

private struct DashboardDatabaseLinkPopover: View {
    @Binding var document: NoteDocument
    let snapshot: DashboardDatabasesSnapshot
    let onClose: () -> Void
    @State private var sourceID = ""
    @State private var databaseID = ""
    @State private var relativePath = ""
    @State private var sqliteQuery = ""

    private var sources: [DashboardDatabaseSource] {
        snapshot.sources.filter { !$0.databases.isEmpty }
    }

    private var databases: [DashboardAgentDatabase] {
        sources.first { $0.id == sourceID }?.databases ?? []
    }

    private var canSave: Bool {
        !sourceID.isEmpty && !databaseID.isEmpty
            && !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Database Link").font(.system(size: 14, weight: .semibold))
            Picker("Workspace", selection: $sourceID) {
                ForEach(sources) { Text($0.name).tag($0.id) }
            }
            Picker("Database", selection: $databaseID) {
                ForEach(databases) { Text($0.name).tag($0.databaseID) }
            }
            TextField("Relative data path, for example data.json", text: $relativePath)
                .textFieldStyle(.roundedBorder)
            if usesSQLite {
                TextField("Read-only SQL query", text: $sqliteQuery, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }
            HStack {
                Button("Remove Link", role: .destructive) { removeLink() }
                    .disabled(existingLink() == nil)
                Spacer()
                Button("Cancel", action: onClose)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { loadInitialValues() }
        .onChange(of: sourceID) { _, _ in
            if !databases.contains(where: { $0.databaseID == databaseID }) {
                databaseID = databases.first?.databaseID ?? ""
            }
        }
    }

    private var usesSQLite: Bool {
        let fileExtension = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        if ["db", "sqlite", "sqlite3"].contains(fileExtension) { return true }
        if fileExtension == "json" { return false }
        return databases.first(where: { $0.databaseID == databaseID })?.preference == .sqlite
    }

    private func loadInitialValues() {
        loadSelectedTargetLink()
    }

    private func loadSelectedTargetLink() {
        if let link = existingLink() {
            sourceID = link.sourceID
            databaseID = link.databaseID
            relativePath = link.relativePath
            sqliteQuery = link.sqliteQuery ?? ""
        } else {
            sourceID = sources.first?.id ?? ""
            databaseID = databases.first?.databaseID ?? ""
            relativePath = ""
            sqliteQuery = ""
        }
    }

    private func existingLink() -> DatabaseArtifactLink? {
        document.databaseLink
    }

    private func save() {
        let link = DatabaseArtifactLink(
            sourceID: sourceID,
            databaseID: databaseID,
            relativePath: relativePath.trimmingCharacters(in: .whitespacesAndNewlines),
            sqliteQuery: sqliteQuery.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        apply(link)
        onClose()
    }

    private func removeLink() {
        apply(nil)
        onClose()
    }

    private func apply(_ link: DatabaseArtifactLink?) {
        document.databaseLink = link
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
