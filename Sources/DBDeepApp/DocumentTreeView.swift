import AppKit
import SwiftUI
import DBDeepCore

@MainActor
final class DocumentTreeNode {
    let id: String
    let name: String
    let path: String
    private let rawJSON: String?
    private var cachedValue: DocumentValue?
    private var cachedChildren: [DocumentTreeNode]?
    private(set) var loadError: String?

    init(document: String, index: Int) {
        id = String(index); name = "Document \(index + 1)"; path = "$[\(index)]"
        rawJSON = document
    }

    private init(id: String, name: String, path: String, value: DocumentValue) {
        self.id = id; self.name = name; self.path = path
        cachedValue = value; rawJSON = nil
    }

    var typeName: String { rawJSON == nil ? cachedValue?.typeName ?? "Object" : "Document" }
    var kind: DocumentValue.Kind { cachedValue?.kind ?? .object }
    var preview: String { loadError ?? cachedValue?.displayValue ?? "{ … }" }
    var isExpandable: Bool { loadError == nil && (cachedValue.map { $0.childCount > 0 } ?? true) }

    var children: [DocumentTreeNode] {
        if let cachedChildren { return cachedChildren }
        loadValue()
        let array = cachedValue?.kind == .array
        let children = (cachedValue?.children ?? []).enumerated().map { index, child in
            let key = String(decoding: (try? JSONEncoder().encode(child.name)) ?? Data(), as: UTF8.self)
            return DocumentTreeNode(id: id + "/\(index)", name: child.name,
                path: path + (array ? child.name : "[\(key)]"), value: child.value)
        }
        cachedChildren = children
        return children
    }

    var detailSource: DocumentDetailSource {
        if let rawJSON, let cachedValue { return .document(rawJSON, cachedValue) }
        return cachedValue.map(DocumentDetailSource.value) ?? .json(rawJSON ?? "")
    }

    private func loadValue() {
        guard cachedValue == nil, loadError == nil, let rawJSON else { return }
        do { cachedValue = try DocumentValue(json: rawJSON) }
        catch { loadError = "Unable to read document: \(error.localizedDescription)" }
    }
}

struct DocumentTreeView: View {
    let resultID: UUID
    let documents: [String]
    let indices: [Int]
    @State private var selected: DocumentTreeNode?
    @State private var collapseID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Expand objects and arrays to explore").foregroundStyle(Theme.secondary)
                Spacer()
                Button("Collapse all") { collapseID = UUID() }.buttonStyle(.plain).foregroundStyle(Theme.purple)
                    .disabled(indices.isEmpty)
            }.font(.system(size: 10)).padding(.horizontal, 17).frame(height: 30).background(Theme.canvas)
            if indices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 24)).foregroundStyle(Theme.purple)
                    Text(documents.isEmpty ? "No documents returned." : "No documents match this filter.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DocumentOutline(documents: documents, indices: indices, resultID: resultID, collapseID: collapseID, selected: $selected)
            }
            if let selected {
                DocumentInspector(node: selected, close: { self.selected = nil })
            }
        }.background(Theme.surface)
    }
}

private struct DocumentInspector: View {
    let node: DocumentTreeNode
    let close: () -> Void
    @StateObject private var detail = DocumentDetailModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(node.path).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(node.path)
                CapsuleTag(text: node.typeName, color: "mint")
                Spacer(minLength: 0)
                Button { Task { await detail.copy() } } label: {
                    Label(detail.isCopying ? "Copying…" : detail.copied ? "Copied" : "Copy value",
                          systemImage: detail.copied ? "checkmark.circle.fill" : "doc.on.doc")
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(detail.copied ? Theme.green : Theme.purple)
                    .disabled(detail.selectionID != node.id || detail.isCopying)
                IconButton(icon: "xmark", help: "Close value details", action: close)
            }
            Group {
                if detail.selectionID != node.id || detail.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing preview…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        Text(detail.preview?.text ?? detail.error ?? "").font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading).themedScrollbars()
                    }
                }
            }.frame(height: 86)
            if detail.preview?.isTruncated == true {
                Text("Preview shortened · Expand branches to explore · Copy value includes the full value")
                    .font(.system(size: 9)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(Theme.canvas)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
            .task(id: node.id) { await detail.load(node.detailSource, id: node.id) }
            .onDisappear { detail.cancel() }
            .task(id: detail.copied) {
                guard detail.copied else { return }
                do { try await Task.sleep(for: .seconds(1.3)) } catch { return }
                detail.resetCopied()
            }
    }
}

private struct DocumentOutline: NSViewRepresentable {
    let documents: [String]
    let indices: [Int]
    let resultID: UUID
    let collapseID: UUID
    @Binding var selected: DocumentTreeNode?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document"))
        column.minWidth = 280; column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.indentationPerLevel = 18
        outline.rowHeight = 30
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.style = .plain
        outline.focusRingType = .none
        outline.backgroundColor = NSColor(Theme.surface)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.toggleSelected)
        outline.setAccessibilityLabel("Document tree")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.surface)
        context.coordinator.observeViewport(scroll, outline: outline)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let outline = scroll.documentView as? NSOutlineView else { return }
        context.coordinator.update(outline)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.stopObserving() }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: DocumentOutline
        var scrollbar: ScrollbarController?
        private var frameObserver: NSObjectProtocol?
        private var roots: [DocumentTreeNode] = []
        private var cache: [Int: DocumentTreeNode] = [:]
        private var resultID: UUID?
        private var indices: [Int] = []
        private var collapseID: UUID?
        private var expanded: Set<String> = []
        private var reloading = false

        init(_ parent: DocumentOutline) { self.parent = parent }

        deinit { if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) } }

        func observeViewport(_ scroll: NSScrollView, outline: NSOutlineView) {
            scrollbar = ScrollbarController(scroll)
            scroll.contentView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak outline] _ in
                MainActor.assumeIsolated {
                    guard let outline, outline.selectedRow >= 0 else { return }
                    outline.scrollRowToVisible(outline.selectedRow)
                }
            }
        }

        func stopObserving() {
            scrollbar = nil
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            frameObserver = nil
        }

        func update(_ outline: NSOutlineView) {
            if resultID != parent.resultID || indices != parent.indices {
                let isNew = resultID != parent.resultID
                if isNew { cache = [:]; expanded = [] }
                resultID = parent.resultID; indices = parent.indices
                roots = indices.compactMap { index in
                    guard parent.documents.indices.contains(index) else { return nil }
                    if let cached = cache[index] { return cached }
                    let node = DocumentTreeNode(document: parent.documents[index], index: index)
                    cache[index] = node
                    return node
                }
                reloading = true
                outline.reloadData()
                for node in roots { restoreExpansion(node, in: outline) }
                if isNew, let first = roots.first {
                    outline.expandItem(first)
                    expanded.insert(first.id)
                }
                reloading = false
                if let selected = parent.selected {
                    let row = outline.row(forItem: selected)
                    if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                    else { DispatchQueue.main.async { [weak self] in self?.parent.selected = nil } }
                }
            }
            if collapseID != parent.collapseID {
                if collapseID != nil { outline.collapseItem(nil, collapseChildren: true); expanded = [] }
                collapseID = parent.collapseID
            }
        }

        private func restoreExpansion(_ node: DocumentTreeNode, in outline: NSOutlineView) {
            guard expanded.contains(node.id) else { return }
            outline.expandItem(node)
            for child in node.children { restoreExpansion(child, in: outline) }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? DocumentTreeNode)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? DocumentTreeNode)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? DocumentTreeNode)?.isExpandable == true }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? DocumentTreeNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("DocumentTreeCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? DocumentTreeCell ?? DocumentTreeCell()
            cell.identifier = identifier
            cell.configure(node)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { DocumentTreeRow() }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !reloading, let outline = notification.object as? NSOutlineView else { return }
            parent.selected = outline.item(atRow: outline.selectedRow) as? DocumentTreeNode
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !reloading, let node = notification.userInfo?["NSObject"] as? DocumentTreeNode else { return }
            expanded.insert(node.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !reloading, let node = notification.userInfo?["NSObject"] as? DocumentTreeNode else { return }
            expanded.remove(node.id)
        }

        @objc func toggleSelected(_ outline: NSOutlineView) {
            guard let node = outline.item(atRow: outline.clickedRow) as? DocumentTreeNode, node.isExpandable else { return }
            if outline.isItemExpanded(node) { outline.collapseItem(node) }
            else { outline.expandItem(node) }
        }
    }
}

private final class DocumentTreeCell: NSTableCellView {
    private let key = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let type = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        key.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        type.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        for field in [key, value, type] { field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1 }
        key.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        type.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [key, value, type])
        stack.orientation = .horizontal; stack.spacing = 10; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            key.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ node: DocumentTreeNode) {
        key.stringValue = node.name
        value.stringValue = node.preview
        type.stringValue = node.typeName
        key.textColor = NSColor(Theme.ink)
        type.textColor = NSColor(Theme.secondary)
        value.textColor = NSColor(node.kind == .string ? Theme.sqlString : node.kind == .null ? Theme.secondary : node.kind == .bson || node.kind == .number ? Theme.sqlNumber : Theme.purple)
        toolTip = String(node.preview.prefix(512))
        setAccessibilityIdentifier("document-node-" + node.id)
    }
}

private final class DocumentTreeRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(Theme.selectedRow).setFill()
        bounds.fill()
    }
}
