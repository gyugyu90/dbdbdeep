import SwiftUI
import DBDeepCore

struct SchemaColumnRow: View {
    let column: SchemaColumn

    private var comment: String? {
        guard let text = column.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private var tooltip: String {
        let details = "\(column.name) · \(column.type) · \(column.nullable ? "nullable" : "not null")"
        return details + (comment.map { "\n\n" + $0 } ?? "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: column.primaryKey ? "key.horizontal" : "number")
                .font(.system(size: 9))
                .foregroundStyle(column.primaryKey ? Theme.accent("yellow") : Theme.secondary.opacity(0.7))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(column.name).font(.system(size: 10)).lineLimit(1)
                    Spacer(minLength: 3)
                    Text(column.type.lowercased()).font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.secondary).lineLimit(1)
                }
                if let comment {
                    Text(comment).font(.system(size: 9)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 39).padding(.trailing, 12).padding(.vertical, 6)
        .frame(minHeight: 26, alignment: .leading)
        .contentShape(Rectangle())
        .help(tooltip)
        .accessibilityElement(children: .combine)
    }
}
