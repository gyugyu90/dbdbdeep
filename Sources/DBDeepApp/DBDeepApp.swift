import SwiftUI

@main
struct DBDeepApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var commandKeyboard = CommandKeyboard()
    @AppStorage("appearanceMode") private var appearanceMode: AppAppearance = .system
    var body: some Scene {
        Window("dbdbdeep", id: "workspace") {
            WorkspaceView().environmentObject(store)
                .onAppear { _ = commandKeyboard }
                .onChange(of: appearanceMode, initial: true) { _, mode in mode.apply() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 850)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Database Connection…") { store.newConnection() }.keyboardShortcut("n", modifiers: .command).disabled(store.isBusy)
            }
            CommandMenu("Query") {
                Button(store.selectedSQL.isEmpty ? "Run statement" : "Run selection") { Task { await store.run() } }
                    .keyboardShortcut(KeyEquivalent("\u{3}"), modifiers: .command).disabled(!store.canRunQuery)
                Divider()
                Button("Commit changes") { Task { await store.transaction(commit: true) } }.keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(!store.canUseTransactions)
                Button("Rollback changes") { Task { await store.transaction(commit: false) } }.disabled(!store.canUseTransactions)
                Divider()
                Button(store.canExportAllQueryRows ? "Export all query rows as CSV…" : "Export fetched rows as CSV…") { Task { await store.exportCSV() } }
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!store.canExportFetchedRows)
                Button("Refresh schema") { Task { await store.refreshSchema() } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!store.isConnected || store.isBusy)
            }
            CommandGroup(after: .sidebar) {
                Menu("Appearance") {
                    Picker("Appearance", selection: $appearanceMode) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }.pickerStyle(.inline)
                }
            }
        }
    }
}
