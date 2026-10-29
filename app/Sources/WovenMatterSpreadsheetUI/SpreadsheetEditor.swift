import SwiftUI
import WovenMatterCore

public struct DashboardSpreadsheetEditor: View {
    @Binding private var document: NoteDocument

    public init(document: Binding<NoteDocument>) {
        self._document = document
    }

    private var tableIndex: Int? {
        document.blocks.firstIndex {
            if case .table = $0 { true } else { false }
        }
    }

    private var table: NoteTableBlock {
        let blocks = document.blocks
        guard let index = blocks.firstIndex(where: {
            if case .table = $0 { true } else { false }
        }), case .table(let table) = blocks[index] else {
            return NoteTableBlock(rows: 20, columns: 8, headerRow: true)
        }
        return table
    }

    public var body: some View {
        let table = self.table
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Button { addRow() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Add row")
                    .help("Add row")
                    Button { removeRow() } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Remove last row")
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
                    .accessibilityLabel("Add column")
                    .help("Add column")
                    Button { removeColumn() } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Remove last column")
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
                // Cell widths are fixed, so row virtualization preserves the
                // grid geometry without constructing every off-screen editor.
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
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
                        HStack(spacing: 0) {
                            Text("\(rowIndex + 1)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, height: 30)
                                .background(Color.secondary.opacity(0.06))
                                .overlay { Rectangle().stroke(Color.secondary.opacity(0.16), lineWidth: 0.5) }
                            ForEach(Array(row.cells.enumerated()), id: \.element.id) { columnIndex, _ in
                                TextField("", text: cellBinding(row: rowIndex, column: columnIndex))
                                    .accessibilityLabel("Cell \(spreadsheetColumnName(columnIndex))\(rowIndex + 1)")
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
            .scrollIndicators(.never)
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
                let table = self.table
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

