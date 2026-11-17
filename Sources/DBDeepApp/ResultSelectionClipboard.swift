import AppKit
import UniformTypeIdentifiers

@MainActor
enum ResultSelectionClipboard {
    static func write(_ text: String, format: ResultSelectionFormat, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        let type: NSPasteboard.PasteboardType = format == .tsv ? .tabularText : .init(UTType.commaSeparatedText.identifier)
        guard item.setString(text, forType: .string), item.setString(text, forType: type) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
