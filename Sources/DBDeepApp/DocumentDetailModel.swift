import AppKit
import Combine
import DBDeepCore

enum DocumentDetailSource: Sendable {
    case json(String), document(String, DocumentValue), value(DocumentValue)

    func preview() async throws -> DocumentPreview {
        try await background {
            switch self {
            case .json(let text): return try DocumentValue(json: text).preview()
            case .document(_, let value): return try value.preview()
            case .value(let value): return try value.preview()
            }
        }
    }

    func copyText() async throws -> String {
        try await background {
            switch self {
            case .json(let text): return text
            case .document(let text, _): return text
            case .value(let value): return value.copyText
            }
        }
    }

    private func background<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try operation()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

@MainActor
final class DocumentDetailModel: ObservableObject {
    @Published private(set) var preview: DocumentPreview?
    @Published private(set) var selectionID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isCopying = false
    @Published private(set) var copied = false
    @Published private(set) var error: String?
    private var source: DocumentDetailSource?
    private var generation = UUID()
    private let renderPreview: @Sendable (DocumentDetailSource) async throws -> DocumentPreview
    private let renderCopy: @Sendable (DocumentDetailSource) async throws -> String
    private let writeClipboard: (String) -> Bool

    init(renderPreview: @escaping @Sendable (DocumentDetailSource) async throws -> DocumentPreview = { try await $0.preview() },
         renderCopy: @escaping @Sendable (DocumentDetailSource) async throws -> String = { try await $0.copyText() },
         writeClipboard: @escaping (String) -> Bool = {
             NSPasteboard.general.clearContents()
             return NSPasteboard.general.setString($0, forType: .string)
         }) {
        self.renderPreview = renderPreview; self.renderCopy = renderCopy; self.writeClipboard = writeClipboard
    }

    func load(_ source: DocumentDetailSource, id: String) async {
        generation = UUID()
        let request = generation
        self.source = source; selectionID = id
        preview = nil; error = nil; copied = false; isCopying = false; isLoading = true
        do {
            let rendered = try await renderPreview(source)
            guard request == generation, !Task.isCancelled else { return }
            preview = rendered
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if request == generation { isLoading = false }
    }

    func copy() async {
        guard !isCopying, let source else { return }
        let request = generation
        isCopying = true; copied = false; error = nil
        do {
            let text = try await renderCopy(source)
            guard request == generation, !Task.isCancelled else { return }
            copied = writeClipboard(text)
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if request == generation { isCopying = false }
    }

    func resetCopied() { copied = false }
    func cancel() { generation = UUID(); source = nil; isLoading = false; isCopying = false }
}
