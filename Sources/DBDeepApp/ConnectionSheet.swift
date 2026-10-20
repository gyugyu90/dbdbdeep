import SwiftUI
import UniformTypeIdentifiers
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
    @State private var testing = false
    @State private var usesBundledInternationalization: Bool
    @State private var additionalJARs: [String]
    @State private var showLibraries = true
    @State private var showPasswordInfo = false
    @State private var id: UUID

    init(connection: DBConnection?) {
        self.connection = connection
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
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (1...65535).contains(Int(port) ?? 0) && !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!password.isEmpty || connection != nil)
    }
    private var profile: DBConnection {
        DBConnection(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 1521, service: service.trimmingCharacters(in: .whitespacesAndNewlines), username: username.trimmingCharacters(in: .whitespacesAndNewlines), usesSID: usesSID, color: color, usesBundledInternationalization: usesBundledInternationalization, additionalJARs: additionalJARs)
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
            HStack(alignment: .top, spacing: 22) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
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
                            formField("Password", info: "Your password stays in macOS Keychain.\n\nDML uses manual commit. Oracle DDL commits automatically.") { SecureField(connection == nil ? "Your password" : "Leave blank to keep saved", text: $password) }
                        }
                        VStack(alignment: .leading, spacing: 9) {
                            Text("A little color").font(.system(size: 11, weight: .medium))
                            ColorChoices(selection: $color)
                        }
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
                    }.padding(.trailing, 6)
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
