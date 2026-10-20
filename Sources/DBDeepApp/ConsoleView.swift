import SwiftUI
import DBDeepCore

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
                    .help(store.selectedSQL.isEmpty ? "Run the statement at or before the cursor · ⌘↵" : "Run only the selected SQL · ⌘↵")
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
            SQLTextEditor(text: $store.query, selection: $store.selectedSQL, cursorLocation: $store.cursorLocation, tables: store.tables, connectionKind: store.connection?.kind ?? .oracle, focusRequest: store.editorFocusRequest)
            HStack(spacing: 5) {
                Image(systemName: "info.circle").font(.system(size: 9))
                Text(store.selectedSQL.isEmpty ? (store.sqlToRun.isEmpty ? "Place the cursor in or after a SQL statement" : "Statement at or before cursor will run · ⌘↵") : "Only selected SQL will run · ⌘↵")
                Spacer()
                Text("UTF-8"); Text("·"); Text("\(store.query.components(separatedBy: "\n").count) lines")
            }.font(.system(size: 9)).foregroundStyle(Theme.secondary).padding(.horizontal, 17).frame(height: 28)
                .background(Theme.canvas)
        }.background(Theme.surface)
    }
}
