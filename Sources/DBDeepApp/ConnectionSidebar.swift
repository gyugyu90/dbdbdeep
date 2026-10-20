import SwiftUI
import DBDeepCore

struct ConnectionSidebar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Theme.secondary)
                Spacer()
                CapsuleTag(text: "PERSONAL", color: "lavender")
            }.padding(.horizontal, 18).padding(.top, 25).padding(.bottom, 23)
            Text("Connections").font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 8)
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
                .contentShape(Rectangle())
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
