import SwiftUI
import DBDeepCore

struct ConnectionSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let connection: DBConnection?
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var service: String
    @State private var username: String
    @State private var password = ""
    @State private var usesSID: Bool
    @State private var color: String
    @State private var message: String?
    @State private var testPassed = false
    @State private var testing = false
    private let id: UUID

    init(connection: DBConnection?) {
        self.connection = connection; id = connection?.id ?? UUID()
        _name = State(initialValue: connection?.name ?? "")
        _host = State(initialValue: connection?.host ?? "localhost")
        _port = State(initialValue: String(connection?.port ?? 1521))
        _service = State(initialValue: connection?.service ?? "FREEPDB1")
        _username = State(initialValue: connection?.username ?? "")
        _usesSID = State(initialValue: connection?.usesSID ?? false)
        _color = State(initialValue: connection?.color ?? "lavender")
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (1...65535).contains(Int(port) ?? 0) && !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!password.isEmpty || connection != nil)
    }
    private var profile: DBConnection {
        DBConnection(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 1521, service: service.trimmingCharacters(in: .whitespacesAndNewlines), username: username.trimmingCharacters(in: .whitespacesAndNewlines), usesSID: usesSID, color: color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.plus").font(.system(size: 22)).foregroundStyle(Theme.purple)
                    .frame(width: 48, height: 48).background(Theme.tint("lavender"), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(connection == nil ? "Meet your database" : "A little connection care").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Give your Oracle connection a cozy home.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                IconButton(icon: "xmark", help: "Close") { dismiss() }.disabled(store.isBusy || testing)
            }
            formField("Connection name") { TextField("e.g. My happy development DB", text: $name) }
            HStack(alignment: .top, spacing: 14) {
                formField("Host") { TextField("localhost", text: $host) }
                formField("Port") { TextField("1521", text: $port) }.frame(width: 95)
            }
            HStack(alignment: .top, spacing: 14) {
                formField(usesSID ? "SID" : "Service name") { TextField("FREEPDB1", text: $service) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect with").font(.system(size: 11, weight: .medium))
                    Picker("Connect with", selection: $usesSID) {
                        Text("Service").tag(false); Text("SID").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(height: 34)
                }.frame(width: 165)
            }
            HStack(alignment: .top, spacing: 14) {
                formField("Username") { TextField("Your Oracle user", text: $username) }
                formField("Password") { SecureField(connection == nil ? "Your password" : "Leave blank to keep saved", text: $password) }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("A little color").font(.system(size: 11, weight: .medium))
                ColorChoices(selection: $color)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(Theme.green)
                Text("Your password stays in macOS Keychain.\nDML uses manual commit. Oracle DDL commits automatically.")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineSpacing(4)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.tint("mint").opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(testPassed ? Theme.green : Theme.accent("peach")).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                SoftButton(title: testing ? "Testing…" : "Test connection", icon: "bolt") { testConnection() }.disabled(!valid || testing || store.isBusy)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary).keyboardShortcut(.cancelAction).disabled(testing || store.isBusy)
                SoftButton(title: store.isBusy ? "Connecting…" : "Save & connect", icon: "arrow.right", prominent: true) {
                    Task {
                        let saved = await store.saveConnection(profile, password: password)
                        if !saved { message = store.error; testPassed = false }
                    }
                }.disabled(!valid || testing || store.isBusy).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 500).background(Theme.canvas).foregroundStyle(Theme.ink).preferredColorScheme(.light)
            .interactiveDismissDisabled(testing || store.isBusy)
    }

    private func testConnection() {
        testing = true; message = nil
        let target = profile
        Task {
            do {
                let secret = try password.isEmpty ? PasswordKeychain.read(for: target.id) : password
                let database = OracleDatabase(connection: target, runtime: store.oracleRuntime)
                try await database.connect(password: secret)
                await database.disconnect()
                message = "Connected! Your database is ready to meet you."
                testPassed = true
            } catch { message = error.localizedDescription; testPassed = false }
            testing = false
        }
    }

    private func formField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium))
            content().textFieldStyle(.plain).font(.system(size: 12)).padding(.horizontal, 11).frame(height: 36)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        }
    }
}

struct ColorChoices: View {
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Theme.colorNames, id: \.self) { name in
                Button { selection = name } label: {
                    Circle().fill(Theme.accent(name).opacity(0.8)).frame(width: 24, height: 24)
                        .overlay { if selection == name { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                        .padding(3).overlay(Circle().stroke(selection == name ? Theme.accent(name) : .clear, lineWidth: 1))
                }.buttonStyle(.plain).help(name.capitalized).accessibilityLabel(name.capitalized)
            }
        }
    }
}

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
                TextField("e.g. My favorite customer query", text: $name).textFieldStyle(.plain).padding(11).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Pick a little emoji").font(.system(size: 11, weight: .medium))
                    Spacer()
                    TextField("Emoji", text: $emoji).textFieldStyle(.plain).multilineTextAlignment(.center).frame(width: 42, height: 29)
                        .background(.white, in: RoundedRectangle(cornerRadius: 6)).onChange(of: emoji) { _, value in emoji = String(value.prefix(2)) }
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
                Picker("Connection", selection: $connectionID) {
                    Text("Any connection").tag(nil as UUID?)
                    ForEach(store.connections) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 240)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("SQL").font(.system(size: 11, weight: .medium))
                SQLTextEditor(text: $sql, selection: $selectedSQL).frame(height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
            }
            HStack {
                Text("Loading a bookmark never runs it.").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary).keyboardShortcut(.cancelAction)
                SoftButton(title: "Save bookmark", icon: "bookmark.fill", prominent: true) {
                    store.saveBookmark(QueryBookmark(id: bookmark?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), emoji: emoji.isEmpty ? "✨" : emoji, color: color, sql: sql, connectionID: connectionID))
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 500).background(Theme.canvas).foregroundStyle(Theme.ink).preferredColorScheme(.light)
            .onAppear {
                name = bookmark?.name ?? ""
                emoji = bookmark?.emoji ?? "✨"
                color = bookmark?.color ?? "lavender"
                sql = bookmark?.sql ?? (store.selectedSQL.isEmpty ? store.query : store.selectedSQL)
                connectionID = bookmark?.connectionID ?? store.selectedID
            }
    }
}
