import AppKit
import SwiftUI

struct ResultsShortcut<Content: View>: NSViewRepresentable {
    let canRefresh: Bool
    let refresh: () -> Void
    var canCopy = false
    var copySelection: () -> Void = {}
    var selectionFocusRequest: UUID?
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> ResultsShortcutView {
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        let view = ResultsShortcutView(content: host)
        view.canRefresh = canRefresh
        view.refresh = refresh
        view.canCopy = canCopy
        view.copySelection = copySelection
        view.selectionFocusRequest = selectionFocusRequest
        return view
    }

    func updateNSView(_ view: ResultsShortcutView, context: Context) {
        withTransaction(context.transaction) {
            (view.content as? NSHostingView<Content>)?.rootView = content()
        }
        view.canRefresh = canRefresh
        view.refresh = refresh
        view.canCopy = canCopy
        view.copySelection = copySelection
        view.selectionFocusRequest = selectionFocusRequest
    }
}

final class ResultsShortcutView: NSView, NSUserInterfaceValidations {
    let content: NSView
    var canRefresh = false
    var refresh: () -> Void = {}
    var canCopy = false
    var copySelection: () -> Void = {}
    var selectionFocusRequest: UUID? {
        didSet { focusSelectionIfNeeded() }
    }
    private var appliedFocusRequest: UUID?
    private var monitor: Any?

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        focusSelectionIfNeeded()
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private var hasResultsFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    private var canCopySelection: Bool {
        canCopy && hasResultsFocus && !(window?.firstResponder is NSText)
    }

    private func focusSelectionIfNeeded() {
        guard let selectionFocusRequest, selectionFocusRequest != appliedFocusRequest,
              let window, window.makeFirstResponder(self) else { return }
        appliedFocusRequest = selectionFocusRequest
    }

    @objc func copy(_ sender: Any?) {
        guard canCopySelection else { return }
        copySelection()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) && canCopySelection
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers == .command, hasResultsFocus else { return event }
            if CommandKeyboard.character(in: event) == "c" {
                guard canCopySelection else { return event }
                if !event.isARepeat { copySelection() }
                return nil
            }
            guard CommandKeyboard.character(in: event) == "r" else { return event }
            if canRefresh && !event.isARepeat {
                window.makeFirstResponder(self)
                refresh()
            }
            return nil
        }
        if (event.type == .leftMouseDown || event.type == .rightMouseDown),
           bounds.contains(convert(event.locationInWindow, from: nil)), !hasResultsFocus {
            window.makeFirstResponder(self)
        }
        return event
    }
}
