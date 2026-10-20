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
