import AppKit
import DBDeepCore
import SwiftUI

struct SQLTextEditor: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    @Binding var selection: String
    @Binding var cursorLocation: Int
    var tables: [SchemaTable]
    var connectionKind: DBConnection.Kind

    init(text: Binding<String>, selection: Binding<String>, cursorLocation: Binding<Int> = .constant(0), tables: [SchemaTable] = [], connectionKind: DBConnection.Kind = .oracle) {
        _text = text
        _selection = selection
        _cursorLocation = cursorLocation
        self.tables = tables
        self.connectionKind = connectionKind
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let view = SQLCompletionTextView(frame: .zero, textContainer: container)
        view.onDismissCompletion = { [weak coordinator = context.coordinator] in coordinator?.dismissCompletion() }
        view.onRequestCompletion = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.updateCompletion(view, explicit: true) }
        }
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = NSColor(Theme.editorText)
        view.backgroundColor = NSColor(Theme.surface)
        view.insertionPointColor = NSColor(Theme.purple)
        view.selectedTextAttributes = [.backgroundColor: NSColor(Theme.tint("lavender"))]
        view.textContainerInset = NSSize(width: 14, height: 22)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        container.widthTracksTextView = true
        view.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.surface)
        scroll.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRuler(textView: view, scrollView: scroll)
        view.string = text
        context.coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if context.coordinator.parent.tables != tables || context.coordinator.parent.connectionKind != connectionKind {
            context.coordinator.dismissCompletion()
        }
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let appearanceChanged = scroll.appearance?.name != appearance?.name
        scroll.appearance = appearance
        if view.string != text {
            context.coordinator.dismissCompletion()
            view.string = text
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.undoManager?.removeAllActions()
            context.coordinator.highlight(view)
        } else if appearanceChanged {
            context.coordinator.dismissCompletion()
            context.coordinator.highlight(view)
        }
        scroll.verticalRulerView?.needsDisplay = true
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.dismissCompletion()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextEditor
        private var completionWork: DispatchWorkItem?
        private var completionPanel: SQLCompletionPanel?
        private(set) var completion: SQLCompletionResult?
        private(set) var selectedCompletion = 0
        private var applyingCompletion = false
        init(_ parent: SQLTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            highlight(view)
            updateSelection(view)
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            if !applyingCompletion { scheduleCompletion(view) }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            updateSelection(view)
            dismissCompletion()
        }

        func textDidEndEditing(_ notification: Notification) { dismissCompletion() }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.complete(_:)) {
                updateCompletion(textView, explicit: true)
                return true
            }
            guard let completion, !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                selectedCompletion = min(selectedCompletion + 1, completion.candidates.count - 1)
                showCompletion(textView)
            case #selector(NSResponder.moveUp(_:)):
                selectedCompletion = max(0, selectedCompletion - 1)
                showCompletion(textView)
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                acceptCompletion(selectedCompletion, in: textView)
            case #selector(NSResponder.cancelOperation(_:)):
                dismissCompletion()
            default:
                return false
            }
            return true
        }

        private func scheduleCompletion(_ view: NSTextView) {
            dismissCompletion()
            let work = DispatchWorkItem { [weak self, weak view] in
                if let view { self?.updateCompletion(view) }
            }
            completionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func updateCompletion(_ view: NSTextView, explicit: Bool = false) {
            dismissCompletion()
            guard !view.hasMarkedText(), view.selectedRange().length == 0 else { return }
            completion = SQLCompletionEngine(tables: parent.tables, kind: parent.connectionKind)
                .completions(in: view.string, atUTF16Offset: view.selectedRange().location, explicit: explicit)
            selectedCompletion = 0
            showCompletion(view)
        }

        private func showCompletion(_ view: NSTextView) {
            guard let completion, view.window?.firstResponder === view, view.window?.isKeyWindow == true else { return }
            let panel = completionPanel ?? SQLCompletionPanel()
            completionPanel = panel
            panel.show(completion, selected: selectedCompletion, for: view, choose: { [weak self, weak view] index in
                if let view { self?.acceptCompletion(index, in: view) }
            }, onDismiss: { [weak self] in self?.dismissCompletion() })
        }

        func acceptCompletion(_ index: Int, in view: NSTextView) {
            guard let completion, completion.candidates.indices.contains(index), !view.hasMarkedText() else { return }
            let insertion = completion.candidates[index].insertion
            let range = completion.range
            dismissCompletion()
            guard NSMaxRange(range) <= (view.string as NSString).length,
                  view.shouldChangeText(in: range, replacementString: insertion) else { return }
            applyingCompletion = true
            defer { applyingCompletion = false }
            view.insertText(insertion, replacementRange: range)
        }

        func dismissCompletion() {
            completionWork?.cancel()
            completionWork = nil
            completion = nil
            completionPanel?.dismiss()
        }

        private func updateSelection(_ view: NSTextView) {
            let range = view.selectedRange()
            let selected = range.length > 0 ? (view.string as NSString).substring(with: range) : ""
            if parent.selection != selected { parent.selection = selected }
            if parent.cursorLocation != range.location { parent.cursorLocation = range.location }
        }
        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttributes([.foregroundColor: NSColor(Theme.editorText), .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)], range: range)
            let rules: [(String, NSColor)] = [
                ("\\b(SELECT|FROM|WHERE|ORDER|BY|GROUP|HAVING|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AS|AND|OR|NOT|NULL|IS|IN|LIKE|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|DROP|ALTER|LIMIT|OFFSET|FETCH|FIRST|ROWS|ONLY|DISTINCT|ASC|DESC|COUNT|SUM|AVG|CASE|WHEN|THEN|ELSE|END|BEGIN|COMMIT|ROLLBACK)\\b", NSColor(Theme.purple)),
                ("\\b[0-9]+(?:\\.[0-9]+)?\\b", NSColor(Theme.sqlNumber)),
                ("'(?:''|[^'])*'", NSColor(Theme.sqlString)),
                ("--[^\\n]*|/\\*[\\s\\S]*?\\*/", NSColor(Theme.sqlComment))
            ]
            for (pattern, color) in rules {
                guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                for match in expression.matches(in: view.string, range: range) { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
            }
            storage.endEditing()
            view.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(Theme.editorText)]
        }
    }
}

final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(Theme.surface).setFill(); bounds.fill()
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
        let string = view.string as NSString
        let visible = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
        var line = 1
        var index = 0
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(Theme.lineNumber)]
        while index < string.length {
            let glyph = layout.glyphIndexForCharacter(at: min(index, max(0, string.length - 1)))
            if glyph >= visible.location && glyph <= NSMaxRange(visible) {
                let lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let y = lineRect.minY + view.textContainerInset.height - view.visibleRect.minY + 1
                let label = "\(line)" as NSString
                label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 9, y: y), withAttributes: attributes)
            }
            let next = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
            if next <= index { break }
            index = next; line += 1
        }
        if string.length == 0 || view.string.hasSuffix("\n") {
            let y = layout.extraLineFragmentRect.minY + view.textContainerInset.height - view.visibleRect.minY + 1
            let label = "\(line)" as NSString
            label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 9, y: y), withAttributes: attributes)
        }
    }
}
