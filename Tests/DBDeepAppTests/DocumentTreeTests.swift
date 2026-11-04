import XCTest
import AppKit
import SwiftUI
import DBDeepCore
@testable import DBDeepApp

@MainActor
final class DocumentTreeTests: XCTestCase {
    func testDocumentNodesLoadLazilyAndKeepStablePathsForSpecialKeys() async throws {
        let node = DocumentTreeNode(document: #"{"_id":{"$oid":"507f1f77bcf86cd799439011"},"a.b":[{"x\"y":null}],"empty":{}}"#, index: 2)
        XCTAssertEqual(node.name, "Document 3")
        XCTAssertEqual(node.preview, "{ … }")
        XCTAssertTrue(node.isExpandable)
        let children = node.children
        XCTAssertEqual(children.first?.name, "_id")
        XCTAssertEqual(children.first?.typeName, "ObjectId")
        XCTAssertFalse(try XCTUnwrap(children.first).isExpandable)
        let array = try XCTUnwrap(children.first { $0.name == "a.b" })
        XCTAssertEqual(array.path, #"$[2]["a.b"]"#)
        let leaf = try XCTUnwrap(array.children.first?.children.first)
        XCTAssertEqual(leaf.path, #"$[2]["a.b"][0]["x\"y"]"#)
        let copied = try await leaf.detailSource.copyText()
        XCTAssertEqual(copied, "null")
        XCTAssertTrue(node.children[1] === children[1])
        XCTAssertNotEqual(leaf.id, array.id)
        XCTAssertFalse(try XCTUnwrap(children.first { $0.name == "empty" }).isExpandable)
    }

    func testInvalidAndEmptyDocumentsRemainInspectableWithoutCrashing() async throws {
        let empty = DocumentTreeNode(document: "{}", index: 0)
        XCTAssertTrue(empty.children.isEmpty)
        XCTAssertFalse(empty.isExpandable)
        XCTAssertEqual(empty.typeName, "Document")
        let invalid = DocumentTreeNode(document: "{unfinished", index: 1)
        XCTAssertTrue(invalid.children.isEmpty)
        XCTAssertNotNil(invalid.loadError)
        let copied = try await invalid.detailSource.copyText()
        XCTAssertEqual(copied, "{unfinished")
    }

    func testTableAndTreeFilteringUsesWholeDocumentBeyondCellPreviews() {
        let result = QueryResult(columns: ["nested"], rows: [["truncated preview"], [nil]], documents: [#"{"nested":{"deepKey":"hidden-value"}}"#, #"{"other":null}"#])
        var grid = ResultGridState()
        grid.reset(for: result)
        XCTAssertEqual(grid.rows(in: result, filter: "hidden-value").map(\.offset), [0])
        XCTAssertEqual(grid.rows(in: result, filter: "DEEPKEY").map(\.offset), [0])
        XCTAssertEqual(grid.rows(in: result, filter: "other").map(\.offset), [1])
    }

    func testNativeOutlineExpandsNestedArraysAndKeepsExpansionWhenFiltering() async throws {
        let documents = [#"{"profile":{"city":"Seoul"},"items":[{"name":"first"}]}"#, #"{"other":true}"#]
        let id = UUID()
        let host = NSHostingView(rootView: DocumentTreeView(resultID: id, documents: documents, indices: [0, 1]))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let outline = try XCTUnwrap(findOutline(in: host))
        let root = try XCTUnwrap(outline.item(atRow: 0) as? DocumentTreeNode)
        XCTAssertTrue(outline.isItemExpanded(root))
        let profile = try XCTUnwrap(root.children.first { $0.name == "profile" })
        outline.expandItem(profile)
        XCTAssertGreaterThanOrEqual(outline.row(forItem: profile.children.first!), 0)
        let items = try XCTUnwrap(root.children.first { $0.name == "items" })
        outline.expandItem(items)
        outline.expandItem(items.children.first!)
        XCTAssertGreaterThanOrEqual(outline.row(forItem: items.children.first!.children.first!), 0)
        host.rootView = DocumentTreeView(resultID: id, documents: documents, indices: [0])
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(outline.isItemExpanded(profile))
        XCTAssertTrue(outline.isItemExpanded(items))
        XCTAssertTrue(outline.enclosingScrollView?.verticalScroller is ThemedScroller)
        outline.collapseItem(root, collapseChildren: true)
        XCTAssertEqual(outline.numberOfRows, 1)
        outline.expandItem(root)
        XCTAssertEqual(outline.numberOfRows, 3)
    }

    private func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap { self.findOutline(in: $0) }.first
    }
}
