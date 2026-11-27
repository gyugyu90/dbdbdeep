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
    var focusRequest: SQLEditorFocus?
    var findRequest: UUID?
    var completionContextID: UUID?
    var loadMongoFields: (String) async -> [SchemaColumn]

    init(text: Binding<String>, selection: Binding<String>, cursorLocation: Binding<Int> = .constant(0), tables: [SchemaTable] = [], connectionKind: DBConnection.Kind = .oracle, focusRequest: SQLEditorFocus? = nil, findRequest: UUID? = nil, completionContextID: UUID? = nil, loadMongoFields: @escaping (String) async -> [SchemaColumn] = { _ in [] }) {
        _text = text
        _selection = selection
        _cursorLocation = cursorLocation
        self.tables = tables
        self.connectionKind = connectionKind
        self.focusRequest = focusRequest
        self.findRequest = findRequest
        self.completionContextID = completionContextID
        self.loadMongoFields = loadMongoFields
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let view = SQLCompletionTextView(frame: .zero, textContainer: container)
        view.onDismissCompletion = { [weak coordinator] in coordinator?.dismissCompletion() }
        view.onRequestCompletion = { [weak coordinator, weak view] in
            if let view { coordinator?.updateCompletion(view, explicit: true) }
        }
        view.onTypeCompletion = { [weak coordinator, weak view] in
            if let view { coordinator?.scheduleCompletion(view) }
        }
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.findController = SQLTextFinder(editor: view)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = NSColor(Theme.editorText)
        view.backgroundColor = NSColor(Theme.surface)
        view.insertionPointColor = NSColor(Theme.purple)
        view.selectedTextAttributes = [.backgroundColor: NSColor(Theme.tint("lavender"))]
        view.textContainerInset = NSSize(width: 14, height: 22)
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        container.widthTracksTextView = true
        view.delegate = coordinator
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.findBarPosition = .aboveContent
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.surface)
        scroll.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRuler(textView: view, scrollView: scroll)
        coordinator.replaceText(in: view, with: text)
        coordinator.observeScrolling(scroll)
        coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if context.coordinator.parent.tables != tables || context.coordinator.parent.connectionKind != connectionKind || context.coordinator.parent.completionContextID != completionContextID {
            context.coordinator.dismissCompletion()
        }
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let appearanceChanged = scroll.appearance?.name != appearance?.name
        scroll.appearance = appearance
        if view.string != text {
            context.coordinator.dismissCompletion()
            context.coordinator.replaceText(in: view, with: text)
            view.undoManager?.removeAllActions()
            context.coordinator.highlight(view)
        } else if appearanceChanged {
            context.coordinator.dismissCompletion()
            context.coordinator.highlight(view)
        }
        scroll.verticalRulerView?.needsDisplay = true
        context.coordinator.scheduleFocus(in: view)
        context.coordinator.scheduleFind(in: view)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextEditor
        private var completionWork: DispatchWorkItem?
        private var completionTask: Task<Void, Never>?
        private var completionPanel: SQLCompletionPanel?
        private(set) var completion: SQLCompletionResult?
        private(set) var selectedCompletion = 0
        private var applyingCompletion = false
        private var synchronizingSelection = false
        private var applyingLimit = false
        private var boundsObserver: NSObjectProtocol?
        private var scrollbarController: ScrollbarController?
        private var highlightWork: DispatchWorkItem?
        private var highlightTask: Task<Void, Never>?
        private var highlightID = UUID()
        private var syntaxMatches: SQLSyntaxHighlighter.Matches?
        private let syntaxRules = SQLSyntaxHighlighter.rules
        private var completionID = UUID()
        private let analysisQueue = DispatchQueue(label: "studio.dbdbdeep.sql-analysis", qos: .userInitiated)
        var onTruncate: (() -> Void)?
        private var showingLimitAlert = false
        private var scheduledFocusID: UUID?
        private var scheduledFindID: UUID?
        private(set) var appliedFocusID: UUID?
        init(_ parent: SQLTextEditor) { self.parent = parent }

        deinit {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            highlightWork?.cancel()
            highlightTask?.cancel()
            completionWork?.cancel()
            completionTask?.cancel()
        }

        func observeScrolling(_ scroll: NSScrollView) {
            scrollbarController = ScrollbarController(scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                guard let view = scroll?.documentView as? NSTextView else { return }
                self?.highlightVisibleText(view)
                scroll?.verticalRulerView?.needsDisplay = true
            }
        }

        func stopObserving() {
            scrollbarController = nil
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            boundsObserver = nil
            highlightID = UUID()
            highlightWork?.cancel()
            highlightTask?.cancel()
            dismissCompletion()
        }

        func replaceText(in view: NSTextView, with text: String) {
            synchronizingSelection = true
            defer { synchronizingSelection = false }
            let limited = SQLLineIndex(text).truncated(text)
            view.string = limited ?? text
            view.setSelectedRange(NSRange(location: 0, length: 0))
            if let limited {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, self.parent.text == text else { return }
                    self.parent.text = limited
                    self.notifyTruncation(in: view)
                }
            }
        }

        func scheduleFocus(in view: NSTextView) {
            guard let request = parent.focusRequest, request.id != scheduledFocusID else { return }
            scheduledFocusID = request.id
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.applyFocus(request, in: view)
            }
        }

        func scheduleFind(in view: NSTextView) {
            guard let request = parent.findRequest, request != scheduledFindID else { return }
            scheduledFindID = request
            DispatchQueue.main.async { [weak self, weak view] in
                guard self?.parent.findRequest == request, let editor = view as? SQLCompletionTextView else { return }
                editor.findController?.perform(.showFindInterface)
            }
        }

        func applyFocus(_ request: SQLEditorFocus, in view: NSTextView) {
            guard parent.focusRequest?.id == request.id, appliedFocusID != request.id,
                  view.string == parent.text, request.range.location != NSNotFound,
                  request.range.location >= 0, request.range.length >= 0,
                  request.range.location <= (view.string as NSString).length,
                  request.range.length <= (view.string as NSString).length - request.range.location else { return }
            dismissCompletion()
            synchronizingSelection = true
            defer { synchronizingSelection = false }
            appliedFocusID = request.id
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: request.range.location, length: 0))
            view.scrollRangeToVisible(NSRange(location: request.range.location, length: 0))
            if view.window != nil { view.showFindIndicator(for: request.range) }
        }
        func textDidChange(_ notification: Notification) {
            guard !synchronizingSelection, let view = notification.object as? NSTextView else { return }
            if !applyingLimit, !view.hasMarkedText(), let limited = SQLLineIndex(view.string).truncated(view.string) {
                applyLimitedText(limited, caret: view.selectedRange().location, in: view)
                return
            }
            parent.text = view.string
            highlight(view)
            updateSelection(view)
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            dismissCompletion()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            updateSelection(view)
            dismissCompletion()
        }

        func textDidEndEditing(_ notification: Notification) { dismissCompletion() }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !applyingLimit, !textView.hasMarkedText(), let replacementString else { return true }
            let candidate = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
            guard let limited = SQLLineIndex(candidate).truncated(candidate) else { return true }
            applyLimitedText(limited, caret: affectedCharRange.location + (replacementString as NSString).length, in: textView)
            return false
        }

        private func applyLimitedText(_ text: String, caret: Int, in view: NSTextView) {
            applyingLimit = true
            defer { applyingLimit = false }
            if view.string != text {
                view.breakUndoCoalescing()
                view.insertText(text, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
            }
            view.setSelectedRange(NSRange(location: min(caret, (view.string as NSString).length), length: 0))
            view.scrollRangeToVisible(view.selectedRange())
            notifyTruncation(in: view)
        }

        private func notifyTruncation(in view: NSTextView) {
            if let onTruncate { onTruncate(); return }
            guard !showingLimitAlert else { return }
            showingLimitAlert = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                guard let window = view?.window, window.attachedSheet == nil else { self.showingLimitAlert = false; return }
                let alert = NSAlert()
                alert.messageText = "Query is too long"
                alert.informativeText = "The query console supports up to 100,000 lines. Text after line 100,000 was truncated."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window) { [weak self] _ in self?.showingLimitAlert = false }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.complete(_:)) {
                updateCompletion(textView, explicit: true)
                return true
            }
            guard let completion, !textView.hasMarkedText() else {
                dismissCompletion()
                return false
            }
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
                dismissCompletion()
                return false
            }
            return true
        }

        func scheduleCompletion(_ view: NSTextView) {
            dismissCompletion()
            guard !applyingCompletion, !view.hasMarkedText() else { return }
            let work = DispatchWorkItem { [weak self, weak view] in
                if let view { self?.updateCompletion(view) }
            }
            completionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func updateCompletion(_ view: NSTextView, explicit: Bool = false) {
            dismissCompletion()
            guard !view.hasMarkedText(), view.selectedRange().length == 0 else { return }
            let tables = parent.tables
            let kind = parent.connectionKind
            let engine = SQLCompletionEngine(tables: tables, kind: kind)
            let text = view.string
            let cursor = view.selectedRange().location
            let analyze = {
                let result = engine.completions(in: text, atUTF16Offset: cursor, explicit: explicit)
                let collection = kind == .mongodb ? MongoCompletionEngine(tables: tables).fieldCollection(in: text, atUTF16Offset: cursor) : nil
                return (result, collection)
            }
            if (text as NSString).length < 100_000 {
                let (result, collection) = analyze()
                applyCompletion(result, collection: collection, text: text, cursor: cursor, explicit: explicit, in: view)
            } else {
                let id = completionID
                let work = DispatchWorkItem { [weak self, weak view] in
                    let (result, collection) = analyze()
                    DispatchQueue.main.async {
                        guard let self, let view, self.completionID == id,
                              view.string == text, view.selectedRange() == NSRange(location: cursor, length: 0), !view.hasMarkedText() else { return }
                        self.applyCompletion(result, collection: collection, text: text, cursor: cursor, explicit: explicit, in: view)
                    }
                }
                completionWork = work
                analysisQueue.async(execute: work)
            }
        }

        private func applyCompletion(_ result: SQLCompletionResult?, collection: String?, text: String, cursor: Int, explicit: Bool, in view: NSTextView) {
            completion = result
            selectedCompletion = 0
            showCompletion(view)
            guard let collection else { return }
            let id = completionID
            let loadFields = parent.loadMongoFields
            let tables = parent.tables
            completionTask = Task { @MainActor [weak self, weak view] in
                let fields = await loadFields(collection)
                guard !Task.isCancelled, !fields.isEmpty, let self, let view, self.completionID == id,
                      view.string == text, view.selectedRange() == NSRange(location: cursor, length: 0), !view.hasMarkedText() else { return }
                let schema = tables.map { $0.name == collection ? SchemaTable(name: $0.name, columns: fields) : $0 }
                let engine = MongoCompletionEngine(tables: schema)
                let result: SQLCompletionResult?
                if text.utf16.count < 100_000 { result = engine.completions(in: text, atUTF16Offset: cursor, explicit: explicit) }
                else {
                    result = await Task.detached(priority: .userInitiated) {
                        engine.completions(in: text, atUTF16Offset: cursor, explicit: explicit)
                    }.value
                }
                guard !Task.isCancelled, self.completionID == id else { return }
                self.completion = result
                self.selectedCompletion = 0
                self.showCompletion(view)
            }
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
            completionID = UUID()
            completionWork?.cancel()
            completionWork = nil
            completionTask?.cancel()
            completionTask = nil
            completion = nil
            completionPanel?.dismiss()
        }

        private func updateSelection(_ view: NSTextView) {
            guard !synchronizingSelection else { return }
            let range = view.selectedRange()
            let selected = range.length > 0 ? (view.string as NSString).substring(with: range) : ""
            if parent.selection != selected { parent.selection = selected }
            if parent.cursorLocation != range.location { parent.cursorLocation = range.location }
        }
        func highlight(_ view: NSTextView) {
            let text = view.string
            let index = SQLLineIndex(text)
            (view.enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.update(index)
            view.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor(Theme.editorText)]
            view.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: index.length))
            highlightWork?.cancel()
            highlightTask?.cancel()
            syntaxMatches = nil
            let id = UUID()
            highlightID = id
            let rules = syntaxRules
            let work = DispatchWorkItem { [weak self, weak view] in
                self?.highlightTask = Task.detached(priority: .userInitiated) { [weak self, weak view] in
                    guard let matches = SQLSyntaxHighlighter.matches(in: text, rules: rules, cancelled: { Task.isCancelled }) else { return }
                    await MainActor.run { [weak self, weak view] in
                        guard let self, let view, self.highlightID == id, view.string == text else { return }
                        self.syntaxMatches = matches
                        self.highlightVisibleText(view)
                    }
                }
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        private func highlightVisibleText(_ view: NSTextView) {
            guard let matches = syntaxMatches, let layout = view.layoutManager, let container = view.textContainer else { return }
            let bounds = view.visibleRect.offsetBy(dx: -view.textContainerInset.width, dy: -view.textContainerInset.height)
            let glyphs = layout.glyphRange(forBoundingRect: bounds, in: container)
            let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for (rule, ranges) in zip(syntaxRules, matches.rules) {
                for match in SQLSyntaxHighlighter.visibleMatches(ranges, in: range) {
                    layout.addTemporaryAttribute(.foregroundColor, value: rule.color, forCharacterRange: NSIntersectionRange(match, range))
                }
            }
        }
    }
}
