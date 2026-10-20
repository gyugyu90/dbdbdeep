import AppKit
import DBDeepCore

@MainActor
enum QueryResultExporter {
    static func export(_ result: QueryResult) throws -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "query-result.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try result.csv.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
