import SwiftUI

@main
struct DBDeepApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        Window("dbdbdeep", id: "workspace") {
            WorkspaceView().environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 850)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Oracle Connection…") { store.newConnection() }.keyboardShortcut("n", modifiers: .command).disabled(store.isBusy)
            }
            CommandMenu("Query") {
                Button("Commit changes") { Task { await store.transaction(commit: true) } }.keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(!store.isConnected || store.isBusy)
                Button("Rollback changes") { Task { await store.transaction(commit: false) } }.disabled(!store.isConnected || store.isBusy)
                Divider()
                Button("Export result as CSV…") { store.exportCSV() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(store.result?.columns.isEmpty != false)
                Button("Refresh schema") { Task { await store.refreshSchema() } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!store.isConnected || store.isBusy)
            }
        }
    }
}
