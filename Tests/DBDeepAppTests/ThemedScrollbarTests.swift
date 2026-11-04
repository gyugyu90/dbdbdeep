import AppKit
import DBDeepCore
import SwiftUI
import XCTest
@testable import DBDeepApp

@MainActor
final class ThemedScrollbarTests: XCTestCase {
    func testScrollingExpandsOnlyTheMovingAxisAndReturnsToIdleWithoutRelayout() async throws {
        let scroll = makeScrollView()
        let controller = ScrollbarController(scroll)
        defer { withExtendedLifetime(controller) {} }
        let vertical = try XCTUnwrap(scroll.verticalScroller as? ThemedScroller)
        let horizontal = try XCTUnwrap(scroll.horizontalScroller as? ThemedScroller)
        let viewport = scroll.contentSize
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertTrue(vertical.isActive)
        XCTAssertFalse(horizontal.isActive)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(vertical.knobThickness, 8, accuracy: 0.1)
        XCTAssertEqual(horizontal.knobThickness, 4, accuracy: 0.1)
        XCTAssertEqual(scroll.contentSize, viewport)
        try await Task.sleep(for: .milliseconds(400))
        scroll.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + 240))
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(vertical.isActive)
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertFalse(vertical.isActive)
        XCTAssertEqual(vertical.knobThickness, 4, accuracy: 0.1)
        XCTAssertEqual(scroll.contentSize, viewport)
    }

    func testLiveScrollKeepsExpandedUntilOneSecondAfterEnd() async throws {
        let scroll = makeScrollView()
        let controller = ScrollbarController(scroll)
        defer { withExtendedLifetime(controller) {} }
        let horizontal = try XCTUnwrap(scroll.horizontalScroller as? ThemedScroller)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: origin.x + 120, y: origin.y))
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertTrue(horizontal.isActive)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertFalse(horizontal.isActive)
        XCTAssertEqual(horizontal.knobThickness, 4, accuracy: 0.1)
    }

    func testSwiftUIScrollViewInstallsBothNativeScrollbars() async throws {
        let content = ScrollView([.horizontal, .vertical]) {
            Color.clear.frame(width: 1500, height: 1500).themedScrollbars()
        }
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendantScrollView(in: host))
        XCTAssertTrue(scroll.verticalScroller is ThemedScroller)
        XCTAssertTrue(scroll.horizontalScroller is ThemedScroller)
        XCTAssertTrue(scroll.verticalScroller?.isEnabled == true)
        XCTAssertTrue(scroll.horizontalScroller?.isEnabled == true)
        XCTAssertLessThan(scroll.verticalScroller?.knobProportion ?? 1, 1)
        XCTAssertEqual(scroll.scrollerStyle, .legacy)
    }

    func testSQLTextEditorUsesTheSameScrollbarAndKeepsRuler() throws {
        let editor = SQLTextEditor(text: .constant(String(repeating: "SELECT 1;\n", count: 200)), selection: .constant(""))
        let coordinator = SQLTextEditor.Coordinator(editor)
        let scroll = editor.makeScrollView(coordinator: coordinator)
        defer { coordinator.stopObserving() }
        XCTAssertTrue(scroll.verticalScroller is ThemedScroller)
        XCTAssertTrue(scroll.verticalRulerView is LineNumberRuler)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller)
    }

    func testLazyResultGridKeepsThemedScrollbarsAfterRendering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let id = try XCTUnwrap(store.selectedID)
        store.results[id] = QueryResult(columns: ["name", "email", "status"], rows: (1...100).map { ["Row \($0)", "row\($0)@example.com", "active"] })
        let host = NSHostingView(rootView: ResultsView().environmentObject(store))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(descendantScrollView(in: host))
        XCTAssertTrue(scroll.verticalScroller is ThemedScroller, "\(String(describing: scroll.verticalScroller))")
        XCTAssertTrue(scroll.horizontalScroller is ThemedScroller, "\(String(describing: scroll.horizontalScroller))")
    }

    func testFrameworkReplacingScrollbarsDoesNotLoseTheme() async throws {
        let scroll = makeScrollView()
        let controller = ScrollbarController(scroll)
        defer { withExtendedLifetime(controller) {} }
        scroll.verticalScroller = NSScroller()
        scroll.horizontalScroller = NSScroller()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(scroll.verticalScroller is ThemedScroller)
        XCTAssertTrue(scroll.horizontalScroller is ThemedScroller)
        XCTAssertTrue(scroll.verticalScroller?.isEnabled == true)
        XCTAssertTrue(scroll.horizontalScroller?.isEnabled == true)
        XCTAssertLessThan(scroll.verticalScroller?.knobProportion ?? 1, 1)
    }

    func testGridViewportReservesSpaceOnlyForNeededScrollbars() {
        let frame = NSSize(width: 400, height: 300)
        let gutter = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        XCTAssertEqual(ScrollbarController.viewportSize(content: NSSize(width: 200, height: 100), in: frame), frame)
        XCTAssertEqual(ScrollbarController.viewportSize(content: NSSize(width: 500, height: 100), in: frame), NSSize(width: 400, height: 300 - gutter))
        XCTAssertEqual(ScrollbarController.viewportSize(content: NSSize(width: 200, height: 500), in: frame), NSSize(width: 400 - gutter, height: 300))
        XCTAssertEqual(ScrollbarController.viewportSize(content: NSSize(width: 400 - gutter / 2, height: 500), in: frame), NSSize(width: 400 - gutter, height: 300 - gutter))
        let scroll = makeScrollView()
        let controller = ScrollbarController(scroll)
        defer { withExtendedLifetime(controller) {} }
        XCTAssertEqual(ScrollbarController.viewportSize(content: NSSize(width: 2000, height: 2000), in: frame), scroll.contentSize)
    }

    private func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 2000))
        return scroll
    }

    private func descendantScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.descendantScrollView(in: $0) }.first
    }
}
