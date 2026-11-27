import AppKit
import DBDeepCore

enum QueryExportScope { case allQueryRows, fetchedRows }

@MainActor
enum QueryResultExporter {
    static func destination(scope: QueryExportScope) -> URL? {
        let panel = NSSavePanel()
        panel.title = scope == .allQueryRows ? "Export all query rows" : "Export fetched rows"
        panel.message = scope == .allQueryRows
            ? "The original SELECT runs again on this connection. Every row it returns is saved; limits written in the query still apply."
            : "Save the rows already fetched into Results. The query will not run again."
        panel.nameFieldStringValue = "query-result.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
