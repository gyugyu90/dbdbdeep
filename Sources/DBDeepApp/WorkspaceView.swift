import SwiftUI
import DBDeepCore

struct WorkspaceView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            Rectangle().fill(Theme.line).frame(height: 1)
            GeometryReader { geometry in
                let maximumSidebarWidth = max(250, geometry.size.width / 3)
                HSplitView {
                    ConnectionSidebar().frame(minWidth: 210, idealWidth: 240, maxWidth: maximumSidebarWidth)
                    ConsoleView().frame(minWidth: 450, maxWidth: .infinity)
                    if store.showBookmarks { BookmarkSidebar().frame(minWidth: 250, idealWidth: 285, maxWidth: maximumSidebarWidth) }
                }
            }
            statusbar
        }
        .foregroundStyle(Theme.ink).background(Theme.surface)
        .frame(minWidth: store.showBookmarks ? 1060 : 800, minHeight: 680)
        .tint(Theme.purple)
        .onChange(of: colorScheme, initial: true) { _, scheme in AppAppearance.updateIcon(for: scheme) }
        .sheet(isPresented: $store.showConnection) { ConnectionSheet(connection: store.editingConnection) }
        .sheet(isPresented: $store.showConnectionDetails) {
            if let connection = store.connections.first(where: { $0.id == store.diagnosticConnectionID }) {
                ConnectionDetailsSheet(connection: connection)
            }
        }
        .sheet(isPresented: $store.showBookmark) { BookmarkSheet(bookmark: store.editingBookmark) }
        .onChange(of: store.query) { _, _ in store.queryChanged() }
        .task { await store.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.persist() }
    }

    private var titlebar: some View {
        HStack(spacing: 10) {
            Mochi(size: 28)
            Text("dbdbdeep").font(.system(size: 19, weight: .bold, design: .rounded)).tracking(-0.7)
            Rectangle().fill(Theme.line).frame(width: 1, height: 18).padding(.horizontal, 8)
            Text("A happy place for your data").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Spacer()
            Button { store.showHistory.toggle() } label: {
                Label("History", systemImage: "clock.arrow.circlepath").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                .popover(isPresented: $store.showHistory) { historyView }
            IconButton(icon: "sidebar.right", help: "Toggle bookmarks") { store.showBookmarks.toggle() }
        }
        .padding(.leading, 80).padding(.trailing, 20).frame(height: 56)
        .background(Theme.canvas)
        .background(WindowTitlebar())
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Query history").font(.system(size: 16, weight: .semibold))
            Text("Successful queries in this session").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            if store.history.isEmpty { Text("Your first query is waiting for you.").padding(.vertical, 24) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(store.history.enumerated()), id: \.offset) { _, entry in
                        Button {
                            store.query = entry.sql; store.selectedSQL = ""; store.cursorLocation = 0; store.showHistory = false
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.sql).font(.system(size: 11, design: .monospaced)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                Text(entry.time, style: .time).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            }.padding(10).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(store.isBusy)
                    }
                }
            }.frame(maxHeight: 350)
        }.padding(20).frame(width: 360)
    }

    private var statusbar: some View {
        HStack(spacing: 7) {
            Circle().fill(store.isConnected ? Theme.green : Theme.secondary).frame(width: 5, height: 5)
            Text(store.status).lineLimit(1)
            Spacer()
            if store.connection?.kind == .sample { Text("Local playground").foregroundStyle(Theme.secondary) }
            Text("✦").foregroundStyle(Theme.purple).padding(.horizontal, 6)
            Text("Made for curious minds").foregroundStyle(Theme.secondary)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text("·").foregroundStyle(Theme.secondary)
                Text("v\(version)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.secondary)
            }
        }.font(.system(size: 10)).padding(.horizontal, 18).frame(height: 28)
            .background(Theme.canvas).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct ConnectionSidebar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Theme.secondary)
                Spacer()
                CapsuleTag(text: "PERSONAL", color: "lavender")
            }.padding(.horizontal, 18).padding(.top, 25).padding(.bottom, 23)
            HStack {
                Text("Connections").font(.system(size: 12, weight: .semibold))
                Spacer()
                IconButton(icon: "plus", help: "Add Oracle connection") { store.newConnection() }.disabled(store.isBusy)
            }.padding(.horizontal, 16).padding(.bottom, 8)
            VStack(spacing: 5) {
                ForEach(store.connections) { connection in
                    connectionRow(connection)
                }
            }.padding(.horizontal, 10)
            Button { store.newConnection() } label: {
                Label("Add connection", systemImage: "plus.circle").font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17).padding(.vertical, 13)
            }.buttonStyle(.plain).foregroundStyle(Theme.secondary).disabled(store.isBusy)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 18).padding(.vertical, 12)
            HStack {
                Text("SCHEMA").font(.system(size: 9, weight: .semibold)).tracking(1.5)
                Spacer()
                IconButton(icon: "arrow.clockwise", help: "Refresh schema") { Task { await store.refreshSchema() } }.disabled(store.isBusy || !store.isConnected)
            }.foregroundStyle(Theme.secondary).padding(.horizontal, 18)
            SearchField(placeholder: "Find a table…", text: $store.schemaSearch).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            if store.isConnected {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    Image(systemName: "folder").font(.system(size: 11))
                    Text(store.connection?.kind == .oracle ? (store.connection?.username.uppercased() ?? "Schema") : "main").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("\(store.tables.count)").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.filteredTables) { table in schemaRow(table) }
                        if store.filteredTables.isEmpty {
                            Text(store.schemaSearch.isEmpty ? "No tables yet. Create something lovely." : "No matching tables.").font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(18)
                        }
                    }.padding(.horizontal, 10)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.plus").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.purple.opacity(0.7))
                    Text("Your tables will feel\nright at home here.").font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(Theme.secondary)
                    if let connection = store.connection {
                        SoftButton(title: "Connect", icon: "bolt", prominent: true) { Task { await store.connect(connection) } }.disabled(store.isBusy)
                    }
                }.frame(maxWidth: .infinity).padding(.top, 24)
                Spacer()
            }
            Spacer(minLength: 8)
        }.background(Theme.sidebar)
    }

    private func connectionRow(_ connection: DBConnection) -> some View {
        let selected = store.selectedID == connection.id
        let connected = store.connectedIDs.contains(connection.id)
        return Button { store.select(connection) } label: {
            HStack(spacing: 10) {
                Image(systemName: connection.kind == .oracle ? "externaldrive" : "leaf")
                    .font(.system(size: 14)).foregroundStyle(Theme.accent(connection.color))
                    .frame(width: 30, height: 32).background(Theme.tint(connection.color), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(connected ? Theme.green : Theme.secondary.opacity(0.5)).frame(width: 4, height: 4)
                        Text(connection.kind == .sample ? "SQLite · local" : "Oracle · \(connected ? "connected" : "offline")").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer(minLength: 1)
                if selected { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.purple) }
            }.padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.line : .clear, lineWidth: 1))
        }.buttonStyle(.plain).disabled(store.isBusy)
            .contextMenu {
                if connection.kind == .oracle {
                    Button("Connect") { Task { await store.connect(connection) } }
                    Button("Connection details…") {
                        store.diagnosticConnectionID = connection.id; store.showConnectionDetails = true
                    }
                    Button("Edit connection…") { store.editingConnection = connection; store.showConnection = true }
                    Divider()
                    Button("Remove connection", role: .destructive) { Task { await store.removeConnection(connection) } }
                }
            }
    }

    private func schemaRow(_ table: SchemaTable) -> some View {
        let expanded = store.expandedTables.contains(table.name)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Button {
                    if expanded { store.expandedTables.remove(table.name) } else { store.expandedTables.insert(table.name) }
                } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).frame(width: 13, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary)
                Button { store.browse(table) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: table.isView ? "eye" : "tablecells").font(.system(size: 11)).foregroundStyle(Theme.purple.opacity(0.8))
                        Text(table.name).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.isBusy).help("Browse \(table.name)")
            }.padding(.horizontal, 10)
            if expanded {
                ForEach(table.columns) { column in
                    HStack(spacing: 7) {
                        Image(systemName: column.primaryKey ? "key.horizontal" : "number").font(.system(size: 9)).foregroundStyle(column.primaryKey ? Theme.accent("yellow") : Theme.secondary.opacity(0.7)).frame(width: 12)
                        Text(column.name).font(.system(size: 10)).lineLimit(1)
                        Spacer(minLength: 3)
                        Text(column.type.lowercased()).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }.padding(.leading, 39).padding(.trailing, 12).frame(height: 26)
                        .help("\(column.name) · \(column.type) · \(column.nullable ? "nullable" : "not null")")
                }
            }
        }
    }
}

struct ConsoleView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text("Query console").font(.system(size: 21, weight: .semibold, design: .rounded)).tracking(-0.5)
                        Text("✦").font(.system(size: 15)).foregroundStyle(Theme.accent("yellow"))
                    }
                    Text("A little curiosity goes a long way.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if let connection = store.connection {
                    HStack(spacing: 6) {
                        Circle().fill(store.isConnected ? Theme.green : Theme.secondary).frame(width: 5, height: 5)
                        Text(connection.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }.padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.sidebar, in: Capsule())
                    if connection.kind == .oracle {
                        IconButton(icon: "info.circle", help: "View connection details") {
                            store.diagnosticConnectionID = connection.id; store.showConnectionDetails = true
                        }
                    }
                }
            }.padding(.horizontal, 25).frame(height: 87)
            VSplitView {
                editor.frame(minHeight: 230, idealHeight: 335)
                ResultsView().frame(minHeight: 160, maxHeight: .infinity)
            }
        }.background(Theme.surface)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(Theme.purple)
                    Text("Query 01").font(.system(size: 11, weight: .medium))
                    Circle().fill(Theme.purple.opacity(0.55)).frame(width: 4, height: 4)
                }.padding(.horizontal, 17).frame(height: 40)
                    .background(Theme.surface).overlay(alignment: .top) { Theme.purple.opacity(0.75).frame(height: 2) }
                Spacer()
                Text(store.connection?.dialect ?? "SQL").font(.system(size: 9)).foregroundStyle(Theme.secondary).padding(.trailing, 16)
            }.background(Theme.sidebar.opacity(0.7))
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            HStack(spacing: 6) {
                SoftButton(title: store.isBusy ? "Running…" : (store.selectedSQL.isEmpty ? "Run statement" : "Run selection"), icon: "play.fill", prominent: true) { Task { await store.run() } }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!store.canRunQuery)
                    .opacity(store.canRunQuery ? 1 : 0.6)
                    .help(store.selectedSQL.isEmpty ? "Run the statement at the cursor · ⌘↵" : "Run only the selected SQL · ⌘↵")
                Text("⌘ ↵").font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.leading, 2)
                Spacer(minLength: 0)
                let bookmark = store.currentBookmark
                IconButton(icon: bookmark == nil ? "bookmark" : "bookmark.fill", help: bookmark.map { "Edit bookmark · \($0.name) · ⌘D" } ?? "Bookmark the statement at or before the cursor · ⌘D") { store.newBookmark() }
                    .keyboardShortcut("d", modifiers: .command).disabled(!store.canBookmarkQuery)
                Rectangle().fill(Theme.line).frame(width: 1, height: 17).padding(.horizontal, 3)
                IconButton(icon: "checkmark.circle", help: "Commit changes") { Task { await store.transaction(commit: true) } }.disabled(store.isBusy || !store.isConnected)
                IconButton(icon: "arrow.uturn.backward", help: "Roll back changes") { Task { await store.transaction(commit: false) } }.disabled(store.isBusy || !store.isConnected)
                CapsuleTag(text: "MANUAL COMMIT", color: "mint").padding(.leading, 3)
            }.padding(.horizontal, 16).frame(height: 54)
            SQLTextEditor(text: $store.query, selection: $store.selectedSQL, cursorLocation: $store.cursorLocation, tables: store.tables, connectionKind: store.connection?.kind ?? .oracle)
            HStack(spacing: 5) {
                Image(systemName: "info.circle").font(.system(size: 9))
                Text(store.selectedSQL.isEmpty ? (store.sqlToRun.isEmpty ? "Place the cursor in a SQL statement" : "Statement at cursor will run · ⌘↵") : "Only selected SQL will run · ⌘↵")
                Spacer()
                Text("UTF-8"); Text("·"); Text("\(store.query.components(separatedBy: "\n").count) lines")
            }.font(.system(size: 9)).foregroundStyle(Theme.secondary).padding(.horizontal, 17).frame(height: 28)
                .background(Theme.canvas)
        }.background(Theme.surface)
    }
}

struct ResultsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter = ""
    @State private var copiedCell: CopiedCell?

    private struct CopiedCell: Equatable {
        let row: Int
        let column: Int
        let id = UUID()
    }

    private var displayedRows: [(offset: Int, element: [String?])] {
        Array((store.result?.rows ?? []).enumerated()).filter { filter.isEmpty || $0.element.contains { $0?.localizedCaseInsensitiveContains(filter) == true } }
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
                    IconButton(icon: "square.and.arrow.up", help: "Export displayed result as CSV") { store.exportCSV() }.disabled(result.columns.isEmpty)
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
            .onChange(of: store.result?.id) { _, _ in filter = ""; copiedCell = nil }
            .onChange(of: filter) { _, _ in copiedCell = nil }
            .onChange(of: store.isRunningQuery) { _, running in if running { copiedCell = nil } }
            .task(id: copiedCell) {
                guard copiedCell != nil else { return }
                do { try await Task.sleep(for: .seconds(1.3)) } catch { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copiedCell = nil }
            }
    }

    private func width(_ index: Int, result: QueryResult) -> CGFloat {
        let name = result.columns[index].lowercased()
        if name == "id" || name.hasSuffix("_id") { return 64 }
        if name.contains("email") { return 210 }
        if name == "status" || name == "plan" { return 100 }
        let maxLength = result.rows.prefix(30).map { ($0.indices.contains(index) ? $0[index]?.count : 0) ?? 4 }.max() ?? 10
        return CGFloat(min(280, max(120, max(result.columns[index].count, maxLength) * 7 + 30)))
    }

    private func resultTable(_ result: QueryResult) -> some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(displayedRows, id: \.offset) { row in
                        HStack(spacing: 0) {
                            Text("\(row.offset + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary.opacity(0.7)).frame(width: 38, height: 36)
                            ForEach(result.columns.indices, id: \.self) { index in
                                valueCell(row.element.indices.contains(index) ? row.element[index] : nil, column: result.columns[index], row: row.offset, index: index)
                                    .frame(width: width(index, result: result), height: 36, alignment: .leading)
                                    .overlay(alignment: .trailing) { Theme.line.opacity(0.6).frame(width: 1) }
                            }
                        }.background(row.offset.isMultiple(of: 2) ? Theme.surface : Theme.canvas)
                            .overlay(alignment: .bottom) { Theme.line.opacity(0.75).frame(height: 1) }
                    }
                } header: {
                    HStack(spacing: 0) {
                        Text("#").font(.system(size: 10)).foregroundStyle(Theme.secondary).frame(width: 38, height: 34)
                        ForEach(result.columns.indices, id: \.self) { index in
                            HStack(spacing: 6) {
                                Text(result.columns[index].lowercased() == "id" ? "⌑" : "≡").foregroundStyle(Theme.secondary)
                                Text(result.columns[index]).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            }.padding(.leading, 12).frame(width: width(index, result: result), height: 34, alignment: .leading)
                                .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                        }
                    }.background(Theme.sidebar).overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
                }
                }.frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
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
        }.padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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

struct BookmarkSidebar: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("Your little library").font(.system(size: 16, weight: .semibold, design: .rounded)).tracking(-0.3)
                Text("🔖").font(.system(size: 15))
                Spacer(minLength: 0)
                IconButton(icon: "plus", help: "Save a bookmark") { store.newBookmark() }.disabled(!store.canBookmarkQuery)
            }.padding(.horizontal, 20).padding(.top, 28)
            Text("Good queries deserve a cozy home.").font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.horizontal, 20).padding(.top, 7).padding(.bottom, 23)
            SearchField(placeholder: "Find a saved query…", text: $store.bookmarkSearch).padding(.horizontal, 17)
            HStack(spacing: 8) {
                Button { store.bookmarkFilter = nil } label: {
                    Text("All queries").font(.system(size: 10, weight: .medium)).padding(.horizontal, 10).frame(height: 25)
                        .background(store.bookmarkFilter == nil ? Theme.tint("lavender") : .clear, in: Capsule())
                        .foregroundStyle(store.bookmarkFilter == nil ? Theme.purple : Theme.secondary)
                }.buttonStyle(.plain)
                ForEach(Theme.colorNames.prefix(4), id: \.self) { name in
                    Button { store.bookmarkFilter = store.bookmarkFilter == name ? nil : name } label: {
                        Circle().fill(Theme.accent(name).opacity(0.7)).frame(width: 9, height: 9)
                            .padding(4).overlay(Circle().stroke(store.bookmarkFilter == name ? Theme.accent(name) : .clear, lineWidth: 1))
                    }.buttonStyle(.plain).help("Filter \(name)")
                }
            }.padding(.horizontal, 17).padding(.top, 13).padding(.bottom, 18)
            HStack {
                Text("SAVED QUERIES").font(.system(size: 8, weight: .semibold)).tracking(1.2)
                Spacer()
                Text("\(store.filteredBookmarks.count)").font(.system(size: 9))
            }.foregroundStyle(Theme.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.filteredBookmarks) { bookmark in bookmarkCard(bookmark) }
                    if store.filteredBookmarks.isEmpty {
                        Text("A little empty, a lot of potential.\nSave a query with ⌘D.").font(.system(size: 11)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).padding(.vertical, 30)
                    }
                    Button { store.newBookmark() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus").font(.system(size: 10))
                            Text("Save current query").font(.system(size: 11))
                        }.foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).frame(height: 43)
                            .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }.buttonStyle(.plain).disabled(!store.canBookmarkQuery)
                }.padding(.horizontal, 17).padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "lightbulb").font(.system(size: 13)).foregroundStyle(Theme.accent("yellow"))
                Text("A name, a color, a little emoji.\nMake each query feel like yours.").font(.system(size: 9)).foregroundStyle(Theme.secondary).lineSpacing(4)
            }.padding(.horizontal, 23).padding(.vertical, 20)
        }.background(Theme.bookmarks)
    }

    private func bookmarkCard(_ bookmark: QueryBookmark) -> some View {
        Button { store.loadBookmark(bookmark) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(bookmark.emoji).font(.system(size: 19)).frame(width: 30, height: 30)
                        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Theme.accent(bookmark.color).opacity(0.7))
                }
                Text(bookmark.name).font(.system(size: 11, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(bookmark.sql.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.prefix(2).joined(separator: " "))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.tint(bookmark.color).opacity(0.75), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.accent(bookmark.color).opacity(0.09), lineWidth: 1))
        }.buttonStyle(.plain).disabled(store.isBusy)
            .contextMenu {
                Button("Edit bookmark…") { store.editingBookmark = bookmark; store.showBookmark = true }
                Button("Copy SQL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(bookmark.sql, forType: .string) }
                Divider()
                Button("Delete bookmark", role: .destructive) { store.removeBookmark(bookmark) }
            }.help("Load query · Right-click to edit")
    }
}
