import SwiftUI
import DBDeepCore

struct ResultsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter = ""
    @State private var copiedCell: CopiedCell?
    @State private var grid = ResultGridState()
    @State private var columnDrag: ColumnDrag?

    private struct ColumnDrag {
        let source: Int
        let target: Int
        let after: Bool
    }

    private struct CopiedCell: Equatable {
        let row: Int
        let column: Int
        let id = UUID()
    }

    private var displayedRows: [(offset: Int, element: [String?])] {
        store.result.map { grid.rows(in: $0, filter: filter) } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells").font(.system(size: 11)).foregroundStyle(Theme.purple)
                Text(store.error == nil ? "Results" : "Previous result").font(.system(size: 11, weight: .semibold))
                if let result = store.result {
                    Text(result.columns.isEmpty ? "\(result.affected) affected" : "\(result.rows.count) \(result.rows.count == 1 ? "row" : "rows")")
                        .font(.system(size: 9)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3).background(Theme.sidebar, in: Capsule())
                }
                Spacer()
                if let result = store.result {
                    Label(String(format: "%.0f ms", result.elapsed * 1000), systemImage: "clock").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                    IconButton(icon: "square.and.arrow.up", help: "Export all fetched rows as CSV") { store.exportCSV() }.disabled(result.columns.isEmpty)
                }
            }.padding(.horizontal, 17).frame(height: 43)
            if let error = store.error {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.accent("peach"))
                    Text(error).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    IconButton(icon: "xmark", help: "Dismiss error") { store.error = nil }
                }.padding(12).background(Theme.tint("peach")).padding(.horizontal, 14).padding(.bottom, 10)
            }
            if let result = store.result, !result.columns.isEmpty {
                HStack {
                    SearchField(placeholder: "Filter results…", text: $filter).frame(maxWidth: 205)
                    Spacer()
                    Text(result.truncated ? "First 1,000 rows · limit reached" : "All fetched rows").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                }.padding(.horizontal, 16).padding(.bottom, 12)
                resultTable(result)
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    Text("\(displayedRows.count) \(displayedRows.count == 1 ? "row" : "rows") displayed")
                    Spacer()
                    Text("Double-click a value to copy").foregroundStyle(Theme.secondary)
                }.font(.system(size: 9)).padding(.horizontal, 17).frame(height: 31)
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Mochi(size: 48)
                    Text(store.result == nil ? "Good things start with a query." : "\(store.result?.affected ?? 0) rows affected. Nicely done.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                    Text(store.result == nil ? "Run your SQL and see what turns up." : "Use Commit to save, or Rollback to undo your DML.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
        }.background(Theme.surface).overlay(alignment: .top) { Theme.line.frame(height: 1) }
            .disabled(store.isRunningQuery)
            .overlay {
                if store.isRunningQuery { QueryLoadingOverlay(status: store.status) }
            }
            .onChange(of: store.result?.id, initial: true) { _, _ in
                filter = ""; copiedCell = nil
                columnDrag = nil
                grid.reset(for: store.result)
            }
            .onChange(of: filter) { _, _ in copiedCell = nil }
            .onChange(of: store.isRunningQuery) { _, running in if running { copiedCell = nil; columnDrag = nil } }
            .task(id: copiedCell) {
                guard copiedCell != nil else { return }
                do { try await Task.sleep(for: .seconds(1.3)) } catch { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copiedCell = nil }
            }
    }

    private func width(_ index: Int, result: QueryResult) -> CGFloat {
        if let width = grid.columnWidths[index] { return CGFloat(width) }
        let name = result.columns[index].lowercased()
        if name == "id" || name.hasSuffix("_id") { return 64 }
        if name.contains("email") { return 210 }
        if name == "status" || name == "plan" { return 100 }
        let maxLength = result.rows.prefix(30).map { ($0.indices.contains(index) ? $0[index]?.count : 0) ?? 4 }.max() ?? 10
        return CGFloat(min(280, max(120, max(result.columns[index].count, maxLength) * 7 + 30)))
    }

    private func resultTable(_ result: QueryResult) -> some View {
        let rows = displayedRows
        let columns = grid.columns(in: result)
        return GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.offset) { position, row in
                        HStack(spacing: 0) {
                            Text("\(position + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary.opacity(0.7)).frame(width: 38, height: 36)
                            ForEach(columns, id: \.self) { index in
                                valueCell(row.element.indices.contains(index) ? row.element[index] : nil, column: result.columns[index], row: row.offset, index: index)
                                    .frame(width: width(index, result: result), height: 36, alignment: .leading)
                                    .overlay(alignment: .trailing) { Theme.line.opacity(0.6).frame(width: 1) }
                            }
                        }.background(position.isMultiple(of: 2) ? Theme.surface : Theme.canvas)
                            .overlay(alignment: .bottom) { Theme.line.opacity(0.75).frame(height: 1) }
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text("#").font(.system(size: 10)).foregroundStyle(Theme.secondary).frame(width: 38, height: 34)
                        ForEach(columns, id: \.self) { index in
                            ResultColumnHeader(name: result.columns[index], width: width(index, result: result),
                                sortDirection: grid.sortColumn == index ? grid.sortDirection : nil,
                                isDragging: columnDrag?.source == index,
                                dropAfter: columnDrag?.target == index && columnDrag?.source != index ? columnDrag?.after : nil,
                                onSort: { copiedCell = nil; grid.toggleSort(column: index) },
                                onResize: { grid.resize(column: index, width: Double($0)) },
                                onDragChanged: { location in
                                    copiedCell = nil
                                    if let target = columnDropTarget(at: location, result: result) {
                                        columnDrag = ColumnDrag(source: index, target: target.column, after: target.after)
                                    }
                                },
                                onDragEnded: { location in
                                    if let target = columnDropTarget(at: location, result: result) {
                                        grid.moveColumn(index, to: target.column, after: target.after)
                                    }
                                    columnDrag = nil
                                })
                        }
                    }.coordinateSpace(name: "resultColumns")
                        .background(Theme.sidebar).overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                }
                }.frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
    }

    private func columnDropTarget(at location: CGFloat, result: QueryResult) -> (column: Int, after: Bool)? {
        let columns = grid.columns(in: result)
        var leading: CGFloat = 38
        for column in columns {
            let trailing = leading + width(column, result: result)
            if location < trailing { return (column, location > (leading + trailing) / 2) }
            leading = trailing
        }
        return columns.last.map { ($0, true) }
    }

    private func valueCell(_ value: String?, column: String, row: Int, index: Int) -> some View {
        Group {
            if let value {
                if column.lowercased() == "status" {
                    HStack(spacing: 4) {
                        Circle().fill(value == "active" || value == "paid" ? Theme.green : Theme.secondary).frame(width: 4, height: 4)
                        Text(value).font(.system(size: 9))
                    }.foregroundStyle(value == "active" || value == "paid" ? Theme.green : Theme.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(value == "active" || value == "paid" ? Theme.tint("mint") : Theme.sidebar, in: Capsule())
                } else if column.lowercased() == "plan" {
                    CapsuleTag(text: value, color: value == "pro" ? "lavender" : value == "team" ? "peach" : "blue")
                } else {
                    Text(value).font(.system(size: 11, design: column.lowercased() == "id" ? .monospaced : .default)).lineLimit(1)
                }
            } else { Text("NULL").font(.system(size: 10, design: .monospaced)).italic().foregroundStyle(Theme.secondary.opacity(0.65)) }
        }.lineLimit(1).padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle()).onTapGesture(count: 2) {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(value ?? "NULL", forType: .string) else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    copiedCell = CopiedCell(row: row, column: index)
                }
            }
            .overlay(alignment: .trailing) {
                if copiedCell?.row == row, copiedCell?.column == index {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                        Text("Copied").foregroundStyle(Theme.ink)
                    }.font(.system(size: 9, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.green.opacity(0.35), lineWidth: 1))
                        .shadow(color: Theme.green.opacity(0.12), radius: 3, y: 1)
                        .padding(.trailing, 4)
                        .transition(.opacity)
                        .accessibilityElement(children: .ignore).accessibilityLabel("Copied")
                        .allowsHitTesting(false)
                }
            }
            .help(value ?? "NULL")
    }
}
