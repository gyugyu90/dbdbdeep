import SwiftUI
import UniformTypeIdentifiers
import DBDeepCore

struct ConnectionSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let connection: DBConnection?
    @State private var kind: DBConnection.Kind
    @State private var mongoConnectionString = ""
    @State private var mongoImportError: String?
    @State private var mongoImportMessage: String?
    @State private var mongoAuthSource: String
    @State private var mongoTLS: Bool
    @State private var mongoSRV: Bool
    @State private var mongoReplicaSet: String
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var service: String
    @State private var username: String
    @State private var password = ""
    @State private var usesSID: Bool
    @State private var color: String
    @State private var testing = false
    @State private var usesBundledInternationalization: Bool
    @State private var additionalJARs: [String]
    @State private var showLibraries = true
    @State private var showPasswordInfo = false
    @State private var id: UUID

    init(connection: DBConnection?) {
        self.connection = connection
        _kind = State(initialValue: connection?.kind ?? .oracle)
        _mongoAuthSource = State(initialValue: connection?.mongoAuthSource ?? "")
        _mongoTLS = State(initialValue: connection?.mongoTLS ?? false)
        _mongoSRV = State(initialValue: connection?.mongoSRV ?? false)
        _mongoReplicaSet = State(initialValue: connection?.mongoReplicaSet ?? "")
        _id = State(initialValue: connection?.id ?? UUID())
        _name = State(initialValue: connection?.name ?? "")
        _host = State(initialValue: connection?.host ?? "localhost")
        _port = State(initialValue: String(connection?.port ?? 1521))
        _service = State(initialValue: connection?.service ?? "FREEPDB1")
        _username = State(initialValue: connection?.username ?? "")
        _usesSID = State(initialValue: connection?.usesSID ?? false)
        _color = State(initialValue: connection?.color ?? "lavender")
        _usesBundledInternationalization = State(initialValue: connection?.usesBundledInternationalization ?? true)
        _additionalJARs = State(initialValue: connection?.additionalJARs ?? [])
    }

    private var valid: Bool {
        (kind != .mongodb || mongoConnectionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && profile.configurationError == nil && (!profile.needsPassword || !password.isEmpty || connection != nil)
    }
    private var profile: DBConnection {
        DBConnection(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 0, service: service.trimmingCharacters(in: .whitespacesAndNewlines), username: username.trimmingCharacters(in: .whitespacesAndNewlines), usesSID: usesSID, color: color, usesBundledInternationalization: usesBundledInternationalization, additionalJARs: additionalJARs, mongoAuthSource: mongoAuthSource.trimmingCharacters(in: .whitespacesAndNewlines), mongoTLS: mongoTLS, mongoSRV: mongoSRV, mongoReplicaSet: mongoReplicaSet.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                DatabaseIcon(kind: kind, size: 28)
                    .frame(width: 48, height: 48).background(Theme.tint("lavender"), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(connection == nil ? "Meet your database" : "A little connection care").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Give your database a cozy home.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                IconButton(icon: "xmark", help: "Close") { dismiss() }.disabled(store.isBusy || testing)
            }
            HStack(alignment: .top, spacing: 22) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        Picker("Database type", selection: $kind) {
                            Text("Oracle").tag(DBConnection.Kind.oracle)
                            Text("MongoDB").tag(DBConnection.Kind.mongodb)
                        }.pickerStyle(.segmented).disabled(connection != nil)
                            .onChange(of: kind) { _, value in
                                port = value == .mongodb ? "27017" : "1521"
                                service = value == .mongodb ? "test" : "FREEPDB1"
                                password = ""
                            }
                        formField("Connection name") { TextField("e.g. My happy development DB", text: $name) }
                        if kind == .mongodb {
                            formField("Connection URI (optional)") {
                                TextField("mongodb://host1:27017,host2:27017/database", text: $mongoConnectionString)
                                    .onSubmit { importMongoURI() }
                                    .onChange(of: mongoConnectionString) { _, value in
                                        if !value.isEmpty { mongoImportError = nil; mongoImportMessage = nil }
                                    }
                            }
                            SoftButton(title: "Import URI", icon: "arrow.down.doc") { importMongoURI() }
                                .disabled(mongoConnectionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if let mongoImportError { Text(mongoImportError).font(.system(size: 10)).foregroundStyle(Theme.accent("peach")) }
                            if let mongoImportMessage { Text(mongoImportMessage).font(.system(size: 10)).foregroundStyle(Theme.green) }
                        }
                        HStack(alignment: .top, spacing: 14) {
                            formField(kind == .mongodb ? "Hosts" : "Host") { TextField("localhost", text: $host) }
                            formField(kind == .mongodb ? "Default port" : "Port") { TextField(kind == .mongodb ? "27017" : "1521", text: $port) }.frame(width: 95).disabled(kind == .mongodb && mongoSRV)
                        }
                        if kind == .mongodb {
                            Text("Separate hosts with commas. Each host may include its own :port; otherwise Default port is used.")
                                .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            HStack(alignment: .top, spacing: 14) {
                                formField("Database") { TextField("test", text: $service) }
                                formField("Authentication DB (optional)") { TextField(service.isEmpty ? "admin" : service, text: $mongoAuthSource) }
                            }
                            Text("Leave Authentication DB blank to authenticate against \(service.isEmpty ? "admin" : service). It is ignored when no username is set.")
                                .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            formField("Replica set (optional)") { TextField("e.g. rs0", text: $mongoReplicaSet) }
                            Toggle("DNS SRV (Atlas)", isOn: $mongoSRV).toggleStyle(.checkbox)
                                .onChange(of: mongoSRV) { _, enabled in if enabled { mongoTLS = true } }
                            Toggle("TLS", isOn: $mongoTLS).toggleStyle(.checkbox).disabled(mongoSRV)
                            Text(mongoSRV ? "Use the cluster hostname. SRV enables TLS and discovers ports automatically." : "Leave username and password blank for a local server without authentication.")
                                .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            Text("Writes are applied immediately. Manual commit and rollback are unavailable.")
                                .font(.system(size: 10)).foregroundStyle(Theme.accent("peach"))
                        } else {
                            HStack(alignment: .top, spacing: 14) {
                                formField(usesSID ? "SID" : "Service name") { TextField("FREEPDB1", text: $service) }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Connect with").font(.system(size: 11, weight: .medium))
                                    Picker("Connect with", selection: $usesSID) {
                                        Text("Service").tag(false); Text("SID").tag(true)
                                    }.pickerStyle(.segmented).labelsHidden().frame(height: 34)
                                }.frame(width: 165)
                            }
                        }
                        HStack(alignment: .top, spacing: 14) {
                            formField("Username") { TextField(kind == .mongodb ? "Optional" : "Your Oracle user", text: $username) }
                            formField("Password", info: kind == .mongodb ? "Your password stays in macOS Keychain.\n\nMongoDB writes are applied immediately." : "Your password stays in macOS Keychain.\n\nDML uses manual commit. Oracle DDL commits automatically.") { SecureField(connection == nil ? "Your password" : "Leave blank to keep saved", text: $password) }
                        }
                        VStack(alignment: .leading, spacing: 9) {
                            Text("A little color").font(.system(size: 11, weight: .medium))
                            ColorChoices(selection: $color)
                        }
                        if kind == .oracle {
                            DisclosureGroup("Driver libraries", isExpanded: $showLibraries) {
                                VStack(alignment: .leading, spacing: 9) {
                                    Toggle("Bundled orai18n.jar", isOn: $usesBundledInternationalization)
                                        .toggleStyle(.checkbox).font(.system(size: 11))
                                    Text("KO16MSWIN949 등 확장 문자 집합 지원. 연결마다 켜거나 끌 수 있습니다.")
                                        .font(.system(size: 9)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                                    ForEach(additionalJARs, id: \.self) { path in
                                        HStack(spacing: 6) {
                                            Image(systemName: "shippingbox").foregroundStyle(Theme.purple)
                                            Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1).truncationMode(.middle).help(path)
                                            Spacer(minLength: 2)
                                            IconButton(icon: "minus.circle", help: "Remove \(path)") { additionalJARs.removeAll { $0 == path } }
                                        }.font(.system(size: 10))
                                    }
                                    SoftButton(title: "Add JAR…", icon: "plus") { addJARs() }
                                    Text("추가한 파일은 현재 위치에서 불러옵니다.").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                                }.padding(.top, 9)
                            }.font(.system(size: 11, weight: .medium))
                        }
                        if let message = profile.configurationError, !name.isEmpty {
                            Text(message).font(.system(size: 10)).foregroundStyle(Theme.accent("peach"))
                        }
                    }.padding(.trailing, 6).themedScrollbars()
                }.frame(width: 350).disabled(store.isBusy || testing)
                ConnectionDiagnosticsView(connection: profile, attempt: store.connectionAttempts[id])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(height: 510)
            HStack {
                SoftButton(title: testing ? "Testing…" : "Test connection", icon: "bolt") { testConnection() }.disabled(!valid || testing || store.isBusy)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.secondary).keyboardShortcut(.cancelAction).disabled(testing || store.isBusy)
                SoftButton(title: store.isBusy && !testing ? "Connecting…" : "Save & connect", icon: "arrow.right", prominent: true) {
                    Task { _ = await store.saveConnection(profile, password: password) }
                }.disabled(!valid || testing || store.isBusy).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 850).background(Theme.canvas).foregroundStyle(Theme.ink)
            .interactiveDismissDisabled(testing || store.isBusy)
    }

    private func importMongoURI() {
        do {
            let imported = try MongoConnectionURI(mongoConnectionString)
            host = imported.host; port = String(imported.port)
            service = imported.database.isEmpty ? "test" : imported.database
            mongoAuthSource = imported.authSource.isEmpty && imported.database.isEmpty ? "admin" : imported.authSource
            mongoSRV = imported.srv; mongoTLS = imported.tls; mongoReplicaSet = imported.replicaSet
            if let user = imported.username {
                username = user; password = imported.password ?? ""
            }
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = "MongoDB · " + service }
            mongoConnectionString = ""
            mongoImportError = nil
            mongoImportMessage = imported.database.isEmpty ? "URI imported. No database was specified; using test. Credentials stay in the username and password fields." : "URI imported. Review the settings below. Credentials stay in the username and password fields."
        } catch {
            mongoImportMessage = nil
            mongoImportError = error.localizedDescription
        }
    }

    private func testConnection() {
        testing = true
        let target = profile
        Task {
            await store.testConnection(target, password: password)
            testing = false
        }
    }

    private func addJARs() {
        let panel = NSOpenPanel()
        panel.title = "Add connection libraries"
        panel.message = "이 연결에 필요한 Oracle 추가 JAR 파일을 선택해 주세요."
        panel.allowedContentTypes = [UTType(filenameExtension: "jar") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !additionalJARs.contains(path) { additionalJARs.append(path) }
        }
    }

    private func formField<Content: View>(_ title: String, info: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: .medium))
                if let info {
                    Button { showPasswordInfo.toggle() } label: {
                        Image(systemName: "info.circle").font(.system(size: 11)).frame(width: 16, height: 14).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Theme.purple)
                        .help("Password storage information").accessibilityLabel("Password storage information")
                        .popover(isPresented: $showPasswordInfo, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Password storage", systemImage: "lock.shield")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
                                Text(info).font(.system(size: 11)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            }.padding(16).frame(width: 280).foregroundStyle(Theme.ink).background(Theme.canvas)
                        }
                }
            }.frame(height: 14, alignment: .leading)
            content().textFieldStyle(.plain).font(.system(size: 12)).padding(.horizontal, 11).frame(height: 36)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        }
    }
}
