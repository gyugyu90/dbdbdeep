import SwiftUI
import DBDeepCore

struct BookmarkSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let bookmark: QueryBookmark?
    @State private var name = ""
    @State private var emoji = "✨"
    @State private var color = "lavender"
    @State private var sql = ""
    @State private var selectedSQL = ""
    @State private var connectionID: UUID?
    private let emojis = ["✨", "🌷", "🧺", "⚡️", "🍑", "🌱", "☁️", "🪄", "📊", "✏️", "🧸", "🐳"]
    private var hasSingleStatement: Bool { SQLStatementLocator.singleStatement(in: sql) != nil }
    private var bookmarkConnection: DBConnection? { store.connections.first { $0.id == connectionID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text(emoji).font(.system(size: 30)).frame(width: 54, height: 54).background(Theme.tint(color), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text(bookmark == nil ? "Keep a good query close" : "Make it yours").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("A name, a color, a little personality.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                IconButton(icon: "xmark", help: "Close") { dismiss() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.system(size: 11, weight: .medium))
                TextField("e.g. My favorite customer query", text: $name).textFieldStyle(.plain).padding(11).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Pick a little emoji").font(.system(size: 11, weight: .medium))
                    Spacer()
                    TextField("Emoji", text: $emoji).textFieldStyle(.plain).multilineTextAlignment(.center).frame(width: 42, height: 29)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6)).onChange(of: emoji) { _, value in emoji = String(value.prefix(2)) }
                }
                HStack(spacing: 5) {
                    ForEach(emojis, id: \.self) { item in
                        Button { emoji = item } label: {
                            Text(item).font(.system(size: 19)).frame(width: 34, height: 34)
                                .background(emoji == item ? Theme.tint(color) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Color").font(.system(size: 11, weight: .medium))
                    ColorChoices(selection: $color)
                }
                Spacer()
            }
            HStack {
                Text("Connection").font(.system(size: 11, weight: .medium))
                Spacer()
                if let connection = bookmarkConnection {
                    Label(connection.name, systemImage: connection.kind == .sample ? "leaf" : "externaldrive")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent(connection.color))
                        .lineLimit(1).help("Saved only in this connection’s library")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("SQL").font(.system(size: 11, weight: .medium))
                SQLTextEditor(text: $sql, selection: $selectedSQL).frame(height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
                Text("One SQL statement or PL/SQL block per bookmark.")
                    .font(.system(size: 10)).foregroundStyle(hasSingleStatement || sql.isEmpty ? Theme.secondary : Theme.accent("peach"))
            }
            HStack {
                Text("Loading a bookmark never runs it.").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary).keyboardShortcut(.cancelAction)
                SoftButton(title: "Save bookmark", icon: "bookmark.fill", prominent: true) {
                    store.saveBookmark(QueryBookmark(id: bookmark?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), emoji: emoji.isEmpty ? "✨" : emoji, color: color, sql: sql, connectionID: connectionID))
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasSingleStatement || bookmarkConnection == nil || connectionID != store.selectedID || store.isBusy).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 500).background(Theme.canvas).foregroundStyle(Theme.ink)
            .onAppear {
                name = bookmark?.name ?? ""
                emoji = bookmark?.emoji ?? "✨"
                color = bookmark?.color ?? "lavender"
                sql = bookmark?.sql ?? store.bookmarkDraftSQL
                if let bookmark { connectionID = bookmark.connectionID }
                else { connectionID = store.bookmarkDraftConnectionID }
            }
    }
}
