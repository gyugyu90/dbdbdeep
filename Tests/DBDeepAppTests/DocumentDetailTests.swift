import XCTest
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class DocumentDetailTests: XCTestCase {
    func testSlowPreviewAllowsOtherSelectionsAndCannotReplaceTheirDetails() async throws {
        let gate = DetailGate<DocumentPreview>()
        let model = DocumentDetailModel(renderPreview: { source in
            if case .json("slow") = source { return await gate.wait() }
            return DocumentPreview(text: "latest", isTruncated: false)
        })
        let first = Task { await model.load(.json("slow"), id: "old") }
        await gate.waitUntilStarted()
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.preview)
        await model.load(.json("fast"), id: "new")
        XCTAssertEqual(model.preview?.text, "latest")
        XCTAssertFalse(model.isLoading)
        await gate.finish(DocumentPreview(text: "stale", isTruncated: true))
        await first.value
        XCTAssertEqual(model.selectionID, "new")
        XCTAssertEqual(model.preview?.text, "latest")
    }

    func testCopyIsOnDemandAndDoesNotWriteStaleSelectionToClipboard() async throws {
        let gate = DetailGate<String>()
        var clipboard: [String] = []
        let model = DocumentDetailModel(renderCopy: { _ in await gate.wait() }, writeClipboard: { clipboard.append($0); return true })
        await model.load(.json("{\"name\":\"first\"}"), id: "first")
        XCTAssertTrue(clipboard.isEmpty)
        let copy = Task { await model.copy() }
        await gate.waitUntilStarted()
        XCTAssertTrue(model.isCopying)
        await model.load(.json("{\"name\":\"second\"}"), id: "second")
        await gate.finish("old value")
        await copy.value
        XCTAssertTrue(clipboard.isEmpty)
        XCTAssertFalse(model.isCopying)
        XCTAssertFalse(model.copied)
    }

    func testLargePreviewAndFullCopyKeepSeparateSizeLimits() async throws {
        let text = String(repeating: "한글🌷", count: 100_000)
        let json = "{\"payload\":" + String(decoding: try JSONEncoder().encode(text), as: UTF8.self) + "}"
        let node = DocumentTreeNode(document: json, index: 0)
        var clipboard = ""
        let model = DocumentDetailModel(writeClipboard: { clipboard = $0; return true })
        await model.load(node.detailSource, id: node.id)
        XCTAssertTrue(model.preview?.isTruncated == true)
        XCTAssertLessThanOrEqual(try XCTUnwrap(model.preview).text.utf16.count, 4_096)
        XCTAssertEqual(node.preview, "{ … }")
        XCTAssertTrue(clipboard.isEmpty)
        await model.copy()
        XCTAssertEqual(clipboard, json)
        XCTAssertTrue(model.copied)
        XCTAssertFalse(model.isCopying)
        _ = node.children
        await model.load(node.detailSource, id: node.id)
        await model.copy()
        XCTAssertEqual(clipboard, json)
    }

    func testClosingInspectorDiscardsPendingPreviewAndCopy() async {
        let gate = DetailGate<DocumentPreview>()
        let model = DocumentDetailModel(renderPreview: { _ in await gate.wait() })
        let pending = Task { await model.load(.json("{}"), id: "first") }
        await gate.waitUntilStarted()
        model.cancel()
        await gate.finish(DocumentPreview(text: "late", isTruncated: false))
        await pending.value
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.isLoading)
    }
}

private actor DetailGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume(); started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}
