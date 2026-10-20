import SwiftUI
import DBDeepCore

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
            Group {
                if let connection = store.connection {
                    HStack(spacing: 5) {
                        Text("FOR").font(.system(size: 8, weight: .semibold)).tracking(1)
                        Label(connection.name, systemImage: connection.kind == .sample ? "leaf" : "externaldrive")
                            .font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }.foregroundStyle(Theme.accent(connection.color)).help(connection.name)
                } else {
                    Text("Choose a connection for your saved queries.").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 9).padding(.bottom, 23)
            SearchField(placeholder: "Find in this connection…", text: $store.bookmarkSearch).padding(.horizontal, 17).disabled(store.connection == nil)
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
            }.padding(.horizontal, 17).padding(.top, 13).padding(.bottom, 18).disabled(store.connection == nil)
            HStack {
                Text("SAVED QUERIES").font(.system(size: 8, weight: .semibold)).tracking(1.2)
                Spacer()
                Text("\(store.filteredBookmarks.count)").font(.system(size: 9))
            }.foregroundStyle(Theme.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.filteredBookmarks) { bookmark in bookmarkCard(bookmark) }
                    if store.filteredBookmarks.isEmpty {
                        Text(store.connection == nil ? "Select a connection to see its library." : store.connectionBookmarks.isEmpty ? "No saved queries for this connection yet.\nKeep one close with ⌘D." : "No matching queries in this connection.")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).padding(.vertical, 30)
                    }
                    Button { store.newBookmark() } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus").font(.system(size: 10))
                            Text("Save current query").font(.system(size: 11))
                        }.foregroundStyle(Theme.secondary).frame(maxWidth: .infinity).frame(height: 43)
                            .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }.buttonStyle(.plain).disabled(!store.canBookmarkQuery)
                    if !store.unassignedBookmarks.isEmpty { unassignedQueries }
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
        let focused = store.currentBookmark?.id == bookmark.id
        return ZStack(alignment: .topTrailing) {
            Button { store.focusBookmark(bookmark) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(bookmark.emoji).font(.system(size: 19)).frame(width: 30, height: 30)
                            .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        Spacer()
                        Color.clear.frame(width: 25, height: 25).accessibilityHidden(true)
                    }
                    Text(bookmark.name).font(.system(size: 11, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text(bookmark.sql.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.prefix(2).joined(separator: " "))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(1)
                }.padding(13).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .background(Theme.tint(bookmark.color).opacity(focused ? 1 : 0.65), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.accent(bookmark.color).opacity(focused ? 0.85 : 0.09), lineWidth: focused ? 1.5 : 1))
            }.buttonStyle(.plain).accessibilityValue(focused ? "Focused query" : "")
                .help("Focus query in console · Right-click to edit")
            Button { Task { await store.runBookmark(bookmark) } } label: {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent(bookmark.color)).frame(width: 25, height: 25)
                    .background(Theme.surface.opacity(0.8), in: Circle()).contentShape(Circle())
            }.buttonStyle(.plain).padding(13)
                .disabled(!store.canRunBookmark(bookmark))
                .accessibilityLabel("Run \(bookmark.name)").help("Run this saved query")
        }.disabled(store.isBusy)
            .contextMenu {
                Button("Edit bookmark…") { store.editBookmark(bookmark) }
                Button("Copy SQL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(bookmark.sql, forType: .string) }
                Divider()
                Button("Delete bookmark", role: .destructive) { store.removeBookmark(bookmark) }
            }
    }

    private var unassignedQueries: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Queries saved without a connection, or from a removed connection. Move one into this library to keep using it.")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                ForEach(store.unassignedBookmarks) { bookmark in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(bookmark.emoji)
                            Text(bookmark.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        Text(bookmark.sql).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.secondary).lineLimit(2)
                        Button("Move here", systemImage: "arrow.down.to.line") { store.assignBookmark(bookmark) }
                            .font(.system(size: 10, weight: .medium)).buttonStyle(.plain).foregroundStyle(Theme.purple)
                            .disabled(store.connection == nil || store.isBusy)
                            .help(store.connection.map { "Move to \($0.name)" } ?? "Select a connection first")
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(.top, 10)
        } label: {
            Text("Unassigned queries · \(store.unassignedBookmarks.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
        }.padding(.top, 10)
    }
}
